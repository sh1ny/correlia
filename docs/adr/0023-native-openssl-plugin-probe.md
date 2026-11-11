# 0023. Experimental output probe with an in-process OpenSSL transport

- Status: accepted (2026-11-11), for the experimental spike only
- Date: 2026-11-11
- Supersedes: [0022](0022-experimental-output-plugin-probe.md) in full
- Chosen by: agent; D24, acceptance of the criterion-2 interpretation and production adoption remain owner-only

## Context

ADR 0022 separated the output probe from the production plugin protocol and prescribed an identity-bearing
Dart `SecurityContext`. The pinned Dart runtime can load its P-521 identity but its TLS 1.3 ClientHello
omits signature scheme `0x0603`, required by the stock Go server for that certificate. That built-in path
failed; its failure remains evidence rather than being overwritten by a later result.

An original Dart prototype using the system OpenSSL 3 ABI completed a protected generated application RPC
over TLS 1.3 to unmodified go-plugin v1.8.0. It rejected a wrong server pin, an absent client identity and a
wrong client identity, then completed another valid RPC. This establishes feasibility of an alternative
in-process transport, not completion of the permanent tests, delivery/lifetime gates or owner checks.

The new mechanism cannot satisfy 0022's literal `SecurityContext(withTrustedRoots: false)` instruction.
Accepted ADRs are immutable, so this decision restates the probe boundary and supersedes 0022 wholly.
It retains its protocol, stock compatibility, canonical bytes, bounded surviving-host guarantee and owner
gates; the changed TLS mechanism and its verification boundary are explicit below. ADRs 0014, 0018, 0020
and 0021 remain in force.

## Decision

### An unstable, output-only probe

`correlia.plugin.spike.v1`, under `proto/correlia/plugin/spike/v1/`, remains Correlia-owned and unstable.
It is not `correlia.plugin.v1`, not a preview of that contract and not a plugin SDK.

- One bidirectional `Deliver` RPC carries batches of event ids and canonical structured-JSON bytes.
  Whole-batch acknowledgements carry a connection epoch and batch sequence; no partial outcomes.
- Epochs change per connection; sequences never repeat in an epoch. Stale callbacks are fenced out;
  unknown or repeated current-epoch acknowledgements fail the connection without creating credits.
- No source, decoder, enricher, config, metadata or patch protocol is published. Service names, fields
  and acknowledgement shape have no compatibility promise beyond this experiment.
- No durable queue, registry, lock file, status persistence or restart policy is introduced. Production
  supervision, distribution and the complete protocol belong to later changes.

### Stock interoperability and independently reported evidence

The four ADR 0020 criteria remain separate observations:

1. Handshake with an unmodified Go plugin built on stock `plugin.Serve()`.
2. Bidirectional P-521 AutoMTLS, with the built-in failure distinguished from the grpc-dart custom
   connector's OpenSSL result.
3. Credit-controlled batched delivery of 10,000 events with plugin-crash redelivery.
4. Host SIGKILL followed by verified stdin-EOF exit of a fixture wrapping stock serving with ADR 0018's
   watcher. No orphan guarantee is claimed for a plain stock plugin without that watcher.

The mapped positive startup test uses default AutoMTLS through SERVING health and an application RPC.
A failed TLS attempt retains its parsed negotiation and observed socket facts as partial evidence, not a
successful authenticated startup. Each criterion records commands, versions, security mode, result and
failure cause; no diagnostic result changes a failed security result into a pass.

- Pin unmodified go-plugin v1.8.0 with module checksums. No fork, patch or vendored upstream source.
  Plain-stock and stdin-watched executables share the original generated application service.
- Keep original hand-coded upstream compatibility descriptors outside the Buf module. Copy no upstream
  schema, implementation or template into this repository.
- Preserve `correlia.event.v1`, its frozen v1.0 baseline and isolated event generation. Only the separate
  experimental plugin stage generates gRPC output.

### In-process native TLS, not a proxy or downgrade

The Dart host owns the transport through grpc-dart's custom connector and http2 stream interface. Original
narrow FFI bindings use the system `libssl.so.3` and `libcrypto.so.3`, with `ffi` 2.2.0. No Go proxy,
OpenSSL command-line bridge or bundled native source is used by the host.

- Resolve required native symbols eagerly before network acquisition or per-connection native allocation;
  require OpenSSL major 3. Missing libraries/ABI fail startup and clean the attempt.
- Require a minimum of TLS 1.3 for this spike so the P-521 signature path that failed is exercised rather
  than bypassed with TLS 1.2. Observe both certificates' public-key groups and the actual protocol/backend.
- Decode the handshake's unpadded standard-base64 DER. Use a fresh pin-only trust/verification store,
  verify the certificate and `localhost` name, compare peer DER exactly, and require ALPN `h2`. No OS
  roots, accept-all callback, substituted verifier or verification-disabled option.
- Clear inherited client identity material and install only the caller's certificate and matching key.
  An absent/wrong client or wrong server pin fails the protected RPC without plaintext retry.
- Retain OpenSSL's default system/`OPENSSL_CONF` policy, explicitly applying the required trust, identity
  and protocol profile after context creation. Record the selected configuration source/default directory
  and `OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE` and `OPENSSL_MODULES` selections, not their file contents.
  A host configuration preventing the required profile fails visibly rather than passing at a lower
  protocol or with broader trust.
- Wait for peer HTTP/2 SETTINGS against original transport failure within startup's deadline. Client-local
  TLS 1.3 completion alone does not prove the Go server accepted the client identity.

