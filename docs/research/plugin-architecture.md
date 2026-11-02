# Correlia: plugin architecture, event format and pipeline (researched 2026-11-03)

Status: research only, no code. It feeds the architecture plan and roadmap.

Context: Correlia is an event/alert aggregator being rebuilt in Dart, with a Serverpod 4.1 server, Postgres and a Flutter web console. The owner has two requirements:

- **(A)** A pass-through pipeline. Every source format is normalized and enriched into one versioned event format. That format feeds the correlation engine and output plugins such as NATS.
- **(B)** Plugins in the style of Terraform and HashiCorp go-plugin: standalone executables in any language, supervised by the main process, talking gRPC.

Sources:

- ctx7: `/websites/deepwiki_hashicorp_go-plugin` and `/websites/deepwiki_grpc_grpc-dart`.
- go-plugin source on `main`, read via raw.githubusercontent: `server.go`, `client.go`, `mtls.go` and `internal/plugin/*.proto`.
- pub.dev API, GitHub release APIs and the Dart SDK CHANGELOG.
- developer.hashicorp.com, the CloudEvents spec repo and the Icinga 2 API docs.
- Web search for third-party implementations.

Legend: **[src]** means read in source or primary docs today. **[uncertain]** means inferred or from general knowledge and not confirmed today. "Spike" marks a short experiment to run before committing to a decision.

---

## TL;DR (opinionated)

1. **Be go-plugin wire compatible on the plugin side, but write your own small host in Dart.**
   - The protocol is simple enough to implement: a stdout handshake line, env-var cookie and version negotiation, then plain gRPC with three tiny internal services.
   - The benefit is that Go plugins can use the stock `plugin.Serve()`.
   - Python, Rust and Node plugins need about 150 to 300 lines of SDK each. HashiCorp already ships a Python example.
   - Skip the gRPC broker (bidirectional callbacks) in v1. Design the Correlia protocol around streams so it isn't needed.
2. **Use a hybrid model.** Built-in sources, decoders, enrichers and outputs run in-process in Dart, behind the same Dart interface as the out-of-process plugins. The plugin host is an adapter that implements that interface over gRPC. Most users never run a plugin binary.
3. **Use the CloudEvents 1.0.2 envelope with a Correlia-owned payload.**
   - `type = io.correlia.alert.v1` (major version in the type).
   - `dataschema` carries the exact minor version.
   - Protobuf (`correlia.event.v1`) is the source of truth, with generated JSON Schema.
   - Attribute keys follow OTel semantic conventions (`service.name`, `host.name`, `k8s.*`).
   - **Set `json_name` explicitly.** proto3 JSON defaults to lowerCamelCase.
4. **Write the NATS output as an out-of-process Go plugin using nats.go v1.55.0.** It is the first real plugin and dogfoods the plugin system. `dart_nats` 1.7.0 is alive and has JetStream publish with `msgId`, but it labels JetStream "experimental".
5. **Use Postgres as the durability spine.**
   - Raw inbox, then staged workers (`FOR UPDATE SKIP LOCKED`, partitioned by fingerprint for ordering), then a transactional outbox per output, giving at-least-once delivery.
   - Use the deterministic event `id` as `Nats-Msg-Id` so JetStream deduplicates retries.
   - Failed events go to a dead-letter table with replay.
6. **Dart is feasible.**
   - grpc 5.2.0 supports Unix domain sockets on both client and server, and TLS.
   - The server supports mTLS via `requireClientCertificate`.
   - A client certificate needs a small `ChannelCredentials` subclass [uncertain, spike].
   - Dart 3.11+ supports AF_UNIX on Windows.
   - A gRPC server can run next to Serverpod in the same process on another port.

---

## 1. HashiCorp go-plugin protocol

