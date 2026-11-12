package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	pluginv1 "github.com/sh1ny/correlia/plugins/protocol/correlia/plugin/v1"
)

const subjectPrefix = "correlia.v1.ev.>"

type natsConfig struct {
	Server string `json:"server"`
	Stream string `json:"stream"`
}

func (*outputServices) GetMetadata(context.Context, *pluginv1.GetMetadataRequest) (*pluginv1.GetMetadataResponse, error) {
	return &pluginv1.GetMetadataResponse{
		Name: "output-nats", Version: "1.0.0", Kinds: []string{"output"},
		ConfigSchemaJson: []byte(`{"type":"object","additionalProperties":false,"required":["server","stream"],"properties":{"server":{"type":"string"},"stream":{"type":"string"}}}`),
	}, nil
}

func rejected(field, class string) *pluginv1.ConfigureResponse {
	return &pluginv1.ConfigureResponse{ErrorClass: class, FieldErrors: []*pluginv1.FieldError{{Field: field, Message: class}}}
}

// capturesAllSubjects checks that a single stream filter covers all four
// variable tokens, not just a particular event under the prefix.
func capturesAllSubjects(filter string) bool {
	parts := strings.Split(filter, ".")
	prefix := [...]string{"correlia", "v1", "ev"}
	for i, part := range parts {
		if part == ">" {
			return i == len(parts)-1 && i <= 6
		}
		if i >= 7 || (i < 3 && part != "*" && part != prefix[i]) || (i >= 3 && part != "*") {
			return false
		}
	}
	return len(parts) == 7
}

func (s *outputServices) Configure(ctx context.Context, req *pluginv1.ConfigureRequest) (*pluginv1.ConfigureResponse, error) {
	var config natsConfig
	decoder := json.NewDecoder(bytes.NewReader(req.GetConfigJson()))
	decoder.DisallowUnknownFields()
	if decoder.Decode(&config) != nil {
		return rejected("server", "invalid_config"), nil
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return rejected("server", "invalid_config"), nil
	}
	u, err := url.Parse(config.Server)
	if err != nil || u == nil || (u.Scheme != "nats" && u.Scheme != "tls") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || (u.Path != "" && u.Path != "/") || strings.Contains(config.Server, ",") {
		return rejected("server", "invalid_config"), nil
	}
	if config.Stream == "" || len(config.Stream) > 256 {
		return rejected("stream", "invalid_config"), nil
	}
	secrets := req.GetSecrets()
	for name, value := range secrets {
		if (name != "token" && name != "creds") || len(value) == 0 {
			return rejected(name, "invalid_secret"), nil
		}
	}
	if len(secrets["token"]) > 0 && len(secrets["creds"]) > 0 {
		return rejected("token", "invalid_secret"), nil
	}
	options := []nats.Option{
		nats.Timeout(5 * time.Second), nats.MaxReconnects(-1),
		nats.ErrorHandler(func(*nats.Conn, *nats.Subscription, error) {}),
	}
	if token := secrets["token"]; len(token) > 0 {
		options = append(options, nats.Token(string(token)))
	}
	if creds := secrets["creds"]; len(creds) > 0 {
		options = append(options, nats.UserCredentialBytes(creds))
	}
	conn, err := nats.Connect(config.Server, options...)
	if err != nil {
		if errors.Is(err, nats.ErrAuthorization) || errors.Is(err, nats.ErrAuthExpired) || errors.Is(err, nats.ErrAuthRevoked) {
			return rejected("server", "nats_auth_failed"), nil
		}
		return rejected("server", "nats_unavailable"), nil
	}
	js, err := jetstream.New(conn, jetstream.WithPublishAsyncMaxPending(64), jetstream.WithPublishAsyncTimeout(10*time.Second))
	if err != nil {
		conn.Close()
		return rejected("server", "nats_unavailable"), nil
	}
	lookupCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	name, err := js.StreamNameBySubject(lookupCtx, subjectPrefix)
	if err != nil || name != config.Stream {
		conn.Close()
		if err == nil || errors.Is(err, jetstream.ErrStreamNotFound) {
			return rejected("stream", "stream_missing"), nil
		}
		return rejected("server", "nats_unavailable"), nil
	}
	stream, err := js.Stream(lookupCtx, name)
	if err != nil {
		conn.Close()
		return rejected("stream", "stream_missing"), nil
	}
	info := stream.CachedInfo()
	captures := false
	for _, filter := range info.Config.Subjects {
		if capturesAllSubjects(filter) {
			captures = true
			break
		}
	}
	if !captures {
		conn.Close()
		return rejected("stream", "stream_missing"), nil
	}
	s.mu.Lock()
	old := s.conn
	s.conn, s.js, s.stream = conn, js, name
	s.mu.Unlock()
	if old != nil {
		old.Close()
	}
	return &pluginv1.ConfigureResponse{
		Accepted:          true,
		Limits:            &pluginv1.DeliveryLimits{MaxEventsPerBatch: 64, MaxBytesPerBatch: 1048576, MaxOutstandingBatches: 1},
		ConfigurationInfo: map[string]string{"stream": name, "duplicate_window_ms": strconv.FormatInt(info.Config.Duplicates.Milliseconds(), 10)},
	}, nil
}

func (s *outputServices) CheckHealth(context.Context, *pluginv1.CheckHealthRequest) (*pluginv1.CheckHealthResponse, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.conn == nil || !s.conn.IsConnected() {
		return &pluginv1.CheckHealthResponse{Reason: "nats_unavailable"}, nil
	}
	return &pluginv1.CheckHealthResponse{Serving: true}, nil
}
