# Tasks

## Test map

Paths are relative to the code repository. All new scenarios start red; a task turns its rows green only after executing their named tests. Tests below cross the actual process/gRPC boundary, including deliberately broken fixtures. Evidence tasks capture observed results, never planned outcomes.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| Stock subprocess handshake | Plain stock plugin startup | correlia_server/test/plugin/plugin_host_test.dart | plain stock plugin negotiates and serves | red |
| Stock subprocess handshake | Invalid or stalled startup | correlia_server/test/plugin/plugin_host_test.dart | invalid startup fails bounded and reaps own child | red |
| Mutual authentication without silent downgrade | Authenticated Unix socket exchange | correlia_server/test/plugin/plugin_host_test.dart | mutual P-521 authentication protects application RPC | red |
| Mutual authentication without silent downgrade | Unauthorized peer or unsupported cryptography | correlia_server/test/plugin/plugin_host_test.dart | unauthorized peers fail without plaintext retry | red |
| Bounded acknowledged delivery | Receiver withholds acknowledgements | correlia_server/test/plugin/plugin_delivery_test.dart | withheld acknowledgements bound sends to credits | red |
| Bounded acknowledged delivery | Invalid acknowledgement | correlia_server/test/plugin/plugin_delivery_test.dart | invalid acknowledgements cannot complete work or create credits | red |
| Bounded acknowledged delivery | Receiver never acknowledges | correlia_server/test/plugin/plugin_delivery_test.dart | stalled receiver times out retaining outstanding work | red |
| Plugin crash redelivery | Ten thousand events with an uncertain batch | correlia_server/test/plugin/plugin_delivery_test.dart | 10000 events reconcile after pre-ack plugin crash | red |
| Plugin crash redelivery | Restart cannot become ready | correlia_server/test/plugin/plugin_delivery_test.dart | failed restart retains immutable pending events | red |
| Child lifetime and shutdown | Host is killed | correlia_server/test/plugin/plugin_lifecycle_test.dart | host SIGKILL yields verified stdin-EOF child exit | red |
| Child lifetime and shutdown | Shutdown does not cooperate | correlia_server/test/plugin/plugin_lifecycle_test.dart | uncooperative child is forcibly stopped and reaped | red |
| Reproducible spike verdict | All runtime criteria pass | correlia_server/test/plugin/plugin_gate_test.dart | gate report reconciles four observed passing criteria without owner approval | red |
| Reproducible spike verdict | A criterion fails | correlia_server/test/plugin/plugin_gate_test.dart | observed gate failure prevents a passing spike verdict | red |
| Reproducible spike verdict | TLS feasibility fails independently | correlia_server/test/plugin/plugin_gate_test.dart | explicit diagnostic run preserves failed TLS verdict and independent evidence | red |

## 1. Experimental contract and reproducible fixture build

- [x] 1.1 Record the additive experimental-output ADR described in design D5, using the next available ADR number; update the architecture index and plugin boundary description without editing accepted ADRs. Verify the ADR names the experimental namespace, four gates, non-production credential helper and owner-only transport/fallback decisions, and run strict OpenSpec validation.
- [x] 1.2 Add the minimal Correlia-owned spike protobuf, pin a protobuf-6-compatible grpc dependency and Dart/Go generators, and create the Go fixture module pinned to stock go-plugin v1.8.0 with checksums. Verify dependency resolution without overrides, STANDARD lint, and building the original fixture/helper code through mise; stop and report incompatible dependencies rather than changing unrelated workspace constraints.
- [x] 1.3 Extend existing proto generation/check stages with isolated plugin inputs/outputs, leaving upstream compatibility methods as original hand-coded Dart descriptors outside Buf. Verify repeated generation produces identical outputs, scratch drift checks catch changed/missing/extra plugin outputs, existing event contract checks pass and the frozen event-v1.0 baseline is untouched; document regeneration in the existing developer documentation.
- [x] 1.4 Add suite-owned fixture build/scratch support and distinct plain-stock and stdin-watched executables, plus original ephemeral P-521 credential helper, journal/control-socket test support and exact-process cleanup. Verify binaries build once per suite, credentials are owner-only, and a throwaway launch/cleanup removes only this suite's files and children; document fixture modes and the no-third-party-copying boundary alongside the fixtures.

## 2. Stock startup and authenticated gRPC

- [ ] 2.1 Write failing real-process tests for the four plugin_host_test.dart rows; cover wrong cookie, incompatible version, malformed/oversized/incomplete handshake, child exit, stalled health, unsafe socket path/ownership/mode, wrong server pin and absent/wrong client identity. Verify each fails for the missing behavior, using barriers and injected deadlines instead of sleeps.
- [ ] 2.2 Implement bounded startup/lifecycle ownership, environment selection, handshake parsing and independent handshake evidence under lib/src/plugin/, with the experimental plugin.dart surface. Verify plain-stock negotiation and invalid startup rows pass, all failed attempts clean their own children, bounded diagnostics drain without blocking, and observed stock socket mode is reported rather than repaired.
- [ ] 2.3 Implement identity-bearing Dart TLS credentials, exact certificate pinning, health/controller/stdio compatibility methods and the protected application exchange. Verify both TLS rows pass against the stock executable, including P-521 and negative identities; if feasibility fails, keep criterion 2 failed and report the cause without automatic downgrade. Turn the four mapped rows green only on observed passes.
- [ ] 2.4 Document startup/security guarantees and errors, stdin ownership, diagnostic-only mode selection and dependency limitations in the existing developer documentation and public API docs. Verify documented examples launch the real fixture, and targeted analysis/formatting pass for the changed Dart surface.
- [ ] 2.5 [evidence] Capture criterion 1 and 2 commands, Linux/tool/dependency versions, parsed negotiation, observed socket mode, positive/negative TLS results and any independent failure; redact private keys and retain actual failures → evidence/handshake-and-mtls.md