Version context: go-plugin **v1.8.0** is the latest release (dated 29 Apr; the year isn't shown, presumably 2026) ([releases](https://github.com/hashicorp/go-plugin/releases)). Muxing of gRPC broker connections arrived in v1.6.0, and `PLUGIN_UNIX_SOCKET_DIR` in v1.5.0.

### 1.1 Launch and handshake [src]

1. **The host launches the plugin binary** as a child process with these environment variables (`client.go`):
   - **Magic cookie.** The variable name and value are chosen per application; Terraform uses `TF_PLUGIN_MAGIC_COOKIE` with a fixed hex value. The plugin checks that the variable is set to the expected value. If it isn't, the plugin prints a human-readable "this is a plugin, don't run it directly" message on stderr and exits. **This is a UX guard, not security.**
   - `PLUGIN_PROTOCOL_VERSIONS`: a comma-separated list of the **app** protocol versions the host supports, for example `5,6`.
   - `PLUGIN_MIN_PORT` and `PLUGIN_MAX_PORT`: the TCP port range.
   - `PLUGIN_CLIENT_CERT`: the host's PEM certificate, set only when AutoMTLS is on.
   - `PLUGIN_MULTIPLEX_GRPC`: tells the plugin the host can multiplex broker connections (v1.6+).
   - `PLUGIN_UNIX_SOCKET_DIR` and `PLUGIN_UNIX_SOCKET_GROUP` (v1.5+).
   - The host environment is inherited unless `SkipHostEnv` is set.
2. **The plugin picks the highest version** in the host's list that it implements. The source sorts the client versions in reverse and matches the newest compatible one.
3. **The plugin opens a listener.**
   - On Windows, go-plugin **always uses TCP on 127.0.0.1**, inside the `PLUGIN_MIN_PORT`/`PLUGIN_MAX_PORT` range if one is given (`serverListener`: `if runtime.GOOS == "windows" → tcp`). This holds even though Windows now has AF_UNIX.
   - Elsewhere it uses a Unix socket in a temp file under `PLUGIN_UNIX_SOCKET_DIR`, mode 0600, made group-writable if a group is set.
4. **The plugin prints exactly one line to stdout:**
   ```
   CORE | APP | NETWORK | ADDRESS | PROTOCOL | SERVER_CERT [| MUX]
   ```
   - The real line has no spaces around the pipes, for example `1|6|unix|/tmp/plugin123|grpc|<b64cert>`.
   - `CORE` is the go-plugin core protocol, always `1`. The host refuses anything else.
   - `APP` is the negotiated app version.
   - `NETWORK` is `tcp` or `unix`.
   - `PROTOCOL` is `grpc` or `netrpc`. `netrpc` is Go-only and is the default when the field is omitted.
   - `SERVER_CERT` is the plugin's leaf certificate as **base64 without padding (RawStdEncoding) of the DER bytes**, not PEM, because the line can't contain newlines. It is empty when AutoMTLS is off.
   - The 7th field, `true`, appears **only if the host set `PLUGIN_MULTIPLEX_GRPC`**. Old hosts used `SplitN(line, "|", 6)` and would break on a 7th field. A host should split on every `|`.
5. **The host waits up to `StartTimeout`** (default 1 minute) for the line. It ignores non-handshake noise only to a limited extent, so a plugin must print nothing else on stdout before the handshake.

### 1.2 AutoMTLS [src]

- **How the certificates are made:**
  - The host generates a throwaway self-signed certificate and passes it as PEM in `PLUGIN_CLIENT_CERT`.
  - The plugin generates its own certificate and pins the host's certificate as its only client CA. It requires and verifies a client certificate, uses TLS 1.2 or later, and sets ServerName `localhost`.
  - The plugin returns its certificate in handshake field 6. The host pins that certificate as the only root.
- **Certificate details (`mtls.go`):**
  - ECDSA **P-521** key.
  - `IsCA=true`.
  - DNS SAN = `localhost`.
  - Extended key usage for both server auth and client auth.
  - Validity of about 30 years.
- **For a Dart host,** BoringSSL in `dart:io` must accept a P-521 ECDSA leaf. This is **[uncertain]**: BoringSSL's P-521 support has narrowed over time. **Spike 1:** connect a Dart client to a stock Go plugin that has AutoMTLS on. If P-521 fails, Correlia's own SDK can use P-256, but stock go-plugin Go plugins would then have to run without AutoMTLS (TLS off on a 0600 Unix socket). On Windows TCP that leaves the plugin port open to any local process.
- **Why AutoMTLS matters on Windows:** go-plugin uses loopback TCP there, and without mTLS any local user can call the plugin's gRPC port. On Unix the 0600 socket already gives owner-only access.

### 1.3 Internal gRPC services [src: `internal/plugin/*.proto`]

The plugin's gRPC server registers the application services plus these:

| Service | Shape | Purpose |
|---|---|---|
| `grpc.health.v1.Health` | standard gRPC health | The host checks service name **`plugin`** for SERVING. The non-Go guide says that without it the host "may restart the process abruptly". |
| `plugin.GRPCController` | `Shutdown(Empty) → Empty` | Graceful stop. On `Kill()` the host calls Shutdown, **waits 2 s** for the process to exit, then force-kills it (`client.go`). |
| `plugin.GRPCStdio` | `StreamStdio(Empty) → stream StdioData{channel STDOUT/STDERR, bytes}` | After the handshake the Go server redirects the plugin's own stdout and stderr into pipes and streams them to the host over gRPC, so stray prints can't corrupt the handshake channel. Call it once, early. **Optional for non-Go plugins.** |
| `plugin.GRPCBroker` | `StartStream(stream ConnInfo) ↔ stream ConnInfo` | Bidirectional callbacks (see 1.4). |

**Logging [src, partial]:**

- The host reads the plugin process's real **stderr** line by line.
- Lines that parse as hclog JSON (`@level`, `@message`, `@module`, `@timestamp`, plus extra keys) are re-emitted into the host logger at that level, named after the plugin.
- Other lines are logged raw at debug level [uncertain on the exact level].
- The upshot is that **plugins log JSON lines to stderr.** Any language can do that.

### 1.4 gRPC broker [src + uncertain on mux details]

- **Message:** `ConnInfo{service_id, network, address, knock{knock, ack, error}}`.
- **Classic mode:**
  1. One side reserves an id (`NextId`) and opens a **new listener** for an extra gRPC server, for example a callback interface the host gives to the plugin.
  2. It announces `{id, network, address}` over the long-lived `StartStream`.
  3. The peer waits for that id and dials the address.
  4. The id itself is passed inside a normal RPC argument. This is how Terraform-style "plugin calls back into host" works, and how go-plugin passes `io.Reader`/`Writer` across.
- **Mux mode (v1.6+, opt-in via the env var and the 7th handshake field):** extra connections reuse the plugin's main listener, and the `knock`/`ack` exchange tells the listener which logical service the next connection is for. This avoids one listener per callback [details uncertain].
- **Correlia should not need the broker in v1.** Model host-provided capabilities (lookups, KV, config) as RPCs the plugin calls on a **host service exposed through the broker only if really needed later**. Better still, put that data into stream messages.

### 1.5 Reattach, version negotiation and controller

- **ReattachConfig** `{Protocol, ProtocolVersion, Addr, Pid, Test}` lets a host connect to an already-running plugin instead of launching one. It is used for debugging, for example Terraform's `TF_REATTACH_PROVIDERS` env var with a provider started under a debugger. **Worth copying.** A Correlia `--plugin-reattach` option makes plugin development in any language far easier: run the plugin in your IDE and point the host at it.
- **Versioning has two levels:**
  - Core version 1 is fixed.
  - The app version is negotiated from the host list in `PLUGIN_PROTOCOL_VERSIONS`.
  - Within one app version, evolve additively through protobuf, and use capability flags returned by a `GetMetadata`-style RPC.
- **Integrity:** `SecureConfig{Checksum, Hash}` makes the host verify the binary's hash before exec. It is a simple, good idea that maps directly onto a Correlia lock file.

### 1.6 How Terraform layers on top [src: developer.hashicorp.com]

- **Protocol versions:**
  - **v5** (latest minor 5.10) works with Terraform 0.12 and later.
  - **v6** (latest minor 6.10) works with Terraform 1.0 and later. v6 adds nested attributes.
  - Major versions are incompatible with each other and minor versions are additive.
  - The `.proto` files are `tfplugin5.proto` and `tfplugin6.proto` under `docs/plugin-protocol` in the terraform repo ([protocol page](https://developer.hashicorp.com/terraform/plugin/terraform-plugin-protocol)).
- **Provider service RPCs [general knowledge, uncertain on newest additions]:**
  - Schema discovery: `GetMetadata` (cheap list of resources, data sources and functions; newer) and `GetProviderSchema` (full typed schema for the provider config and every resource, data source and function).
  - Validation and configuration: `ValidateProviderConfig`, `ConfigureProvider`.
  - Resource lifecycle: `PlanResourceChange`, `ApplyResourceChange`, `ReadResource`, `ImportResourceState`, `UpgradeResourceState`.
  - Control: `StopProvider`.
  - Values travel as msgpack- or JSON-encoded `DynamicValue` blobs typed by the schema. That is how a generic host handles plugin-defined config without codegen.
  - **Lesson for Correlia:** a plugin returns its **config schema** (JSON Schema) from `GetMetadata`. The host validates config before `Configure` and the console renders forms from it. This is the same pattern Grafana uses with plugin.json.
- **Discovery and distribution [src: lock-file docs, plus general knowledge on the registry protocol]:**
  - Addresses are `hostname/namespace/type`.
  - The registry protocol works through `/.well-known/terraform.json` and a versions endpoint, which lists versions with `protocols` and `platforms`.
  - The download endpoint returns the zip URL, `shasum`, `SHA256SUMS`, its GPG signature and the signing keys.
  - `.terraform.lock.hcl` records per provider:
    - `version`;
    - `constraints`, informational only;
    - `hashes`, either `zh:` (SHA-256 of the official zip) or `h1:` (SHA-256 over the unpacked contents, the preferred scheme, which also matches mirrors).
  - Trust is on first use. Afterwards `init` fails if no hash matches ([lock file docs](https://developer.hashicorp.com/terraform/language/files/dependency-lock)).
  - **For Correlia v1** a local `plugins/` directory plus a `correlia.lock` (name, version, sha256 per OS/arch) is enough. Add a registry and signatures (minisign or cosign) only if third parties ever publish plugins.

### 1.7 Is it documented enough? Non-Go implementations

- **Documentation is thin but the protocol is small.**
  - The official docs (`docs/internals.md`, `docs/guide-plugin-write-non-go.md`) cover only the handshake, the port env vars and the health requirement ([internals](https://github.com/hashicorp/go-plugin/blob/main/docs/internals.md), [non-Go guide](https://github.com/hashicorp/go-plugin/blob/main/docs/guide-plugin-write-non-go.md)).
  - AutoMTLS, the broker, stdio, the controller, multiplexing and stderr log parsing are documented **only in source**. They total roughly 1.5k lines of Go across `client.go`, `server.go`, `grpc_broker.go` and `mtls.go`, and they read cleanly.
  - Verdict: **implementable**. A Dart host for the subset (handshake, negotiation, AutoMTLS, health, Shutdown, stderr logs) is about 500 to 800 lines [estimate].
- **Existing non-Go implementations:**
  - **Python:** an official example plugin in `examples/grpc/plugin-python`. It is plugin-side only and is not a library.
  - **Rust, `grr-plugin`:** plugin side only, last release 0.2.0 (Feb 2022), effectively unmaintained ([lib.rs](https://lib.rs/crates/grr-plugin)).
  - **Rust, `magma-plugin`:** a **host/client** side for Terraform and OpenTofu providers. It covers the handshake, mTLS bootstrap, and tfplugin5 and tfplugin6 clients ([docs.rs](https://docs.rs/magma-plugin/0.1.20/magma_plugin/)). It is the closest existing non-Go host and a useful reference for Spike 1 (it proves a non-Go host can do AutoMTLS against Go providers) [maturity unverified].
  - **Rust, terustform:** a hobby tfplugin6 provider ([git.noratrieb.dev](https://git.noratrieb.dev/Noratrieb/terustform/commit/18a9d610cdc257b9193dee617d3bd92de171c9c2)).
  - **Search found no maintained .NET or Node implementations** [search-limited]. Nothing exists for Dart.
- **Redpanda Connect dynamic plugins** are the closest modern analogue. They are subprocesses on gRPC over a Unix socket, with official Go and Python SDKs, beta since v4.56 (2025) ([docs](https://docs.redpanda.com/redpanda-connect/plugins/about/), [blog](https://www.redpanda.com/blog/multi-language-redpanda-connect-plugins)). Their docs warn about IPC overhead and recommend **batch** components. Correlia should batch too.

---

## 2. Alternatives compared

| Model | How it works | Pros for Correlia | Cons for Correlia |
|---|---|---|---|
| **go-plugin-style subprocess + gRPC** (Terraform, Vault, Packer, Grafana backend, Redpanda Connect dynamic) | Host supervises child processes and talks gRPC over UDS or loopback | Any language; crash isolation; proven at scale; Go plugins nearly free; schema discovery via RPC; can use native clients (nats.go, Kafka libs) | You build supervision, IPC serialization cost (batch it), cross-OS process handling, binary distribution per OS/arch |
| **WASM** (wasmtime **v50.0.1**, Extism) | In-process sandboxed modules | Sandboxed, fast, single portable artifact, good for **pure transforms** (decode, enrich) | **Dart host support is weak.** `wasm_run` 0.2.0+2 wraps an older wasmtime and has no component model. **Extism has no Dart SDK** (you'd FFI libextism yourself) and defers the component model ([host SDKs](https://extism.org/docs/concepts/host-sdk), [issue](https://github.com/extism/extism/issues/666)). Networking from guests is awkward, so it's a **bad fit for outputs** (NATS, Kafka) |
| **NATS plugin bus** (plugins as `micro` services; discovery via `$SRV.PING/INFO/STATS`, ADR-32) | Plugins connect to NATS and serve request/reply endpoints | Language-agnostic (NATS clients everywhere), remote and horizontally scalable plugins, no supervision code, built-in discovery and stats ([NATS services](https://docs.nats.io/learn/services/), [ADR-32](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-32.md)) | Makes NATS a **hard dependency** even for a small single-box install. No lifecycle management (who starts plugins?). Trust and authn rely on NATS accounts. Harder to debug |
| **Fluent Bit** | C plugins compiled in or loaded as `.so`; Go plugins as cgo shared libs (fluent-bit-go); WASM filters and inputs; Lua filter [general knowledge] | Shows that "built-ins + scriptable filter + WASM" is a viable split | Shared-library plugins are **not** an option from Dart (no stable C ABI story) |
| **Vector** | No runtime plugins: VRL transform language, `exec` source, Lua transform; the WASM experiment was removed [general knowledge, uncertain on dates] | A deliberate choice: one fast DSL for transforms beats a plugin ABI | Not extensible by third parties without forking |
| **OpenTelemetry Collector** | Compile-time composition: the `ocb` builder assembles receivers, processors, exporters and extensions into a custom binary | Strong typed component model (receiver, processor, exporter, connector, extension). **Copy its vocabulary** | Requires rebuilding the binary, which is a non-starter for "any language" |
| **Benthos / Redpanda Connect** (v4.116.1) | Compiled Go plugins, plus dynamic gRPC subprocess plugins, plus a WASM processor, plus the Bloblang DSL | Same hybrid Correlia wants; validates the design | Dynamic plugins still beta; Go-centric SDK |
| **Grafana backend plugins** | go-plugin with a per-type magic cookie; services for QueryData, CallResource, CheckHealth, CollectMetrics and streams; plugins signed via a manifest [general knowledge] | Closest product analogue: a UI product hosting data plugins; `CheckHealth` and `CollectMetrics` are worth copying | In practice Go-only (Grafana SDK); signing is Grafana-centralized |

**Recommendation: hybrid, with one interface and two transports.**

- **Define the component kinds once** in Dart (`Source`, `Decoder`, `Enricher`, `Classifier`, `Output`), mirroring the OTel Collector's taxonomy, and the same contract in protobuf.
- **Built-ins** (Alertmanager/Thanos, Icinga2, generic-JSON decoders, CIDR/lookup/regex/CEL enrichers, webhook output) are Dart classes. They have zero IPC cost and work without any plugin binary.
- **External plugins** go through a `GrpcPluginAdapter implements Output` (and so on) speaking a go-plugin-compatible handshake.
- **Later (parked):**
  - A WASM transform tier, once a decent Dart wasmtime binding exists.
  - A "remote plugin over NATS" transport as a third adapter behind the same interface.
- **Don't make NATS a required dependency.**

### Proposed Correlia plugin protocol v1 (sketch)

- **Handshake:** go-plugin compatible.
  - Cookie `CORRELIA_PLUGIN_COOKIE`.
  - `PLUGIN_PROTOCOL_VERSIONS=1`.
  - Health service name `plugin`.
  - `GRPCController.Shutdown`.
  - JSON-on-stderr logs.
- **Common RPCs:**
  - `GetMetadata`: kind(s), name, version, capabilities, JSON Schema of the config.
  - `Configure(config_json)`.
  - `CheckHealth`.
  - `GetStats`.
- **`Output.Deliver(stream EventBatch) returns (stream Ack)`:** bidirectional and batched. Each batch carries a sequence number and the plugin acks per batch, with per-event failures marked retryable or permanent. Back-pressure comes from a host-side window of N unacked batches (credit-based).
- **`Source.Run(SourceConfig) returns (stream RawEventBatch)`:** for pull or stream sources such as the Icinga2 `/v1/events` long-poll. The host acks by checkpoint over a separate `Commit(cursor)` unary call, or the stream becomes bidirectional.
- **`Decoder.Decode(RawEventBatch) returns (EventBatch)`** and **`Enricher.Enrich(EventBatch) returns (EventPatchBatch)`:** unary and batched. Enrichers return **patches** (set or append labels or attributes), not whole events, so the host stays authoritative and can audit which plugin set what.
- **Supervision:**
  - Restart with exponential backoff.
  - Circuit-break after K crashes in M minutes, after which the plugin is shown as `degraded` in the console.
  - Health check every 10 to 30 s.
  - Per-plugin `StartTimeout`.
  - Optional per-plugin env and working dir.

---

## 3. Dart feasibility

| Item | Finding |
|---|---|
| **package:grpc** | **5.2.0** (2026-10-15), requires `protobuf` 6.x ([changelog](https://github.com/grpc/grpc-dart/blob/master/CHANGELOG.md)). Repo: 891 stars, 126 open issues, pushed 2026-11-01. Maintained by the Dart team, with steady but slow change. Has unary, client, server and **bidirectional streaming**, interceptors (`serverInterceptors` since 4.1.0), keepalive and compression. |
| UDS | `Server.serve(address: InternetAddress(path, type: unix))` on the server. On the client, `ClientChannel` accepts an `InternetAddress` of type unix (`http2_channel.dart`) [src]. |
| TLS / mTLS server | `ServerTlsCredentials(certificate, privateKey)` plus `serve(requestClientCertificate:, requireClientCertificate:)` [src, ctx7]. |
| mTLS client | `ChannelCredentials.secure(certificates:, authority:, onBadCertificate:)` only sets **trusted roots**. There is no client-cert parameter. **Workaround:** subclass `ChannelCredentials` (call the public `.secure` constructor) and override the `securityContext` getter to also call `useCertificateChainBytes` and `usePrivateKeyBytes` [src for the getter; subclassing **uncertain, spike**]. Set `authority: 'localhost'` to match go-plugin's ServerName. |
| Health service | grpc-dart **does not ship** `grpc.health.v1`. Vendor `health.proto` and generate it, which takes minutes. |
| **Windows UDS** | **Dart 3.11.0 added AF_UNIX on Windows** (stream sockets only; reparse points, so use `FileSystemEntity.typeSync` instead of `File.existsSync`) [src: dart-lang/sdk CHANGELOG]. The Dart host can therefore use UDS everywhere, but must still accept **TCP from Go plugins on Windows**, because go-plugin forces TCP there. |
| **protoc_plugin** | **25.1.0** with **protobuf 6.1.0** (2026-09-11). Requires `protoc` or `buf` on the dev machine. Use **buf** (`buf generate`) to drive Dart, Go, Python, Rust (prost/tonic) and TS codegen from one `buf.yaml`, plus `buf breaking` in CI to enforce additive evolution [general knowledge]. Generated Dart supports proto3 JSON via `toProto3Json`/`mergeFromProto3Json` [general knowledge]. |
| **Process supervision** | `Process.start` gives the pid, stdin, stdout and stderr streams, and `exitCode`. **Gotchas** [general knowledge, uncertain on details]: on Windows `Process.kill()` is TerminateProcess (no graceful signal), so graceful stop must be the gRPC `Shutdown` RPC (which go-plugin already uses) and kill is only the fallback. Children are **not** killed when the host dies (no Job Objects in dart:io, no `PR_SET_PDEATHSIG`). **Mitigation:** the Correlia SDK makes plugins exit when **stdin reaches EOF**; the host keeps stdin open and never writes. Stock Go go-plugin plugins don't do this; on Windows a Job Object via `package:win32` FFI fixes it [uncertain]. Use `ProcessStartMode.normal`. Drain stdout and stderr continuously, or the pipes fill and the child blocks. |
| **Serverpod + gRPC side by side** | Serverpod 4.1 is a normal Dart process. Starting a `grpc.Server` on another port, or on a UDS, after `pod.start()` in the same isolate works because both are just `dart:io` sockets [reasoning, not a documented Serverpod feature]. The plugin host here is a gRPC **client**, so Serverpod needs a gRPC *server* only if plugins call back into the host or remote agents push over gRPC. For CPU-heavy decode or enrich work, run pipeline workers in separate **isolates**, or as separate Serverpod instances in a "worker" role sharing Postgres. |

---

## 4. NATS from Dart, and the NATS output design

### 4.1 Dart NATS clients (pub.dev, 2026-11-03)

| Package | Version | Notes |
|---|---|---|
| **dart_nats** | **1.7.0** (2026-10-23), repo `dart-nats/dart-nats`, 58 stars | Actively maintained: 1.3 to 1.7 shipped in 2026 with careful changelogs (typed server errors, concurrent requests, reconnect and handshake fixes). Supports TCP, TLS and WebSocket; **JetStream, KV and Object Store, but README marks them experimental**; `PubOpts(msgId:)` for dedup; pull consumers; consumer pause/resume. |
| nats_for_dart | 0.3.0 (2026-10-21) | FFI to the NATS **C** client, with JetStream and KV. Native-lib distribution burden. |
| natsio | 0.1.1 (2026-02) | "Pure Dart, ported from nats.go". Too young. |
| nats_client, nats, nats_dart, dart_nats_client | 2020–2023 | Abandoned. |

**Recommendation:** make the NATS output **an out-of-process Go plugin on nats.go v1.55.0** (nats-server is at v2.15.2).

- It exercises the plugin system with a real, valuable plugin from day one.
- nats.go is the reference JetStream implementation. It brings async publish with PubAck futures, reconnect buffering, `Nats-Msg-Id`, and `Nats-Expected-*` headers.
- It isolates a network client's failure modes from the core.
- Cost: a Go toolchain in the build, which is cheap.

Keep `dart_nats` in mind for a **built-in fallback** or for consuming NATS as a *source* later. It is good enough for core pub/sub today.

### 4.2 Subject, stream and header design

- **Subjects:**
  - Events: `correlia.v1.ev.<tenant>.<kind>.<source_kind>.<severity>`, for example `correlia.v1.ev.default.alert.alertmanager.critical`.
  - Incidents: `correlia.v1.incident.<tenant>.<status>`.
  - Keep tokens **low-cardinality and stable**. Never put fingerprints, hostnames or free text in subjects: wildcards then become useless and the subject space explodes. Hostnames go in the payload or headers.
  - `kind` is one of alert, state, ack, downtime, comment, heartbeat.
  - Put the version **right after the prefix** so a v2 can run side by side (`correlia.v2.>`).
- **Stream:** `CORRELIA_EVENTS` captures `correlia.v1.ev.>`. Configure it with file storage, limits retention, `max_age` around 7 days (configurable), `duplicate_window` at the default 2 min or longer to cover the outbox retry horizon, and R3 in a cluster. A second stream `CORRELIA_INCIDENTS` holds incident lifecycle events. Consumers own their durable consumers; Correlia only publishes.
- **Headers:**
  - `Nats-Msg-Id` = the CloudEvents `id`, which is deterministic (see 6), so the outbox's at-least-once delivery becomes effectively exactly-once inside the dedup window.
  - Add the CloudEvents **binary-mode** `ce-*` headers (`ce-specversion`, `ce-id`, `ce-type`, `ce-source`, `ce-subject`, `ce-time`, `ce-dataschema`), which NATS 2.2+ supports, and `traceparent`.
  - **Default to structured mode** (`Content-Type: application/cloudevents+json`, whole envelope in the body). It is self-contained, works with `nats sub`, and any CloudEvents SDK can parse it.
  - Make binary mode a plugin option. The CloudEvents NATS binding is still marked `1.0.3-wip` ([binding](https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/nats-protocol-binding.md)).

---

## 5. Standardized event format

### 5.1 Inputs to the design

- **CloudEvents 1.0.2** (latest core release) ([releases](https://github.com/cloudevents/spec/releases)).
  - Required attributes: `id`, `source` (URI-reference), `specversion`, `type`.
  - Optional attributes: `datacontenttype`, `dataschema`, `subject`, `time`.
  - Extensions must be lowercase alphanumeric. Standard ones: `traceparent`/`tracestate` (distributed tracing), `partitionkey` (partitioning), `sequence`.
  - Formats: JSON (required), protobuf (`io.cloudevents.v1.CloudEvent` with `proto_data` for embedded protobuf), Avro. Bindings: HTTP, NATS, Kafka, AMQP, MQTT, WebSockets.
  - **Use CloudEvents as an envelope only.** It says nothing about alert semantics.
- **Alertmanager webhook** (also the shape Thanos Ruler alerts arrive in once routed through Alertmanager) [general knowledge]:
  - Group level: `version: "4"`, `groupKey`, `truncatedAlerts`, `status`, `receiver`, `groupLabels`, `commonLabels`, `commonAnnotations`, `externalURL`.
  - Per alert in `alerts[]`: `status` (firing/resolved), `labels`, `annotations`, `startsAt`, `endsAt` (`0001-01-01T00:00:00Z` while firing), `generatorURL`, `fingerprint`.
  - **One webhook means N events.** Split per alert. Use AM's `fingerprint` (a hash of the labels) as the identity seed.
- **Icinga 2 event streams** (`POST /v1/events`, `types[]`, optional `filter`; older versions also required `queue` [uncertain whether still required]) ([API docs](https://icinga.com/docs/icinga-2/latest/doc/12-icinga2-api/)):
  - Types: CheckResult, StateChange, Notification, Flapping, AcknowledgementSet, AcknowledgementCleared, CommentAdded, CommentRemoved, DowntimeAdded, DowntimeRemoved, DowntimeStarted, DowntimeTriggered, ObjectCreated, ObjectModified, ObjectDeleted.
  - StateChange carries `state`, `state_type` (SOFT/HARD), `check_result`, `downtime_depth`, `acknowledgement`, `host`, `service`.
  - **Implication:** Correlia events are not only "alerts". Acks, downtimes and comments are first-class `kind`s.
  - Map only HARD state changes to alert firing/resolved by default, and keep soft states as `state` events.
- **PagerDuty PD-CEF** [general knowledge]: `summary`, `source`, `severity` (critical/error/warning/info), `timestamp`, `component`, `group`, `class`, `custom_details`, plus `dedup_key` and `event_action` (trigger/acknowledge/resolve). It is the best minimal **semantic** model; Correlia's core fields should be a superset of it.
- **OpenTelemetry semantic conventions v1.45.0** (2026-11-02):
  - Resource attributes `service.name`, `service.namespace`, `service.instance.id`, `host.name`, `host.id`, `k8s.cluster.name`, `k8s.namespace.name`, `k8s.pod.name`, `k8s.node.name`, `cloud.provider`, `cloud.region`, `deployment.environment.name` (renamed from `deployment.environment`).
  - The Logs data model has `SeverityNumber` 1–24 and `SeverityText`, `Timestamp` vs `ObservedTimestamp`, `Resource` vs `Attributes`.
  - **Borrow the naming and the resource/attributes split.**
- **Elastic ECS v9.5.0** [general knowledge on fields]:
  - `event.kind: alert`, `event.severity`, `event.created`/`event.ingested`, `observer.*` (the reporting system), `rule.*`.
  - The useful idea is **`observer` vs `host`**: the system that reported the event is not the thing it is about.
  - Correlia's `source` and `resource` should mirror that split.

### 5.2 Recommended design

**Envelope: CloudEvents 1.0.2, JSON structured mode on the wire.**

| CE attribute | Correlia value |
|---|---|
| `specversion` | `1.0` |
| `id` | **Deterministic** UUIDv5 over (source instance id + raw payload hash + split index), so reprocessing the same raw input yields the same id. Never random. |
| `source` | `/correlia/<tenant>/sources/<source_instance>`, for example `/correlia/default/sources/icinga-prod` (the configured ingest endpoint, not the monitored host) |
| `type` | `io.correlia.<kind>.v1`, where kind is `alert`, `state`, `ack`, `downtime`, `comment` or `heartbeat`. **The major version lives here.** |
| `subject` | The alert fingerprint (lets consumers filter without parsing data) |
| `time` | When the condition happened (source time) |
| `dataschema` | `https://schemas.correlia.dev/event/v1.4.json` (exact minor version) [domain is a placeholder] |
| `datacontenttype` | `application/json` |
| extensions | `traceparent`, `partitionkey` (= fingerprint), `correliatenant` |

**Payload (`data`), schema `correlia.event.v1`:**

- **Identity:**
  - `fingerprint`: the stable identity of the *condition*. Computed by per-source-kind rules: AM fingerprint; Icinga `host!service`; generic JSON uses configurable fields. The result is a SHA-256 over a canonical `source_kind|tenant|identity tuple`, hex-encoded.
  - `dedup_key`: an optional override coming from the source, as with PD-CEF.
  - `correlation_hints[]`: optional keys that plugins or rules add, such as a topology node id.
- **Status:**
  - `status`: firing, resolved or info (for one-shot events). Kept separate from severity.
  - Ack, downtime and suppression are separate event kinds and state flags, not statuses.
- **Severity:**
  - `severity`: normalized enum `critical | error | warning | info | unknown`, aligned with PD-CEF.
  - `severity_number`: OTel 1–24 for sorting.
  - `severity_original`: the raw text, for example `HARD CRITICAL`, `P2` or `disaster`.
- **Text:** `summary` (required, one line), `description`.
- **Resource (what the event is about):** `resource{}` as a flat map of OTel keys (`host.name`, `service.name`, `k8s.*`, `cloud.*`, `deployment.environment.name`), plus Correlia-specific `correlia.check.name` and `correlia.site`.
- **Observer (who reported it):** `observer{kind: icinga2|alertmanager|..., instance, version, url}`.
- **Labels:** `labels{}` as string→string. These are the routing and grouping dimensions: original source labels plus inferred tags, with a `labels_origin{key: source|rule:<id>|plugin:<name>}` sidecar for explainability.
- **Annotations:** `annotations{}` for free text (runbook, dashboard).
- **Links:** `links[]` of `{rel: runbook|dashboard|source|silence, href, title}`.
- **Timestamps:** `starts_at`, `ends_at` (null while firing), `observed_at` (when Correlia received it), `processed_at`.
- **Raw:**
  - `raw{ref: "urn:correlia:raw:<uuid>", sha256, size, content_type}`, pointing at the Postgres raw inbox row.
  - Optional `raw.inline` only when small (under about 16 KB) and the output requests it.
  - Don't put the raw payload in every event by default.
- **Pipeline provenance:** `pipeline{version, stages_applied[], enrichment_errors[]}`.
- **Extensions:** `extensions{}` as a namespaced map (`<plugin>.<key>`) for plugin-specific data. It prevents schema pressure.

**Versioning rules:**

1. **Protobuf is the source of truth** (`proto/correlia/event/v1/event.proto`). Generate JSON Schema from it and publish both.
   - **Set explicit `json_name` in snake_case on every field**, or accept lowerCamelCase. proto3 JSON defaults to lowerCamelCase, and CloudEvents-world consumers expect snake_case.
   - Other proto3 JSON rules: `int64` is serialized as a string, `Timestamp` as RFC 3339, enums by name. Prefer string enums in JSON and add `UNSPECIFIED = 0`.
2. **Schema semver:**
   - **Minor (additive):** new optional fields, new enum values (consumers must treat unknown values as `unknown`), new label conventions. Bump the `dataschema` URL only.
   - **Major:** rename, removal, or a semantic change. Change the `type` to `.v2` and the subject prefix to `correlia.v2`, and dual-publish during migration.
3. **Never reuse or renumber field numbers, and never change field types.** Use `reserved` for removed fields. Enforce this with `buf breaking` in CI.
4. Consumers must ignore unknown fields. Correlia itself preserves unknown fields when it relays events.

---

## 6. Enrichment pipeline design

### 6.1 Stages

`ingest → persist raw → decode → normalize → enrich → classify → route → (correlate) + (outbox → outputs)`

1. **Ingest:**
   - The HTTP route (Serverpod Relic route `/hooks/<source_kind>/<source_instance>`) authenticates per source with a token or HMAC.
   - It writes the raw body to `raw_inbox` (id, source, received_at, sha256, body, headers subset) and returns **202 quickly**. Nothing else runs synchronously.
   - Pull sources (Icinga event stream, source plugins) write to the same table.
2. **Decode / parse** (per source kind; built-in or decoder plugin): raw → 0..N proto-shaped events. Splitting happens here (an AM group becomes N alerts).
3. **Normalize:** map severity and status, compute the fingerprint, set timestamps, map source fields onto OTel resource keys.
4. **Enrich** (ordered rules, then enricher plugins; each produces patches):
   - **Regex extraction** with named groups, for example `host.name` `^(?<site>[a-z]{3})-(?<role>[a-z]+)\d+` → labels `site` and `role`.
   - **CIDR maps:** an IP attribute → `site`/`network`/`zone` via a longest-prefix-match table.
   - **Lookup tables / CMDB:** key → attributes (owner team, tier, business service). Sync CMDB data into a Postgres table on a schedule; never call a CMDB inline per event. Cache in memory with a version stamp.
   - **Topology:** attach `correlia.topology.node_id` and parents for the correlation engine.
   - **Conditional rules (`when` + `set`):** use CEL expressions. **Dart CEL is weak:**
     - `cel` 0.6.1 (atn832/cel-dart, 5 stars) is a "simplified port" with runtime-only type errors and no timestamps, durations or type conversions.
     - Options: (a) start with a small declarative matcher (equals / regex / in-list / CIDR / exists, combined with all/any) that covers 90% of cases, then add CEL later; (b) contribute to cel-dart; (c) run cel-go inside a Go "rules" plugin.
     - **Recommendation: (a) now, and keep CEL as the documented future syntax** so rule storage can migrate.
5. **Classify:** assign `kind` (alert/state/...), noise flags, maintenance (an active downtime for the resource) and priority.
6. **Route:** decide which outputs receive the event and which correlation pipeline it enters. Express routes as matcher rules over labels and resource (OTel Collector "routing connector" style).

**Where plugins hook in:** Source (stage 1), Decoder (2), Enricher (4, after built-in rules, in a configured order), Output (after route). Plugins don't get Normalize or Classify in v1. Keep the semantics in the core, so a buggy plugin can't redefine severity or identity. An enricher's patches may not touch `fingerprint`, `id` or `status`; the host enforces this.

### 6.2 Delivery semantics

- **Idempotency:**
  - `raw_inbox` is unique on (source, sha256, received bucket), which catches webhook retries.
  - The event `id` is deterministic, so re-running the pipeline produces the same ids.
  - Upserts into `alerts` are keyed on fingerprint with a monotonic guard: apply only if `observed_at`/`starts_at` is newer, so an old `resolved` can't override a newer `firing`.
  - Outputs dedupe on `id` (NATS via `Nats-Msg-Id`).
- **Ordering:**
  - Guarantee **per-fingerprint order only.** Workers claim work by `hash(fingerprint) % N` lanes, or by advisory lock per fingerprint, with `SELECT … FOR UPDATE SKIP LOCKED LIMIT batch`.
  - There is no global order. Document this.
  - Per-output relays deliver in outbox sequence per partition key.
- **Back-pressure:**
  - Bounded in-memory queues between stages.
  - Credit windows to plugins (N unacked batches).
  - At ingest, if `raw_inbox` lag exceeds a threshold, return **429/503 with Retry-After**. Alertmanager and most webhook senders retry, so pushing back beats dropping.
  - A slow output must never block ingest or correlation: each output has its own outbox cursor and its own lag metric.
- **Dead letters:**
  - `pipeline_failures(raw_id, stage, error, attempts, last_attempt, payload_snapshot)` for decode and enrich failures after N retries.
  - `outbox` rows that exceed max attempts for an output move to `outbox_dead`.
  - The console shows both, with **replay**: re-enqueue the raw input with the current rules, which is safe because ids are deterministic.
  - Enrichment failures should be **soft**: emit the event with `pipeline.enrichment_errors[]` rather than dead-lettering it. Only decode failures are hard.
- **At-least-once outputs via a transactional outbox:**
  - The same Postgres transaction that commits the processed event (and the alert-state upsert) inserts one `outbox(output_id, seq bigserial, event_id, partition_key, payload jsonb, attempts, next_attempt_at)` row per routed output.
  - A relay per output reads `WHERE output_id=$1 AND next_attempt_at<=now() ORDER BY seq LIMIT batch FOR UPDATE SKIP LOCKED`, wakes on `LISTEN/NOTIFY`, delivers to the in-process or plugin output, and deletes or marks rows on ack. Failures back off exponentially.
  - Partition outbox tables by time, or delete on ack, so they stay small.
  - This gives at-least-once delivery with no XA and no dual-write bug.

---

## 7. Suggested spikes before the plan is final

1. **Dart host ↔ stock Go go-plugin plugin with AutoMTLS** (P-521 certificate, `ChannelCredentials` subclass for the client certificate), on Linux UDS and Windows TCP. **Half a day; it decides whether "stock go-plugin compatible" is real.**
2. **Python plugin via the SDK sketch:** handshake, health, Shutdown, stdin-EOF exit, and JSON stderr logs.
3. **Windows orphan test:** kill the host with Task Manager and check whether the plugins die. Decide between a Job Object via FFI and SDK stdin-EOF.
4. **Outbox relay throughput** on embedded Postgres: target at least 2k events/s on a laptop [target is a guess].

## Sources

- go-plugin: [repo](https://github.com/hashicorp/go-plugin) (`server.go`, `client.go`, `mtls.go`, `internal/plugin/grpc_{broker,controller,stdio}.proto`, read 2026-11-03), [internals.md](https://github.com/hashicorp/go-plugin/blob/main/docs/internals.md), [non-Go guide](https://github.com/hashicorp/go-plugin/blob/main/docs/guide-plugin-write-non-go.md), [releases](https://github.com/hashicorp/go-plugin/releases), ctx7 `/websites/deepwiki_hashicorp_go-plugin`.
- Terraform: [plugin protocol](https://developer.hashicorp.com/terraform/plugin/terraform-plugin-protocol), [dependency lock file](https://developer.hashicorp.com/terraform/language/files/dependency-lock).
- Non-Go implementations: [grr-plugin](https://lib.rs/crates/grr-plugin), [magma-plugin](https://docs.rs/magma-plugin/0.1.20/magma_plugin/), [terustform](https://git.noratrieb.dev/Noratrieb/terustform/commit/18a9d610cdc257b9193dee617d3bd92de171c9c2).
- Redpanda Connect: [plugins](https://docs.redpanda.com/redpanda-connect/plugins/about/), [multi-language plugins blog](https://www.redpanda.com/blog/multi-language-redpanda-connect-plugins); release v4.116.1 (GitHub API).
- Extism: [host SDKs](https://extism.org/docs/concepts/host-sdk), [component model issue](https://github.com/extism/extism/issues/666). wasmtime v50.0.1 (GitHub API).
- NATS: [services](https://docs.nats.io/learn/services/), [ADR-32](https://github.com/nats-io/nats-architecture-and-design/blob/main/adr/ADR-32.md), [dart-nats](https://github.com/dart-nats/dart-nats) README and CHANGELOG; nats-server v2.15.2 and nats.go v1.55.0 (GitHub API).
- grpc-dart: [CHANGELOG](https://github.com/grpc/grpc-dart/blob/master/CHANGELOG.md), `lib/src/client/transport/http2_credentials.dart`, ctx7 `/websites/deepwiki_grpc_grpc-dart`.
- Dart SDK: [CHANGELOG](https://github.com/dart-lang/sdk/blob/main/CHANGELOG.md) (3.11.0 Windows AF_UNIX), [issue #41161](https://github.com/dart-lang/sdk/issues/41161).
- pub.dev API: grpc 5.2.0, protobuf 6.1.0, protoc_plugin 25.1.0, dart_nats 1.7.0, nats_for_dart 0.3.0, natsio 0.1.1, wasm_run 0.2.0+2, cel 0.6.1, serverpod 4.1.0.
- CloudEvents: [releases](https://github.com/cloudevents/spec/releases), [NATS binding](https://github.com/cloudevents/spec/blob/main/cloudevents/bindings/nats-protocol-binding.md).
- Icinga 2: [API / event streams](https://icinga.com/docs/icinga-2/latest/doc/12-icinga2-api/).
- OTel semantic conventions v1.45.0 and Elastic ECS v9.5.0 (GitHub releases API). Field lists for OTel, ECS, PD-CEF and the Alertmanager payload are from general knowledge and not re-read today.
- cel-dart: [README](https://github.com/atn832/cel-dart).
