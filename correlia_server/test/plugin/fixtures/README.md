# Plugin host spike fixtures

This directory owns the test-only Go fixtures for the `plugin-host-spike`
change. It contains no production plugin implementation.

## Module boundary

`go/` is an independent Go module named `correlia.local/pluginspike`. It pins
stock `github.com/hashicorp/go-plugin` v1.8.0 without a fork, patch, replace
directive, or vendored copy. The generated `OutputService` bindings under
`go/gen/` are Correlia-owned output from `proto/correlia/plugin/spike/v1/` and
are never edited by hand.

The module pins these generators through Go tool directives:

- `protoc-gen-go` v1.36.11;
- `protoc-gen-go-grpc` v1.6.0.

`go.sum` is the checksum boundary for every resolved module and generator.

## Executables

The Dart suite builds these three programs once per suite into an owned
scratch directory:

- `cmd/plain-stock`: stock `plugin.Serve()` only. It deliberately does not
  watch stdin, so it demonstrates the limitation of an unmodified third-party
  go-plugin process;
- `cmd/stdin-watched`: the same stock `plugin.Serve()` and generated service
  adapter, with a small stdin watcher around it. When stdin closes, it writes
  and syncs the distinct EOF-cause marker, then exits;
- `cmd/credential-helper`: creates an ephemeral self-signed P-521 client
  identity with a `localhost` SAN in an owner-only directory. It is a test
  helper, not a production certificate dependency.

The plain-stock and stdin-watched executables share
`internal/fixture/plugin.go`; only the presence of the stdin watcher differs.

## Common arguments

Both plugin executables accept the following explicit test-only arguments:

- `--journal PATH`: append-only acceptance journal, required;
- `--control-socket PATH`: observer's Unix control socket;
- `--eof-marker PATH`: distinct, owner-only stdin-EOF cause marker, required
  by the stdin-watched executable;
- `--ack-mode MODE`: `normal`, `withhold`, `invalid-epoch`,
  `invalid-sequence`, or `duplicate`;
- `--startup-mode MODE`: `serve`, `exit`, `stall`, `malformed`, `oversized`,
  or `incomplete`;
- `--tls-mode MODE`: `stock`, `plaintext`, or `required`;
- `--lifecycle-mode MODE`: `cooperative` or `uncooperative`;
- `--arm-barrier`: arm exactly one pre-ack control barrier in this process.

The normal startup mode is stock go-plugin serving. The stock TLS mode uses
go-plugin AutoMTLS whenever the inherited `PLUGIN_CLIENT_CERT` is present.
`plaintext` is an explicitly selected diagnostic mode and never an automatic
fallback. `required` fails startup when the client certificate is absent.
The uncooperative lifecycle mode keeps the process alive after the stock
controller stops serving, so the host must exercise its bounded forced-stop
path.

## Journal and barrier contract

The journal contains one newline-delimited JSON object per accepted event:

```json
{"id":"event-id","sha256":"hex-digest","epoch":"epoch","sequence":1}
```

The canonical JSON bytes are hashed with SHA-256 but are not copied into the
journal. A batch is serialized, written, flushed, and synced before its
acknowledgement. The journal is owner-only and bounded to 32 MiB. A trailing
torn JSON line is rejected during reconciliation; all complete earlier lines
remain usable.

When `--arm-barrier` is present, the fixture journals and syncs the first
batch, then sends one bounded JSON barrier frame to the control socket and
waits for one bounded release frame. Only the explicitly armed first process
uses this barrier: the fixture creates an exclusive claim file beside the
control socket, so a restarted fixture cannot block at the same crash point
even if the launch arguments are copied.

## Stdin EOF contract

The stdin-watched executable reads stdin without writing to it. A clean EOF
causes a separate owner-only marker file containing `stdin-eof` to be written
and synced before exit. A read failure exits without creating that marker, so
the marker proves an actual EOF rather than an arbitrary I/O failure. In the
host-death path it does not write to file descriptors 1 or 2 after the
handshake. The fixture also disables gRPC's default stderr logger before
stock serving starts so an internal error cannot violate that boundary.

## Original-code boundary

All fixture, journal, control, credential, and watcher code in this
directory is original Correlia code written for this test. No third-party
source, schema, template, certificate helper, or generated binding is copied
into it. The only dependency reused at runtime is stock go-plugin v1.8.0, and
the application contract comes from Correlia's own protobuf.
