// supervision-fixture exposes a deterministic barrier during a real delivery.
package main

import (
    "context"
    "encoding/json"
    "errors"
    "io"
    "os"

    "github.com/hashicorp/go-hclog"
    "github.com/hashicorp/go-plugin"
    pluginv1 "github.com/sh1ny/correlia/plugins/protocol/correlia/plugin/v1"
    "google.golang.org/grpc"
)

type fixture struct {
    plugin.NetRPCUnsupportedPlugin
    pluginv1.UnimplementedPluginServiceServer
    pluginv1.UnimplementedOutputServiceServer
    marker string
}

func (f *fixture) GRPCServer(_ *plugin.GRPCBroker, server *grpc.Server) error {
    pluginv1.RegisterPluginServiceServer(server, f)
    pluginv1.RegisterOutputServiceServer(server, f)
    return nil
}
func (*fixture) GRPCClient(context.Context, *plugin.GRPCBroker, *grpc.ClientConn) (any, error) {
    return nil, errors.New("fixture has no client")
}
func (*fixture) GetMetadata(context.Context, *pluginv1.GetMetadataRequest) (*pluginv1.GetMetadataResponse, error) {
    return &pluginv1.GetMetadataResponse{Name: "supervision-fixture", Version: "1.0", Kinds: []string{"output"}}, nil
}
func (f *fixture) Configure(_ context.Context, request *pluginv1.ConfigureRequest) (*pluginv1.ConfigureResponse, error) {
    var config struct { Marker string `json:"marker"` }
    if err := json.Unmarshal(request.ConfigJson, &config); err != nil || config.Marker == "" {
        return &pluginv1.ConfigureResponse{Accepted: false}, nil
    }
    f.marker = config.Marker
    return &pluginv1.ConfigureResponse{Accepted: true, Limits: &pluginv1.DeliveryLimits{
        MaxEventsPerBatch: 64, MaxBytesPerBatch: 1048576, MaxOutstandingBatches: 1,
    }}, nil
}
func (*fixture) CheckHealth(context.Context, *pluginv1.CheckHealthRequest) (*pluginv1.CheckHealthResponse, error) {
    return &pluginv1.CheckHealthResponse{Serving: true}, nil
}
func (f *fixture) Deliver(stream grpc.BidiStreamingServer[pluginv1.DeliverRequest, pluginv1.DeliverResponse]) error {
    for {
        request, err := stream.Recv()
        if err == io.EOF { return nil }
        if err != nil { return err }
        if _, err := os.Stat(f.marker); os.IsNotExist(err) {
            encoded, err := json.Marshal(request.Events)
            if err != nil { return err }
            if err := os.WriteFile(f.marker, encoded, 0600); err != nil { return err }
            <-stream.Context().Done()
            return stream.Context().Err()
        }
        encoded, err := json.Marshal(request.Events)
        if err != nil { return err }
        if err := os.WriteFile(f.marker+".retry", encoded, 0600); err != nil { return err }
        result := &pluginv1.DeliverResponse{Sequence: request.Sequence}
        for _, event := range request.Events {
            result.Results = append(result.Results, &pluginv1.EventResult{
                EventId: event.EventId, Outcome: pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_ACKNOWLEDGED,
            })
        }
        if err := stream.Send(result); err != nil { return err }
    }
}
func main() {
    go func() { _, _ = io.Copy(io.Discard, os.Stdin); os.Exit(0) }()
    plugin.Serve(&plugin.ServeConfig{
        HandshakeConfig: plugin.HandshakeConfig{ProtocolVersion: 1, MagicCookieKey: "CORRELIA_PLUGIN", MagicCookieValue: "correlia.plugin.v1"},
        Plugins: plugin.PluginSet{"output": &fixture{}}, GRPCServer: plugin.DefaultGRPCServer,
        Logger: hclog.New(&hclog.LoggerOptions{Level: hclog.Error, Output: io.Discard}),
    })
}
