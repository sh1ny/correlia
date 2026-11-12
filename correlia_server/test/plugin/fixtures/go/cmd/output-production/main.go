// output-production is a stock go-plugin fixture for the production protocol.
package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"os"
	"strings"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/go-plugin"
	pluginv1 "github.com/sh1ny/correlia/plugins/protocol/correlia/plugin/v1"
	"google.golang.org/grpc"
)

type fixture struct {
	plugin.NetRPCUnsupportedPlugin
	pluginv1.UnimplementedPluginServiceServer
	pluginv1.UnimplementedOutputServiceServer
	mode string
	configured bool
}

func (f *fixture) GRPCServer(_ *plugin.GRPCBroker, s *grpc.Server) error {
	pluginv1.RegisterPluginServiceServer(s, f)
	pluginv1.RegisterOutputServiceServer(s, f)
	return nil
}

func (*fixture) GRPCClient(context.Context, *plugin.GRPCBroker, *grpc.ClientConn) (any, error) {
	return nil, errors.New("fixture has no client")
}

func (f *fixture) GetMetadata(context.Context, *pluginv1.GetMetadataRequest) (*pluginv1.GetMetadataResponse, error) {
	kinds := []string{"output"}
	if f.mode == "source" { kinds = []string{"source"} }
	schema := []byte(`{"type":"object"}`)
	if f.mode == "large-metadata" { schema = []byte(strings.Repeat("x", 65537)) }
	return &pluginv1.GetMetadataResponse{Name: "fixture", Version: "1.0", Kinds: kinds, ConfigSchemaJson: schema}, nil
}

func (f *fixture) Configure(_ context.Context, r *pluginv1.ConfigureRequest) (*pluginv1.ConfigureResponse, error) {
	if strings.Contains(string(r.ConfigJson), `"unknown"`) {
		return &pluginv1.ConfigureResponse{FieldErrors: []*pluginv1.FieldError{{Field: "unknown", Message: "invalid"}}}, nil
	}
	switch f.mode {
	case "reject-class":
		return &pluginv1.ConfigureResponse{ErrorClass: "stream_missing", FieldErrors: []*pluginv1.FieldError{{Field: "token", Message: "invalid"}}}, nil
	case "reject-secret":
		return &pluginv1.ConfigureResponse{ErrorClass: "nats_auth_failed"}, nil
	case "reject-invalid-class":
		return &pluginv1.ConfigureResponse{ErrorClass: "Invalid-Class"}, nil
	case "reject-info":
		return &pluginv1.ConfigureResponse{ConfigurationInfo: map[string]string{"stream": "alerts"}}, nil
	}
	if f.mode == "reject" || string(r.ConfigJson) != `{"subject":"alerts"}` || string(r.Secrets["token"]) != "fixture-secret" {
		return &pluginv1.ConfigureResponse{FieldErrors: []*pluginv1.FieldError{{Field: "token", Message: "invalid"}}}, nil
	}
	f.configured = true
	limits := &pluginv1.DeliveryLimits{MaxEventsPerBatch: 64, MaxBytesPerBatch: 1048576, MaxOutstandingBatches: 2}
	if f.mode == "large-limits" { limits.MaxEventsPerBatch = 10000 }
	response := &pluginv1.ConfigureResponse{Accepted: true, Limits: limits, ConfigurationInfo: map[string]string{"stream": "ALERTS", "duplicate_window_ms": "120000"}}
	switch f.mode {
	case "info-boundary":
		response.ConfigurationInfo = map[string]string{strings.Repeat("a", 64): strings.Repeat("é", 128), "b":"1","c":"1","d":"1","e":"1","f":"1","g":"1","h":"1"}
	case "info-count":
		response.ConfigurationInfo = map[string]string{"a":"1","b":"1","c":"1","d":"1","e":"1","f":"1","g":"1","h":"1","i":"1"}
	case "info-key":
		response.ConfigurationInfo = map[string]string{"Bad-Key": "1"}
	case "info-long-key":
		response.ConfigurationInfo = map[string]string{strings.Repeat("a", 65): "1"}
	case "info-value":
		response.ConfigurationInfo = map[string]string{"stream": strings.Repeat("é", 129)}
	case "accept-class":
		response.ErrorClass = "stream_missing"
	case "accept-fields":
		response.FieldErrors = []*pluginv1.FieldError{{Field: "token"}}
	case "info-oversized":
		response.ErrorClass = "Invalid-Class"
		response.ConfigurationInfo = map[string]string{"stream": strings.Repeat("x", 65537)}
	}
	return response, nil
}

func (f *fixture) CheckHealth(ctx context.Context, _ *pluginv1.CheckHealthRequest) (*pluginv1.CheckHealthResponse, error) {
	if f.mode == "stall-health" { <-ctx.Done(); return nil, ctx.Err() }
	return &pluginv1.CheckHealthResponse{Serving: f.configured}, nil
}

func (f *fixture) Deliver(stream grpc.BidiStreamingServer[pluginv1.DeliverRequest, pluginv1.DeliverResponse]) error {
	if !f.configured { return errors.New("not configured") }
	var previous uint64
	var held *pluginv1.DeliverResponse
	for {
		req, err := stream.Recv()
		if err == io.EOF { return nil }
		if err != nil { return err }
		if req.Sequence <= previous || len(req.Events) > 64 { return errors.New("invalid batch") }
		previous = req.Sequence
		res := &pluginv1.DeliverResponse{Sequence: req.Sequence}
		for i, event := range req.Events {
			if string(event.Payload) != "bytes-"+event.EventId { return errors.New("payload changed") }
			result := &pluginv1.EventResult{EventId: event.EventId, Outcome: pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_ACKNOWLEDGED}
			if f.mode == "mixed" && i == 1 { result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_RETRYABLE; result.ErrorClass = "publish_timeout" }
			if f.mode == "mixed" && i == 2 { result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_REJECTED; result.ErrorClass = "payload_too_large" }
			res.Results = append(res.Results, result)
		}
		switch f.mode {
		case "missing": if len(res.Results) > 0 { res.Results = res.Results[:len(res.Results)-1] }
		case "unknown": if len(res.Results) > 0 { res.Results[0].EventId = "unknown" }
		case "duplicate": if len(res.Results) > 0 { res.Results = append(res.Results, res.Results[0]) }
		}
		if f.mode == "hold-two" && held == nil { held = res; continue }
		if held != nil { if err := stream.Send(held); err != nil { return err }; held = nil }
		if err := stream.Send(res); err != nil { return err }
		if f.mode == "repeated-sequence" { if err := stream.Send(res); err != nil { return err } }
	}
}

func main() {
	mode := flag.String("mode", "normal", "fixture behavior")
	flag.Parse()
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); os.Exit(0) }()
	f := &fixture{mode: *mode}
	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig: plugin.HandshakeConfig{ProtocolVersion: 1, MagicCookieKey: "CORRELIA_PLUGIN", MagicCookieValue: "correlia.plugin.v1"},
		Plugins: plugin.PluginSet{"output": f},
		GRPCServer: plugin.DefaultGRPCServer,
		Logger: hclog.New(&hclog.LoggerOptions{Level: hclog.Error, Output: io.Discard}),
	})
}