## 3. Bounded delivery and plugin-crash recovery

- [ ] 3.1 Write failing real-process tests for the five plugin_delivery_test.dart rows. Use a bounded lazy canonical-event producer, withheld/malformed/stale/duplicate ack modes, an injected ack-progress deadline, and a journal-flushed pre-ack barrier. Verify failures exercise missing flow control/recovery rather than fixture startup; retain separate failed security evidence if TLS feasibility prevents execution.
- [ ] 3.2 Implement immutable event admission, byte/count-bounded partial-batch flush, epoch/sequence acknowledgements and credit-controlled sends under the sole delivery owner. Verify the three bounded-delivery rows pass, cancellation/stop release blocked admissions with errors, stale callbacks cannot mutate new epochs, and invalid acknowledgements create neither completion nor credits; turn those mapped rows green.
- [ ] 3.3 Implement explicit restart and atomic retirement of a failed generation, retaining exactly its unacknowledged bytes. Verify the 10,000-event crash test reconciles exact unique ids and SHA-256 payload digests, observes the uncertain batch's allowed duplicate, never replays acknowledged work, and rejects torn journal evidence. Verify failed restart retains work, and turn both crash-redelivery rows green.
- [ ] 3.4 Exercise documented queue, message, journal and log caps using focused boundary cases; verify overflow is rejected or backpressured, logs remain bounded, the child does not block on stdout/stderr, and healthy progressing delivery is not ended by a whole-stream deadline. Document the resulting at-least-once and surviving-host-only guarantees with the delivery API; targeted analysis and tests must pass.
- [ ] 3.5 [evidence] Capture the credit-window maximum, 10,000-event reconciliation, pre-ack crash point, duplicate accounting, retained pending work on failed restart and selected security mode; record actual results rather than inferring durability across host death → evidence/stream-and-redelivery.md

## 4. Host-death and shutdown proof

- [ ] 4.1 Write failing real-process tests for both plugin_lifecycle_test.dart rows. Directly launch the resolved Dart executable or compiled host, verify plugin PPid and start identity before SIGKILL, and require the EOF marker plus terminated-process observation before teardown signals. Add an uncooperative shutdown fixture; verify failures identify the absent lifecycle behavior.
- [ ] 4.2 Implement normal controller shutdown, bounded forced termination/reaping and fixture stdin-EOF marker/exit with no post-handshake fd-1/2 writes in the host-death case. Verify both lifecycle tests pass, the observer retains no stdin writer, zombie versus running process state is distinguished, unrelated decoy processes survive, and all test-owned scratch is removed after exact-process cleanup; turn both rows green.
- [ ] 4.3 Document the proven watched-plugin guarantee versus plain-stock limitations and shutdown behavior. Verify the documented process topology matches the directly observed parent/child relationship and targeted analysis/tests pass.
- [ ] 4.4 [evidence] Capture criterion 4's direct host launch, parent/start identity, SIGKILL, flushed EOF exit-cause marker, observed child exit and assertion-before-teardown ordering, plus forced-shutdown results → evidence/host-death-and-shutdown.md

## 5. Integrated spike verdict and owner gate

- [ ] 5.1 Write failing real-process tests for the three plugin_gate_test.dart rows using the existing fixture/harness results, not mock success records. Include a deliberately failed TLS run followed only by an explicitly selected diagnostic run, and verify failures demonstrate missing independent verdict/error propagation rather than source-text formatting.
- [ ] 5.2 Integrate the four runtime results into a reproducible gate report in the test support, preserving each criterion's commands, evidence, failure reason and security mode. Verify all three report rows pass: an injected real failure remains failed, plaintext diagnostics never become adoption approval, and partial handshake evidence survives TLS failure. Turn the three rows green; document how to run the plugin tier and interpret unresolved gates.
- [ ] 5.3 Run the plugin tier through the existing mise task and the workspace check gate, including plugin/event generated drift checks and existing canonical-event tests. Verify every named scenario is green or honestly reported failed; do not weaken a criterion, tick failed work, modify accepted ADRs or proceed with a fallback without owner disposition.
- [ ] 5.4 [evidence] Commit the consolidated four-criterion verdict, commands/versions and links to the other evidence files, explicitly separating runtime results from D24 owner confirmation and listing review suggestions S7–S11 and how implementation treated them → evidence/spike-gate.md
- [ ] 5.5 [user] Confirm D24's production Unix-socket transport after reviewing observed stock permissions and the four-gate evidence, or explicitly decide the required fallback/superseding ADR. Only the owner ticks this task; verification is the owner's recorded decision, never an automated test result.

## Workflow follow-up

- The real Alertmanager → console → NATS user demo is judged at M1 close, as proposal.md states; it is not claimed by this output-only spike.
- Any runtime gate failure pauses dependent plugin implementation for owner disposition. Explicit diagnostic runs gather evidence, not approval. A fallback needs its owner-approved superseding ADR and renewed review before adoption.
- After implementation and the owner task are complete, run the explicit verify/archive/finish workflows; they are not implementation checkboxes here. Nothing is pushed in local finish mode.
