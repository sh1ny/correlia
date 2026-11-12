package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/nats-io/nats-server/v2/server"
	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: natsdev serve|stream|sub")
	}
	switch args[0] {
	case "serve":
		return serve(args[1:])
	case "stream":
		return stream(args[1:])
	case "sub":
		return sub(args[1:])
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func serve(args []string) error {
	flags := flag.NewFlagSet("serve", flag.ContinueOnError)
	port := flags.Int("port", 0, "loopback port (0 selects a free port)")
	store := flags.String("store", "", "private JetStream storage directory")
	token := flags.String("token", "", "test-server authentication token")
	maxPayload := flags.Int("max-payload", 0, "test-server payload limit (0 uses the server default)")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 || *store == "" || *port < 0 || *port > 65535 || *maxPayload < 0 || int64(*maxPayload) > 1<<31-1 {
		return errors.New("serve requires --store, a valid --port and a valid --max-payload")
	}
	if err := os.MkdirAll(*store, 0700); err != nil {
		return fmt.Errorf("NATS storage: %w", err)
	}
	listenPort := *port
	if listenPort == 0 {
		listenPort = server.RANDOM_PORT
	}
	s, err := server.NewServer(&server.Options{
		Host: "127.0.0.1", Port: listenPort, JetStream: true,
		LogSizeLimit: 1 << 20, LogMaxFiles: 2,
		StoreDir: *store, LogFile: filepath.Join(*store, "nats.log"),
		JetStreamMaxMemory: 64 << 20, JetStreamMaxStore: 1 << 30,
		Authorization: *token, MaxPayload: int32(*maxPayload),
	})
	if err != nil {
		return fmt.Errorf("NATS startup: %w", err)
	}
	s.ConfigureLogger()
	go s.Start()
	if !s.ReadyForConnections(10 * time.Second) {
		s.Shutdown()
		s.WaitForShutdown()
		return errors.New("NATS startup: server did not become ready; see nats.log")
	}
	fmt.Printf("ready %s\n", s.ClientURL())
	_, _ = io.Copy(io.Discard, os.Stdin)
	s.Shutdown()
	s.WaitForShutdown()
	return nil
}

func connect(args []string, name string) (*nats.Conn, *flag.FlagSet, error) {
	flags := flag.NewFlagSet(name, flag.ContinueOnError)
	url := flags.String("url", "", "NATS server URL")
	if err := flags.Parse(args); err != nil {
		return nil, nil, err
	}
	if *url == "" || flags.NArg() != 0 {
		return nil, nil, fmt.Errorf("%s requires --url", name)
	}
	nc, err := nats.Connect(*url, nats.Timeout(5*time.Second), nats.NoReconnect())
	if err != nil {
		return nil, nil, fmt.Errorf("connect: %w", err)
	}
	return nc, flags, nil
}

func stream(args []string) error {
	nc, _, err := connect(args, "stream")
	if err != nil {
		return err
	}
	defer nc.Close()
	js, err := jetstream.New(nc)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err = js.CreateOrUpdateStream(ctx, jetstream.StreamConfig{
		Name: "CORRELIA_EVENTS", Subjects: []string{"correlia.v1.ev.>"},
		Duplicates: 10 * time.Minute,
	})
	if err != nil {
		return fmt.Errorf("create stream: %w", err)
	}
	fmt.Println("stream CORRELIA_EVENTS")
	return nil
}

func sub(args []string) error {
	nc, _, err := connect(args, "sub")
	if err != nil {
		return err
	}
	defer nc.Close()
	subscription, err := nc.SubscribeSync("correlia.v1.ev.>")
	if err != nil {
		return err
	}
	if err := subscription.SetPendingLimits(1024, 8<<20); err != nil {
		return err
	}
	if err := nc.FlushTimeout(5 * time.Second); err != nil {
		return err
	}
	fmt.Println("ready")
	for {
		msg, err := subscription.NextMsgWithContext(context.Background())
		if err != nil {
			return err
		}
		fmt.Printf("%s %s\n", msg.Subject, msg.Data)
	}
}
