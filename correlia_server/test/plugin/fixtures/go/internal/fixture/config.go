package fixture

import (
	"flag"
	"fmt"
	"io"
)

// AckMode controls the acknowledgement emitted for each accepted batch.
type AckMode string

const (
	// AckNormally acknowledges the exact epoch and sequence received.
	AckNormally AckMode = "normal"
	// AckWithheld journals a batch but never acknowledges it.
	AckWithheld AckMode = "withhold"
	// AckInvalidEpoch acknowledges with a deliberately different epoch.
	AckInvalidEpoch AckMode = "invalid-epoch"
	// AckInvalidSequence acknowledges with a deliberately different sequence.
	AckInvalidSequence AckMode = "invalid-sequence"
	// AckDuplicate acknowledges the same batch twice.
	AckDuplicate AckMode = "duplicate"
)

// StartupMode controls behavior before the stock go-plugin handshake.
type StartupMode string

const (
	// StartupServe starts the stock go-plugin server.
	StartupServe StartupMode = "serve"
	// StartupExit exits before writing a handshake.
	StartupExit StartupMode = "exit"
	// StartupStall remains alive without writing a handshake until signaled.
	StartupStall StartupMode = "stall"
	// StartupMalformed writes one malformed handshake line.
	StartupMalformed StartupMode = "malformed"
	// StartupOversized writes a handshake larger than the host's 16 KiB cap.
	StartupOversized StartupMode = "oversized"
	// StartupIncomplete writes a partial handshake and remains alive.
	StartupIncomplete StartupMode = "incomplete"
)

// TLSMode controls the stock go-plugin AutoMTLS selection.
type TLSMode string

const (
	// TLSStock passes through the inherited PLUGIN_CLIENT_CERT environment.
	TLSStock TLSMode = "stock"
	// TLSPlaintext explicitly selects stock plaintext serving.
	TLSPlaintext TLSMode = "plaintext"
	// TLSRequired requires PLUGIN_CLIENT_CERT and otherwise fails startup.
	TLSRequired TLSMode = "required"
)

// LifecycleMode controls whether the process exits after stock serving stops.
type LifecycleMode string

const (
	// LifecycleCooperative exits after the stock controller stops serving.
	LifecycleCooperative LifecycleMode = "cooperative"
	// LifecycleUncooperative remains alive after the stock controller stops
	// serving, forcing the host to use its bounded forced-stop path.
	LifecycleUncooperative LifecycleMode = "uncooperative"
)

// Config contains the fixture's explicit test-only configuration.
type Config struct {
	JournalPath     string
	ControlSocket   string
	EOFMarker       string
	Ack             AckMode
	Startup         StartupMode
	TLS             TLSMode
	Lifecycle       LifecycleMode
	ArmBarrier      bool
	CookieKey       string
	CookieValue     string
	ProtocolVersion int
}

// ParseConfig parses fixture arguments without reading the process environment.
func ParseConfig(args []string) (Config, error) {
	config := Config{
		Ack:             AckNormally,
		Startup:         StartupServe,
		TLS:             TLSStock,
		Lifecycle:       LifecycleCooperative,
		CookieKey:       "CORRELIA_PLUGIN_COOKIE",
		CookieValue:     "correlia-plugin-host-spike",
		ProtocolVersion: 1,
	}

	flags := flag.NewFlagSet("plugin-fixture", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	flags.StringVar(&config.JournalPath, "journal", "", "journal path")
	flags.StringVar(&config.ControlSocket, "control-socket", "", "Unix control socket path")
	flags.StringVar(&config.EOFMarker, "eof-marker", "", "stdin EOF cause marker path")
	flags.Var((*ackModeValue)(&config.Ack), "ack-mode", "ack mode: normal, withhold, invalid-epoch, invalid-sequence, or duplicate")
	flags.Var((*startupModeValue)(&config.Startup), "startup-mode", "startup mode: serve, exit, stall, malformed, oversized, or incomplete")
	flags.Var((*tlsModeValue)(&config.TLS), "tls-mode", "TLS mode: stock, plaintext, or required")
	flags.Var((*lifecycleModeValue)(&config.Lifecycle), "lifecycle-mode", "lifecycle mode: cooperative or uncooperative")
	flags.BoolVar(&config.ArmBarrier, "arm-barrier", false, "arm the one-time pre-ack control barrier")

	if err := flags.Parse(args); err != nil {
		return Config{}, fmt.Errorf("parse fixture arguments: %w", err)
	}
	if flags.NArg() != 0 {
		return Config{}, fmt.Errorf("unexpected fixture arguments: %v", flags.Args())
	}
	if config.ArmBarrier && config.ControlSocket == "" {
		return Config{}, fmt.Errorf("--arm-barrier requires --control-socket")
	}
	if config.EOFMarker != "" && config.Startup != StartupServe {
		return Config{}, fmt.Errorf("--eof-marker requires --startup-mode=serve")
	}

	return config, nil
}

type ackModeValue AckMode

func (value *ackModeValue) Set(raw string) error {
	mode := AckMode(raw)
	switch mode {
	case AckNormally, AckWithheld, AckInvalidEpoch, AckInvalidSequence, AckDuplicate:
		*value = ackModeValue(mode)
		return nil
	default:
		return fmt.Errorf("unknown ack mode %q", raw)
	}
}

func (value *ackModeValue) String() string {
	return string(*value)
}

type startupModeValue StartupMode

func (value *startupModeValue) Set(raw string) error {
	mode := StartupMode(raw)
	switch mode {
	case StartupServe, StartupExit, StartupStall, StartupMalformed, StartupOversized, StartupIncomplete:
		*value = startupModeValue(mode)
		return nil
	default:
		return fmt.Errorf("unknown startup mode %q", raw)
	}
}

func (value *startupModeValue) String() string {
	return string(*value)
}

type tlsModeValue TLSMode

func (value *tlsModeValue) Set(raw string) error {
	mode := TLSMode(raw)
	switch mode {
	case TLSStock, TLSPlaintext, TLSRequired:
		*value = tlsModeValue(mode)
		return nil
	default:
		return fmt.Errorf("unknown TLS mode %q", raw)
	}
}

func (value *tlsModeValue) String() string {
	return string(*value)
}

type lifecycleModeValue LifecycleMode

func (value *lifecycleModeValue) Set(raw string) error {
	mode := LifecycleMode(raw)
	switch mode {
	case LifecycleCooperative, LifecycleUncooperative:
		*value = lifecycleModeValue(mode)
		return nil
	default:
		return fmt.Errorf("unknown lifecycle mode %q", raw)
	}
}

func (value *lifecycleModeValue) String() string {
	return string(*value)
}
