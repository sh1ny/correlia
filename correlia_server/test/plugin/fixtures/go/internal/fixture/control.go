package fixture

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"time"
)

// MaxControlFrameBytes bounds one frame in either direction.
const MaxControlFrameBytes = 8 * 1024

// ControlBarrier is a one-shot, pre-ack test barrier.
//
// The fixture connects to the observer's Unix socket, sends one JSON frame,
// and waits for one JSON release frame. Only an explicitly armed process uses
// the barrier, so a restarted fixture never blocks on the same crash point.
type ControlBarrier struct {
	socketPath string
	armed      bool
	mu         sync.Mutex
	used       bool
}

// NewControlBarrier creates an optional one-shot control barrier.
func NewControlBarrier(socketPath string, armed bool) *ControlBarrier {
	return &ControlBarrier{socketPath: socketPath, armed: armed}
}

// BarrierFrame describes a batch paused immediately before acknowledgement.
type BarrierFrame struct {
	Type     string `json:"type"`
	Epoch    string `json:"epoch"`
	Sequence uint64 `json:"sequence"`
}

// ReleaseFrame authorizes the fixture to acknowledge the paused batch.
type ReleaseFrame struct {
	Type string `json:"type"`
}

// Wait blocks at the pre-ack barrier until the observer releases it.
//
// The barrier deliberately has no timeout of its own: the test's whole-test
// deadline owns the bound, while this keeps the fixture deterministic and
// prevents an accidental release from racing an internal timer.
func (barrier *ControlBarrier) Wait(epoch string, sequence uint64) error {
	barrier.mu.Lock()
	if !barrier.armed || barrier.used {
		barrier.mu.Unlock()
		return nil
	}
	barrier.used = true
	barrier.mu.Unlock()

	connection, err := net.DialTimeout("unix", barrier.socketPath, 5*time.Second)
	if err != nil {
		return fmt.Errorf("connect control socket: %w", err)
	}
	defer connection.Close()

	if deadline, ok := connection.(interface{ SetDeadline(time.Time) error }); ok {
		_ = deadline.SetDeadline(time.Time{})
	}

	frame := BarrierFrame{
		Type:     "barrier",
		Epoch:    epoch,
		Sequence: sequence,
	}
	payload, err := json.Marshal(frame)
	if err != nil {
		return fmt.Errorf("encode barrier frame: %w", err)
	}
	if len(payload) > MaxControlFrameBytes {
		return fmt.Errorf("barrier frame exceeds %d-byte bound", MaxControlFrameBytes)
	}
	if _, err := connection.Write(append(payload, '\n')); err != nil {
		return fmt.Errorf("write barrier frame: %w", err)
	}

	reader := bufio.NewReader(io.LimitReader(connection, MaxControlFrameBytes+1))
	line, err := reader.ReadBytes('\n')
	if err != nil {
		return fmt.Errorf("read barrier release: %w", err)
	}
	if len(line) > MaxControlFrameBytes {
		return fmt.Errorf("barrier release exceeds %d-byte bound", MaxControlFrameBytes)
	}

	var release ReleaseFrame
	if err := json.Unmarshal(line, &release); err != nil {
		return fmt.Errorf("decode barrier release: %w", err)
	}
	if release.Type != "release" {
		return fmt.Errorf("unexpected barrier release %q", release.Type)
	}
	return nil
}

// WriteEOFMarker flushes the distinct stdin-EOF cause marker.
//
// The marker is a separate regular file so the host-death path never writes
// to file descriptors 1 or 2 after the handshake.
func WriteEOFMarker(path string) error {
	if path == "" {
		return errors.New("EOF marker path is required")
	}

	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("open EOF marker: %w", err)
	}
	defer file.Close()
	if err := file.Chmod(0o600); err != nil {
		return fmt.Errorf("restrict EOF marker permissions: %w", err)
	}
	if _, err := file.WriteString("stdin-eof\n"); err != nil {
		return fmt.Errorf("write EOF marker: %w", err)
	}
	if err := file.Sync(); err != nil {
		return fmt.Errorf("sync EOF marker: %w", err)
	}
	return nil
}