The native engine owns its SSL context/session, BIO pair and staging. An event-driven socket adapter owns
raw I/O, queued plaintext, pending ciphertext and subscriptions. The BIO pair is bounded to 32 KiB per
direction; native staging uses three 16 KiB buffers and ciphertext staging one 16 KiB Dart buffer.
Credentials/DER/accepted chains are capped at 16 KiB each, and queued plaintext at 256 KiB per connection.
These bound the adapter, not OpenSSL's entire per-connection cryptographic heap.

Pause upstream `addStream` input at capacity and stop raw reads when the consumer pauses or the inbound
BIO is full. Preserve identical native plaintext across WANT retries and pending ciphertext across partial
writes. Reject an oversized chunk or overflowing direct admission before accepting it. Partial native
initialization, deadlines, close and late acquisitions release their resources without depending on a
paused or absent listener. No blocking native network I/O, arbitrary sleeps or polling loops.

### Authenticated-only public surface and isolated verification

The curated `plugin.dart` export exposes only authenticated host construction/configuration and observed
evidence. Its identity is required; its advertised certificate derives from that identity. Public plaintext,
umask opt-out, pin override and separate advertised-certificate switches are removed without shims.

A private constructor and internal top-level harness factory, not an exported class member or public
configuration, select negative/diagnostic cases and acquisition controls. Native fault selection can only
cause an actual load or ABI failure against the genuine system backend; it cannot return a substitute
library. A capability probe narrows actual signature support and cannot disable verification. These
controls are not operator/environment settings or automatic fallbacks.

Real-process tests cover default authenticated negatives, inbound/outbound backpressure and byte identity,
partial initialization, late socket/process/directory receipts and TLS/HTTP2 readiness deadlines. An original
mutual-TLS byte peer may isolate adapter behavior; it never substitutes for stock-plugin acceptance.
Original native allocation hooks run only in a separate cold test process, before OpenSSL initialization,
with warmed-cache live-allocation comparisons and independent tracking of real Dart-side native staging.
A C compiler and OpenSSL development headers are test prerequisites, not host runtime dependencies.

### Ephemeral credentials and socket ownership

The original Go standard-library helper issues P-521 test identities into current-uid-owned, owner-only
scratch. It is not production issuance or a production certificate dependency. No private key is committed
or logged, and test credentials are not reused across plugin attempts; scratch is removed after its exact
processes and connections exit. No production Dart certificate-issuance claim follows from the probe.

The host owns one child, channel, stdin and subscriptions; stdin remains open without writes. Select only
explicit environment values and fixture argv. Default launches use `umask 0177` followed by `exec`, retaining
the direct child PID. Require an owner-only attempt directory and a current-uid-owned socket inside it
without group/other write bits. Record inherited/effective umasks and actual mode; separately observe stock
under the inherited umask for the owner. Do not call the hardened mode an intrinsic stock permission or
repair a socket with chmod. Controlled unsafe umasks belong only to the internal negative harness.

### Immutable canonical bytes and bounded surviving-host pending work

- Admit validated canonical envelopes with matching ids, snapshotting bytes before ownership transfers.
  Re-batching and restart retain byte-identical payloads and unchanged ids; no id gains different bytes.
- Admission is bounded to 1,024 events and 16 MiB; batches to 64 events and 1 MiB; outstanding batches to
  four; encoded gRPC messages to 2 MiB. At capacity, backpressure or explicit rejection applies rather
  than unbounded buffering. Stop/cancellation release blocked admissions with errors.
- The delivery owner alone mutates pending and in-flight maps. Derive credits from the current epoch's
  outstanding map; only validated acknowledgements release credit and complete events. The first terminal
  event retires the epoch and returns its outstanding work to pending once; failed restart retains it.
- A receiver records complete batches with id/digest/epoch/sequence and flushes before ack. A first-launch
  one-shot barrier enables an exact pre-ack crash. Reconcile the whole id/payload-digest set, including
  permitted duplicates, and reject torn journal evidence. Acknowledged work is never replayed.
- The guarantee is at least once in the surviving host, not exactly once or durable across host death.
  Acknowledgement-progress deadlines apply while work is outstanding; no whole-stream/idle deadline ends
  healthy progressing or empty delivery. Production durable delivery remains outside this probe.

### Production interpretation and fallback remain owner decisions

This decision authorizes the experimental mechanism and its verification, not production adoption.

- The built-in Dart TLS result remains failed. A passing custom connector result is labelled as such.
  Whether that satisfies ADR 0020's phrase "client certificate presented by grpc-dart", including the
  system native dependency, is reviewed by the owner in task 5.5 together with D24.
- D24's production Unix-socket transport and stock permission evidence remain owner-only. Automated tests
  never tick that check or grant either interpretation or transport approval.
- An explicitly selected internal diagnostic mode may gather criteria 3/4 evidence over an exact-0600
  socket without AutoMTLS. It is not a criterion-1 pass, security fallback adoption or unblocking decision.
- Any security fallback or production transport change requires its owner-approved superseding ADR and
  renewed review. A failed gate is preserved and dependent production plugin work remains blocked until
  fixed or explicitly dispositioned. Passing experimental runtime results alone do not settle owner gates.

## Consequences

The spike keeps the original unstable output boundary and bounded at-least-once guarantee while testing an
in-process solution to the observed P-521 incompatibility. It adds an explicit OpenSSL 3 runtime dependency
and native ownership/retry verification, without changing stock Go serving or publishing the production SDK.
The public API cannot accidentally select diagnostic plaintext or a test verifier. System configuration and
both permission-launch policies remain visible in evidence instead of being assumed. The accepted 0022
file stays unchanged as historical context; this whole restatement replaces it in the in-force index.
