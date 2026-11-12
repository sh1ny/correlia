package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/nats-io/nats.go"
	"github.com/nats-io/nats.go/jetstream"
	pluginv1 "github.com/sh1ny/correlia/plugins/protocol/correlia/plugin/v1"
)

type envelope struct {
	SpecVersion string `json:"specversion"`
	ID          string `json:"id"`
	Type        string `json:"type"`
	Source      string `json:"source"`
	Subject     string `json:"subject"`
	Time        string `json:"time"`
	Traceparent string `json:"traceparent"`
	Data        struct {
		Tenant   string `json:"tenant"`
		Kind     string `json:"kind"`
		Severity string `json:"severity"`
		Observer struct {
			SourceKind string `json:"source_kind"`
		} `json:"observer"`
	} `json:"data"`
}

func validSubjectToken(token string) bool {
	if token == "" {
		return false
	}
	for i := range len(token) {
		c := token[i]
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

func makeMessage(event *pluginv1.Event) (*nats.Msg, bool) {
	var e envelope
	if json.Unmarshal(event.GetPayload(), &e) != nil {
		return nil, false
	}
	kind := strings.ToLower(strings.TrimPrefix(e.Data.Kind, "EVENT_KIND_"))
	severity := strings.ToLower(strings.TrimPrefix(e.Data.Severity, "EVENT_SEVERITY_"))
	tokens := [...]string{e.Data.Tenant, kind, e.Data.Observer.SourceKind, severity}
	for _, token := range tokens {
		if !validSubjectToken(token) {
			return nil, false
		}
	}
	msg := &nats.Msg{Subject: "correlia.v1.ev." + strings.Join(tokens[:], "."), Data: event.GetPayload(), Header: nats.Header{}}
	msg.Header.Set("Content-Type", "application/cloudevents+json")
	msg.Header.Set("ce-specversion", e.SpecVersion)
	msg.Header.Set("ce-id", e.ID)
	msg.Header.Set("ce-type", e.Type)
	msg.Header.Set("ce-source", e.Source)
	msg.Header.Set("ce-subject", e.Subject)
	if e.Time != "" {
		msg.Header.Set("ce-time", e.Time)
	}
	if e.Traceparent != "" {
		msg.Header.Set("traceparent", e.Traceparent)
	}
	return msg, true
}

func publishFailure(result *pluginv1.EventResult, err error) {
	result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_RETRYABLE
	switch {
	case errors.Is(err, nats.ErrMaxPayload), errors.Is(err, jetstream.ErrStreamMessageExceedsMaximum):
		result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_REJECTED
		result.ErrorClass = "payload_too_large"
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, nats.ErrTimeout), errors.Is(err, jetstream.ErrAsyncPublishTimeout):
		result.ErrorClass = "publish_timeout"
	default:
		var api *jetstream.APIError
		if errors.As(err, &api) && api.ErrorCode == 10060 {
			result.ErrorClass = "stream_mismatch"
		} else {
			result.ErrorClass = "nats_unavailable"
		}
	}
}

func (s *outputServices) deliverBatch(parent context.Context, batch *pluginv1.DeliverRequest) *pluginv1.DeliverResponse {
	ctx, cancel := context.WithTimeout(parent, 10*time.Second)
	defer cancel()
	s.mu.RLock()
	conn, js, stream := s.conn, s.js, s.stream
	s.mu.RUnlock()
	response := &pluginv1.DeliverResponse{Sequence: batch.GetSequence(), Results: make([]*pluginv1.EventResult, len(batch.GetEvents()))}
	futures := make([]jetstream.PubAckFuture, len(response.Results))
	for i, event := range batch.GetEvents() {
		result := &pluginv1.EventResult{EventId: event.GetEventId()}
		response.Results[i] = result
		msg, valid := makeMessage(event)
		if !valid {
			result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_REJECTED
			result.ErrorClass = "invalid_subject_token"
			continue
		}
		if conn == nil || js == nil || !conn.IsConnected() {
			publishFailure(result, nats.ErrDisconnected)
			continue
		}
		if err := ctx.Err(); err != nil {
			publishFailure(result, err)
			continue
		}
		future, err := js.PublishMsgAsync(msg, jetstream.WithMsgID(event.GetEventId()), jetstream.WithExpectStream(stream), jetstream.WithRetryAttempts(0))
		if err != nil {
			publishFailure(result, err)
			continue
		}
		futures[i] = future
	}
	for i, future := range futures {
		if future == nil {
			continue
		}
		result := response.Results[i]
		select {
		case ack := <-future.Ok():
			if ack != nil && ack.Stream == stream {
				result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_ACKNOWLEDGED
			} else {
				result.Outcome = pluginv1.DeliveryOutcome_DELIVERY_OUTCOME_RETRYABLE
				result.ErrorClass = "stream_mismatch"
			}
		case err := <-future.Err():
			publishFailure(result, err)
		case <-ctx.Done():
			publishFailure(result, ctx.Err())
		}
	}
	if ctx.Err() != nil && js != nil {
		js.CleanupPublisher()
	}
	return response
}

func (s *outputServices) Deliver(stream pluginv1.OutputService_DeliverServer) error {
	for {
		batch, err := stream.Recv()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := stream.Send(s.deliverBatch(stream.Context(), batch)); err != nil {
			return err
		}
	}
}
