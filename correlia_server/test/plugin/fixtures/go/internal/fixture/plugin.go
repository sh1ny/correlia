package fixture

import (
	"context"
	"errors"
	"fmt"
	"io"

	"github.com/hashicorp/go-hclog"
	"github.com/hashicorp/go-plugin"
	"google.golang.org/grpc"

	spikev1 "correlia.local/pluginspike/gen/correlia/plugin/spike/v1"
)

// OutputGRPCPlugin adapts the generated output service to stock go-plugin.
//
// It embeds plugin.NetRPCUnsupportedPlugin so the fixture serves gRPC only,
// while GRPCServer registers the unmodified generated service contract.
type OutputGRPCPlugin struct {
	plugin.NetRPCUnsupportedPlugin
	Receiver *OutputReceiver
}

// GRPCServer registers the generated OutputService implementation.
func (output *OutputGRPCPlugin) GRPCServer(
	_ *plugin.GRPCBroker,
	server *grpc.Server,
) error {
	spikev1.RegisterOutputServiceServer(server, output.Receiver)
	return nil
}

// GRPCClient is not used by the fixture process.
func (output *OutputGRPCPlugin) GRPCClient(
	_ context.Context,
	_ *plugin.GRPCBroker,
	_ *grpc.ClientConn,
) (any, error) {
	return nil, errors.New("client side is not implemented by the fixture")
}

// Ensure the adapter retains the complete stock plugin interface.
var _ plugin.GRPCPlugin = (*OutputGRPCPlugin)(nil)

// OutputReceiver implements the experimental output delivery service.
type OutputReceiver struct {
	spikev1.UnimplementedOutputServiceServer

	Journal *Journal
	Barrier *ControlBarrier
	Ack     AckMode
}

// Deliver accepts one batch, journals it, and optionally pauses before ack.
func (receiver *OutputReceiver) Deliver(
	stream grpc.BidiStreamingServer[spikev1.DeliverRequest, spikev1.DeliverResponse],
) error {
	for {
		request, err := stream.Recv()
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, io.EOF) {
				return nil
			}
			return fmt.Errorf("receive delivery: %w", err)
		}
		if request.GetEpoch() == "" {
			return errors.New("delivery epoch is empty")
		}

		events := make([]EventPayload, 0, len(request.GetEvents()))
		for _, event := range request.GetEvents() {
			events = append(events, EventPayload{
				ID:            event.GetEventId(),
				CanonicalJSON: event.GetCanonicalJson(),
			})
		}
		if err := receiver.Journal.AppendBatch(
			request.GetEpoch(),
			request.GetSequence(),
			events,
		); err != nil {
			return fmt.Errorf("journal delivery: %w", err)
		}

		if err := receiver.Barrier.Wait(
			request.GetEpoch(),
			request.GetSequence(),
		); err != nil {
			return fmt.Errorf("control barrier: %w", err)
		}

		switch receiver.Ack {
		case AckWithheld:
			continue
		case AckInvalidEpoch:
			if err := stream.Send(&spikev1.DeliverResponse{
				Epoch:    request.GetEpoch() + "-invalid",
				Sequence: request.GetSequence(),
			}); err != nil {
				return fmt.Errorf("send invalid-epoch acknowledgement: %w", err)
			}
		case AckInvalidSequence:
			if err := stream.Send(&spikev1.DeliverResponse{
				Epoch:    request.GetEpoch(),
				Sequence: request.GetSequence() + 1,
			}); err != nil {
				return fmt.Errorf("send invalid-sequence acknowledgement: %w", err)
			}
		case AckDuplicate:
			response := &spikev1.DeliverResponse{
				Epoch:    request.GetEpoch(),
				Sequence: request.GetSequence(),
			}
			if err := stream.Send(response); err != nil {
				return fmt.Errorf("send duplicate acknowledgement: %w", err)
			}
			if err := stream.Send(response); err != nil {
				return fmt.Errorf("send duplicate acknowledgement: %w", err)
			}
		default:
			if err := stream.Send(&spikev1.DeliverResponse{
				Epoch:    request.GetEpoch(),
				Sequence: request.GetSequence(),
			}); err != nil {
				return fmt.Errorf("send acknowledgement: %w", err)
			}
		}
	}
}

// ServeConfig creates the stock go-plugin serving configuration.
func ServeConfig(config Config, receiver *OutputReceiver) *plugin.ServeConfig {
	return &plugin.ServeConfig{
		HandshakeConfig: plugin.HandshakeConfig{
			ProtocolVersion:  uint(config.ProtocolVersion),
			MagicCookieKey:   config.CookieKey,
			MagicCookieValue: config.CookieValue,
		},
		Plugins: plugin.PluginSet{
			"output": &OutputGRPCPlugin{Receiver: receiver},
		},
		GRPCServer: plugin.DefaultGRPCServer,
		Logger: hclog.New(&hclog.LoggerOptions{
			Level:      hclog.Error,
			Output:     io.Discard,
			JSONFormat: true,
		}),
	}
}
