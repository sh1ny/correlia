package fixture

import (
	"encoding/base64"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/hashicorp/go-plugin"
)

// Run starts a fixture process using the shared stock adapter.
//
// The plain-stock and stdin-watched executables call this same function; only
// WatchStdin differs between them.
func Run(config Config, watchStdin bool) error {
	switch config.Startup {
	case StartupExit:
		return nil
	case StartupStall:
		waitForSignal()
		return nil
	case StartupDiagnosticFlood:
		chunk := strings.Repeat("x", 4096)
		for range 1024 {
			if _, err := io.WriteString(os.Stderr, chunk); err != nil {
				return err
			}
		}
		_, err := io.WriteString(os.Stdout, "not-a-handshake\n")
		return err
	case StartupMalformed:
		_, err := io.WriteString(os.Stdout, "not-a-handshake\n")
		return err
	case StartupOversized:
		_, err := io.WriteString(os.Stdout, strings.Repeat("x", 17*1024)+"\n")
		return err
	case StartupIncomplete:
		_, err := io.WriteString(os.Stdout, "1|1|unix|")
		if err != nil {
			return err
		}
		waitForSignal()
		return nil
	case StartupForeignOwner:
		path := filepath.Join(os.Getenv("PLUGIN_UNIX_SOCKET_DIR"), "foreign.sock")
		listener, err := net.Listen("unix", path)
		if err != nil {
			return err
		}
		defer listener.Close()
		if err := os.Chown(path, 1, -1); err != nil {
			return err
		}
		block, _ := pem.Decode([]byte(os.Getenv("PLUGIN_CLIENT_CERT")))
		if block == nil {
			return errors.New("foreign owner requires a client certificate")
		}
		certificate := base64.RawStdEncoding.EncodeToString(block.Bytes)
		if _, err := fmt.Fprintf(os.Stdout, "1|1|unix|%s|grpc|%s\n", path, certificate); err != nil {
			return err
		}
		waitForSignal()
		return nil
	case StartupServe, StartupStallHealth, StartupDiagnosticFloodAfterHandshake:
	default:
		return fmt.Errorf("unsupported startup mode %q", config.Startup)
	}

	// The host-death path requires no writes to fd 1 or 2 after the
	// handshake. gRPC's default error logger writes to stderr, so silence it
	// before stock serving starts.
	if err := os.Setenv("GRPC_GO_LOG_SEVERITY_LEVEL", "NONE"); err != nil {
		return fmt.Errorf("silence gRPC diagnostics: %w", err)
	}
	if config.TLS == TLSPlaintext {
		if err := os.Unsetenv("PLUGIN_CLIENT_CERT"); err != nil {
			return fmt.Errorf("select plaintext TLS mode: %w", err)
		}
	}
	if config.TLS == TLSRequired && os.Getenv("PLUGIN_CLIENT_CERT") == "" {
		return errors.New("TLS mode requires PLUGIN_CLIENT_CERT")
	}

	journal, err := OpenJournal(config.JournalPath)
	if err != nil {
		return err
	}
	defer journal.Close()

	receiver := &OutputReceiver{
		Journal:   journal,
		Barrier:   NewControlBarrier(config.ControlSocket, config.ArmBarrier),
		Ack:       config.Ack,
		FloodLogs: config.Startup == StartupDiagnosticFloodAfterHandshake,
	}

	if watchStdin {
		if config.EOFMarker == "" {
			return errors.New("stdin watcher requires an EOF marker path")
		}
		go func() {
			_, copyErr := io.Copy(io.Discard, os.Stdin)
			if copyErr != nil {
				// A read failure is not proof that the host closed stdin. Exit
				// without creating the EOF-cause marker so the test cannot
				// mistake a transport failure for the intended cause.
				os.Exit(1)
			}
			if err := WriteEOFMarker(config.EOFMarker); err != nil {
				os.Exit(1)
			}
			os.Exit(0)
		}()
	}

	plugin.Serve(ServeConfig(config, receiver))
	if config.Lifecycle == LifecycleUncooperative {
		waitIgnoringTermination()
	}
	return nil
}

func waitForSignal() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	<-signals
}

func waitIgnoringTermination() {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	for {
		<-signals
	}
}
