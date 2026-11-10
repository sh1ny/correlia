# Review

## Metadata

- **Round:** 2
- **Prior round:** Round 1 returned APPROVE_WITH_CHANGES with six Required Changes (M1–M6), no Critical findings, and CHANGES_APPLIED: no.
- **Reviewer:** cross-model CLI (claude route, claude-opus-5-5)
- **Reviewed:**
  - Change artifacts: `openspec/changes/plugin-host-spike/{proposal.md, design.md, specs/external-plugin-host/spec.md, review.md (round 1)}`
  - ADRs: `docs/adr/0014`, `0018`, `0020`, `0021`
  - `openspec/architecture.md` (plugin sections)
  - Config: `buf.yaml`
  - Tooling source: `tool/lib/src/proto_command.dart` (lines 60–380), the package filters in `tool/lib/src/contract_compatibility.dart:202-203` and `tool/lib/src/bounds_extractor.dart:124-125`
  - Event source: `correlia_server/lib/src/event/cloud_event.dart` (`toJsonBytes`)
  - The upstream go-plugin source is outside the readable workspace. Claims about it below are marked as inferences. No store references needed resolving.

<!-- This verdict covers only the contents reviewed. Editing proposal, specs or design afterward (other than applying Required Changes, or an edit confined to the proposal's `## Release Notes` section) voids it. -->

## Findings

### Critical (blocking)

None.

### Moderate

None open. I re-checked each round-1 Moderate against the amended artifacts. History:

**M1 (resolved).** The upstream interoperability declarations would have failed the existing `buf lint` gate.
- D3 now specifies hand-coded Dart `ClientMethod` descriptors and minimal codecs, with no upstream `.proto` files or copied schemas.
- D5 states that no upstream schemas enter the linted `proto` Buf module, that `correlia.plugin.spike.v1` passes STANDARD lint, and that the event `proto:check` and baseline stay unchanged.
- The Risks bullet "Existing event generation scans `proto`" was updated to match.

I checked this against the code:
- `proto_command.dart:92` runs `buf lint` over the single module in `buf.yaml:3`.
- Adding new files does not trip `buf breaking` with the FILE rule (`proto_command.dart:115-126`).
- `compareContractDescriptors` filters on `correlia.event.v1` (`contract_compatibility.dart:203`), and so does bounds extraction (`bounds_extractor.dart:125`).
- The event stage copies only `dart/correlia/event/v1` outputs (`proto_command.dart:235-244`).

So a STANDARD-clean `correlia.plugin.spike.v1` file under `proto/` does not disturb the event gates. Bidirectional streaming is not banned by STANDARD.

**M2 (resolved).** A criterion-2 failure used to take criteria 1 and 3 down with it.
- D2 now records criterion-1 handshake parsing, negotiation and socket connection independently of TLS.
- D2 also gives the criterion-3/4 harnesses an explicit security-mode parameter. The diagnostic mode is never an automatic retry or an adoption decision, and the evidence names the mode for each criterion.
- Risks and Failure & Visibility ("record parsed-handshake evidence before TLS") are consistent with this.
- The spec's "Reproducible spike verdict" adds "Handshake evidence SHALL survive TLS failure" and the scenario "TLS feasibility fails independently".
- "A failed authentication SHALL NOT trigger plaintext retry" is kept.

S9 below covers a residual ambiguity about criterion 1's pass condition.

**M3 (resolved).** The fixed 30 s per-stream deadline could kill healthy streams. The Resource Bounds gRPC row now has:
- a 10 s stream-open/first-response deadline;
- a 10 s ack-progress deadline while batches are outstanding;
- explicitly "no whole-stream deadline or idle timeout with no outstanding work".

This agrees with the 10x/100x claims. S8 below covers a small wording ambiguity.

**M4 (resolved).** The socket mode check was underspecified.
- D3 defines the check: the attempt directory is mode 0700 and owned by the current uid; the announced path resolves inside it to a socket owned by that uid with no group or other write bits; the actual mode is recorded.
- Flow & State Gaps and Risks state that a stock mode differing from ADR 0020's "0600" wording goes to the owner and is not repaired by chmod or by modifying the plugin.

**M5 (resolved).** The criterion-4 evidence could pass for the wrong reason.
- (a) D4 and the Flow section launch the resolved Dart executable or an AOT binary directly, with no `dart run` or `timeout` wrapper. The plugin's PPid is asserted to equal the host PID before SIGKILL.
- (b) "Exit" is defined as `/proc/<pid>` absent, or the same start identity in state `Z`.
- (c) The watcher writes and flushes a distinct EOF exit-cause marker. The spec's "Host is killed" THEN requires the confirmed parent, the defined exit state and the marker, with no teardown signal before the assertion.

The marker makes the evidence sound even if something does write to fd 1/2 after the handshake. A SIGPIPE death would produce no marker, which is a visible false failure, not a false pass.

**M6 (resolved).** Ownership of the in-flight map contradicted itself.
- D4 now says "The delivery owner alone mutates pending events and the in-flight map". A generation holds only its epoch, next sequence and credit counter, and reports to the owner.
- On the first terminal event, the owner retires the epoch and moves the generation's outstanding batches back to pending once.
- The State & Ownership table splits these into separate rows: "Epoch, sequence, credit counter" owned by the stream generation with "no map mutation from callbacks", and "In-flight batch map" owned by the delivery owner. Flow & State Gaps matches.

S11 below covers a remaining derived-state detail.

### Suggestions

**Round-1 suggestions, all addressed by the amendments:**
- S1 (certificate encoding and context): fixed in D2. The design specifies unpadded standard base64 of DER, PEM-wrapping, `withTrustedRoots: false`, authority `localhost`, no accept-all callback, and a `ChannelCredentials` subclass if needed.
- S2 (grpc resolution gate): fixed in D2. Failure to resolve without dependency overrides is a stop-and-report feasibility failure.
- S3 (acknowledgement stall): fixed. The spec adds the scenario "Receiver never acknowledges", whose THEN is assertable.
- S4 (partial-batch flush): fixed in the Batch row.
- S5 (digest journal): fixed in D4 and the journal bounds row. Records are id plus SHA-256, epoch and sequence; reconciliation rejects torn records and covers duplicates.
- S6 (barrier transport): fixed in D4 with a test Unix control socket and explicit release. The bounds row allows one 8 KiB frame in each direction per barrier.

**New in round 2 (none blocking):**

**S7. The diagnostic mode requires exact 0600 but names no stock way to get it.** Flow & State Gaps says "Diagnostic plaintext mode additionally requires exact 0600". The design forbids chmod and plugin modification, and its own Risks bullet expects that the stock mode may not be 0600.

Inference: stock go-plugin binds the socket under the inherited umask and only chmods when a socket group is configured. Under a typical umask of 022 the socket would be 0755, so the diagnostic runs for criteria 3/4 would fail the precondition every time. That is the one branch where M2 needs them.

Recommendation: name the mechanism. For example, the test operator launches the host, and through it the plugin, with an inherited umask of 0177 so the socket comes out 0600. This is environment, not plugin modification. Record the umask with the evidence. If 0600 is still not observed, the diagnostic run fails with the observed mode recorded.

**S8. "First-response" is ambiguous on a bidirectional stream.** If it means the first acknowledgement message, a stream opened before any batch is sent would time out while idle, which contradicts "no … idle timeout with no outstanding work". Define it as receipt of response headers, or open `Deliver` only when there is pending work so the ack-progress deadline covers the first response.

**S9. Criterion 1's pass condition under TLS failure is undefined.** The "Plain stock plugin startup" THEN requires SERVING health and a completed application RPC. Under D2 these run only in the selected security mode, and the diagnostic mode is defined only for criteria 3/4.

When criterion 2 fails, it is unclear whether criterion 1 passed, which contradicts "report the four criteria independently". Either:
- state that criterion 1 passes on handshake parse, negotiation and socket connection (ADR 0020 says "completes the handshake"), with health/RPC recorded per security mode; or
- add the plain-stock fixture to the explicitly selected diagnostic runs.

**S10. The crash barrier needs arming and configuration rules.** The restarted plugin may start a fresh epoch at the same sequence. If the barrier is keyed by sequence, it would block or be killed again after restart.
- Arm the barrier for exactly one configured batch in the first launch only, for example through a launch argument given only to that process.
- Have the observer release any later barrier.
- D3's "minimal inherited environment plus explicit cookie, versions, host certificate and private socket directory" leaves no channel for the journal and control-socket paths. Name one, either fixture argv or an explicit test-only environment allowlist.

**S11. Derive the credit counter from the owner's map.** Credits equal the window minus the current epoch's in-flight count. If the generation keeps its own counter, an implementer can increment it on raw ack receipt before the owner validates the ack, which creates an extra credit (spec "Invalid acknowledgement"). Either derive credits from the owner's in-flight map for the current epoch, or state that the generation releases a credit only on the owner's validated-ack notification.

## Verdict

All six round-1 Required Changes are present in design.md and spec.md and are internally consistent. The amendments to D2 (certificate encoding, context, dependency-resolution failure) and D4 (digest journal, control socket), and the new acknowledgement-stall scenario, introduce no Critical or Moderate contradictions with ADRs 0014, 0018, 0020, 0021, the architecture doc or the tooling code. The remaining items are Suggestions.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

These are the round-1 Required Changes. Round 2 re-checked each one and found it applied:

1. **(M1)** Upstream interoperability declarations stay out of the linted `proto` Buf module. Correlia-owned `correlia.plugin.spike.v1` passes STANDARD lint, and the event `proto:check` is unchanged. Applied in D3, D5 and Risks.
2. **(M2)** Evidence for each criterion is independent:
   - handshake evidence survives TLS failure;
   - the criterion-3/4 harnesses take an explicit security mode, and the diagnostic mode is never automatic or adopted;
   - the spec has the scenario "TLS feasibility fails independently".

   Applied in D2, Risks, the spec requirement and its scenario.
3. **(M3)** The whole-stream 30 s deadline is replaced by a stream-open/first-response deadline plus the ack-progress deadline. Applied in the Resource Bounds gRPC row.
4. **(M4)** The socket check is defined exactly (attempt directory, uid, type, mode bits), the observed mode is recorded, and an ADR wording mismatch is escalated to the owner. Applied in D3, Flow and Risks.
5. **(M5)** Criterion-4 evidence:
   - (a) direct launch and the PPid assertion;
   - (b) the definition of exit;
   - (c) the flushed EOF exit-cause marker.

   Applied in D4, Flow and the spec's "Host is killed" scenario.
6. **(M6)** The delivery owner is the sole writer of the pending set and the in-flight map, and retires an epoch and returns its batches once. Applied in D4, State & Ownership and Flow.

CHANGES_APPLIED: yes

## Rebuttals

The author recorded no rebuttals. The round-1 findings M1–M6 were fixed as cited above. The round-2 suggestions S7–S11 are open and optional.