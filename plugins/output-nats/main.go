package main

import (
	"context"
	"errors"

	"github.com/hashicorp/go-plugin"
	pluginv1 "github.com/sh1ny/correlia/plugins/protocol/correlia/plugin/v1"
	"google.golang.org/grpc"
)

type outputPlugin struct {
	plugin.NetRPCUnsupportedPlugin
}

type outputServices struct {
	pluginv1.UnimplementedPluginServiceServer
	pluginv1.UnimplementedOutputServiceServer
}

func (*outputPlugin) GRPCServer(_ *plugin.GRPCBroker, server *grpc.Server) error {
	services := &outputServices{}
	pluginv1.RegisterPluginServiceServer(server, services)
	pluginv1.RegisterOutputServiceServer(server, services)
	return nil
}

func (*outputPlugin) GRPCClient(context.Context, *plugin.GRPCBroker, *grpc.ClientConn) (any, error) {
	return nil, errors.New("output plugin does not provide a client")
}

func main() {
	watchStdin()
	plugin.Serve(&plugin.ServeConfig{
		HandshakeConfig: plugin.HandshakeConfig{
			ProtocolVersion: 1,
			MagicCookieKey: "CORRELIA_PLUGIN",
			MagicCookieValue: "correlia.plugin.v1",
		},
		Plugins: plugin.PluginSet{"output": &outputPlugin{}},
		GRPCServer: plugin.DefaultGRPCServer,
	})
}
