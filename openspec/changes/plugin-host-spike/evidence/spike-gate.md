# Plugin-host spike: independent runtime verdict

## Status and boundary

The four individual runtime criteria pass through the **custom in-process
OpenSSL connector**. The full plugin tier passes 39 tests. Owner task **5.5 is
pending**: neither these results nor explicit diagnostics approve D24, the
interpretation of ADR 0020 criterion 2, or the native runtime dependency.
The final workspace gate also passed, including fatal-info analysis, generated
drift checks, canonical-event coverage, tool tests and the Flutter widget test.
These full-tier/workspace figures describe group-5 base commit `3c633d9`.
The explicitly authorized pre-ship follow-up has separate focused verification
recorded below.

This is an experimental output probe, not a stable plugin SDK, production
supervisor, durable outbox or host-crash delivery guarantee. The built-in Dart
TLS engine's historical P-521 failure remains failed; a separate native success
must not rewrite it. See [handshake/mTLS evidence](handshake-and-mtls.md),
[protected delivery evidence](stream-and-redelivery.md), and
[direct lifetime evidence](host-death-and-shutdown.md).

## Reproducible commands and versions

From the repository root:

```sh
mise run test -- --tags plugin
mise run check
```

The first command actually completed after the lint fixes: **39 passed, zero
failed**, in 40.05 seconds (40.10 seconds wall time). The expanded output contains
the independent native, failed-capability and explicitly diagnostic reports,
including actual executable/argv, PID/start, socket and transport observations.
The scoped parent MCP runs also passed all three gate tests and all 14 migrated
delivery tests. The five mapped delivery proofs are shared implementations,
not copied assertions or mocked success records.

| Component | Observed runtime or committed pin |
|---|---|
| Linux | 6.18.33.2-microsoft-standard-WSL2, x64 |
| Dart | 3.13.7 stable, actual CLI and doctor |
| Flutter | 3.47.9, actual doctor |
| Go | go1.27.3 linux/amd64, actual CLI and doctor |
| Buf | 1.75.0, actual CLI and doctor |
| OpenSpec / Serverpod CLI | 1.16.0 / 4.1.0, actual doctor |
| Native TLS backend | OpenSSL 3.0.13 30 Jan 2024, actual negotiated-connection metadata |
| Dart transport dependencies | grpc 5.2.0, http2 2.3.1, ffi 2.2.0, exact pubspec pins |
| Go fixture dependencies | go-plugin v1.8.0, gRPC v1.75.1, protobuf v1.36.11, committed go.mod |

Dart `^3.12.2` is the package's minimum constraint, not the SDK used here.
The fixture module's `go 1.24.0` is likewise its module directive, not the
executing Go tool version. No dependency overrides or upstream implementation/
schema copies were introduced.

Runtime needs system `libssl.so.3` and `libcrypto.so.3`; there is no OpenSSL
executable in the TLS path, proxy or bundled crypto. C compiler/development
headers belong only to native allocation tests. Default system/`OPENSSL_CONF`
policy is honored: the observed compiled directory was `/usr/lib/ssl`, and
`OPENSSL_CONF`, `OPENSSL_CONF_INCLUDE`, `OPENSSL_MODULES` were all unset. No
configuration contents or private key material appear in reports.

## Independent results

`PASS-DIAG` below means an explicitly selected plaintext observation, never an
adopted fallback or a passing native criterion. The report's runtime pass
requires exactly four passing non-diagnostic results.

| Actual run | 1: stock handshake/socket | 2: AutoMTLS | 3: delivery/recovery | 4: lifetime/shutdown | Runtime verdict |
|---|---|---|---|---|---|
| Default native | PASS, handshake-only | PASS, native TLS | PASS, native TLS | PASS, native TLS | PASS; owner pending |
| Restricted P-521 offer, no diagnostics | PASS, handshake-only | FAIL | not run | not run | FAIL |
| Restricted offer, explicitly selected diagnostics | PASS, handshake-only | FAIL | PASS-DIAG | PASS-DIAG | FAIL |

### Criterion 1: stock handshake and socket

A separate unmodified plain-stock Go process emits the stock core-1/version-1,
Unix/gRPC handshake and advertises its AutoMTLS certificate. The observer checks
actual socket type/UID/0600 mode in the private directory, performs a real Unix
`RawSocket.connect`, then closes it. Its security mode is explicitly
`stock-automtls-handshake-only`; `tls_negotiated` and `application_rpc` are false.
This pre-TLS observation cannot claim authenticated application delivery.
It stays independently successful when the later native TLS capability fails.

### Criterion 2: native authenticated exchange

The final native run reported TLSv1.3, client/server P-521, health SERVING and a
protected application acknowledgement on a socket owned by UID 1000. Effective
launch umask was 0177 and actual mode 0600. Authentication and native ownership
negatives remain covered by the same full plugin tier; no accept-all callback,
replacement loader/verifier, disabled peer checks or plaintext retry exists.

Both controlled-failure runs narrowed the actual OpenSSL signature offer using
internal `withoutP521Signatures`, not a wrong pin or fake error. They retained
version 1, UID 1000, socket 0600, certificate-present and actual-connect facts,
then failed with the original transport cause:

```text
HandshakeException: TLS handshake failed (SSL error 1): error:0A000410:SSL routines::sslv3 alert handshake failure
```

No protocol was negotiated in those failed attempts; OpenSSL's generic alert
name is not evidence that SSLv3 was enabled. The configured profile still
requires TLS1.3. The independent handshake result survives; absent explicit
selection, delivery/lifetime remain visibly not-run, not silently retried.

### Criterion 3: bounded delivery and recovery

Both native and explicitly diagnostic runs executed all five mapped cases:
withheld credits, invalid/stale/duplicate ACKs, missing progress, crash recovery,
and failed restart retaining immutable pending work. Each performed real
health/application probes before its business assertions. Native connections
reported TLS1.3/P-521; diagnostic connections reported no TLS metadata and
still required actual 0600 sockets.

The final native and diagnostic reconciliation runs independently measured the
same following values (the underlying exact id/digest/set assertions also ran):

| Observation | Value |
|---|---:|
| Original unique ids reconciled | 10,000 |
| Records before the second crash | 10,001 |
| Duplicated ids / uncertain barrier ids | 1 / 1 |
| First barrier sequence / recorded events | 1 / 1 |
| Pending events at first crash | 1,024 |
| Pending canonical bytes at first crash | 1,408,538 |
| Default credit limit / outstanding at barrier | 4 / 4 |
| Acknowledged originals before second crash | 10,000 |
| New records after second restart | 1 |

The restricted withheld-ACK case separately observed two accepted outstanding
batches with a two-credit policy, six retained events, zero false completions
and zero usable credit after failure. Every uncertain id actually appeared
twice with unchanged bytes; the duplicate set equalled only that uncertain set.
A second kill after all original ACKs and a third launch with one extra event
proved non-vacuous no-acknowledged-replay. Failed restart retained its one id,
exact bytes and immutable snapshot without claiming delivery.

Actual native successful-launch argv are read from `/proc`; diagnostic launches
also capture the real process-starter argv. The intentionally immediate-exit
failed-restart child's final argv may already be gone before inspection and is
not fabricated. Its selected exit fixture, actual startup exception and retained
work assertions are recorded by the shared proof; reproducible tier/source
commands and the other observed invocations remain available.

### Criterion 4: direct host death and shutdown

In the final native gate run, the directly launched Dart host was PID
939633/start tick 39010502. Its Go child was PID 939673/start 39010831, with
independently observed PPid 939633 before host SIGKILL. The EOF marker and absent
child were both observed in 20 ms, before any plugin teardown signal. The
reaped direct host exited -9; the decoy survived. No Go-stdin writer was held by
the independent observer, and no `dart run`/shell-parent/timeout wrapper hid the
actual host relationship.

The same run's plain-stock controller case exited 0 without forcing in 4,173
microseconds. Its uncooperative case was forced to -9 and reaped in 2,002,039
microseconds; the unrelated captured decoy survived both. The explicitly
selected diagnostic run independently passed the same EOF/exit and shutdown
proofs, with diagnostic mode labelled and no TLS metadata. This does not grant
an orphan guarantee to plain-stock plugins lacking the watcher, nor durable
pending events after host death.

The diagnostic policy negative observed actual mode **0755**, UID 1000 and
umask **0022**. Its group/other-write mask was zero, yet exact-0600 policy
rejected it with `StateError` before application delivery; the journal remained
empty. This isolates the diagnostic rule from ordinary write-bit rejection.
No chmod repair or plugin patch was used.

## Actual test-first and integration history

The first valid native gate test reached four real passing runtime observations
but exposed a classifier bug: a report containing only three of them returned
true. The test failed with `Expected: false`, `Actual: <true>` for
`Three observed criteria cannot grant a four-criterion verdict`. The fix requires
exactly four observations; the same process test then passed. Constructor
parameter cleanup was not counted as behavioral red evidence.

The failed-capability and explicit-diagnostic checks passed on their first
observations. The owner had explicitly approved recording genuinely
initially-green task-5.1 checks without manufacturing failure; all behavioral
acceptance stayed unchanged. This evidence-history permission does not tick or
approve owner task 5.5.

The first `mise run check` stopped on 13 fatal lint infos, not runtime-test
failures. Completion hooks now explicitly use `unawaited` so they remain
nonblocking; real teardown futures are awaited, test evidence uses
`stdout.writeln`, and multiline guards have braces. No lint was ignored or
assertion weakened. Formatter checked all 11 owned fix-scope files with zero
further changes; scoped fix and Serverpod hot reload completed. Both final mise
tasks passed for group-5 base `3c633d9`; follow-up verification is recorded below.

### Final workspace verification

`mise run check` completed successfully in 211.48 seconds (211.55 seconds wall).
Its actual stage results were:

| Stage | Observed result |
|---|---|
| Strict OpenSpec validation | 4 passed, 0 failed |
| Linux pinned-tool doctor | all six tools matched |
| Dart and Flutter fatal-info analysis | No issues found |
| Workspace formatting | 129 files, 0 changed |
| Serverpod generated code | current |
| Canonical baseline/schema and event/plugin generated drift | compatible and current |
| Fast server tests, including canonical events | 91 passed |
| Tool tests, including generated-output changes/deletions | 64 passed |
| Flutter widget test | 1 passed |

The separately requested plugin tier passed all 39 cases on the same source.
No database/e2e/load tier is claimed by these commands. The existing local
password file was kept, and no accepted ADR or frozen event baseline was
regenerated to obtain a pass.

## Design-review suggestion dispositions

The ledger includes the native amendment's later review, not only the original
S7–S15 task wording. Current `review.md` is Round 5; earlier titles were checked
against committed/local original review output, not inferred.

| ID | Concern | Implementation disposition |
|---|---|---|
| S7 | Stock way to obtain exact 0600 | Explicit 0177 launch, observed 0600, inherited-mode evidence separate; real diagnostic guard passed. |
| S8 | First-response versus idle timeout | Open Deliver only with pending work; ACK-progress timer only outstanding; healthy beyond-deadline traffic passed. |
| S9 | Criterion 1 under TLS failure | Separate real stock handshake/socket probe plus retained failed-TLS facts; all three report modes passed. |
| S10 | First-launch barrier/configuration | Explicit argv paths, first nonempty batch only, restart omits flag; obsolete claim file removed. |
| S11 | Credits derived from owner state | Sole outstanding map; credits validated/derived, real withheld and invalid ACK checks passed. |
| S12 | Whole ADR supersession | ADR 0023 replaces all of 0022 and repoints the index; accepted 0022 unchanged. |
| S13 | Negative causes, not arbitrary errors | Typed transport/startup negatives; actual restricted-offer cause is HandshakeException, not timeout or wrong pin. |
| S14 | Genuine deliberate TLS gate failure | Actual narrowed OpenSSL signature offer fails P-521; 2 stays failed alongside explicit diagnostic 3/4. |
| S15 | Executable late acquisition tests | Real delayed process/directory receipts disposed; both permanent regressions passed in the full tier. |
| S16 | Eager ABI resolution | Fixed genuine libraries, eager required symbols before connect/per-session allocation; failure-only controls. |
| S17 | Inbound native bound | Paused-reader bound and byte-identical resume passed; oversized-source rejection remains covered. |
| S18 | Isolated allocation accounting | Original cold-process C hooks plus Dart staging accounting; repeated failures and partial allocation checks passed. |
| S19 | Labels and native release notes | Historical built-in/diagnostic evidence distinct; OpenSSL runtime/test dependencies and ADR 0023 documented. |
| S20 | Migrate path/type negatives and 0600 guard | Valid-cert path/type negatives remain; actual 0022→0755 diagnostic refusal proves the stricter rule. |
| S21 | TLS1.3/configuration/verify store | Actual TLS1.3 asserted, TLS1.2-capped config rejected, both trust/verify stores reset. D2 enforces the threshold; no weaker runtime interpretation. |
| S22 | Track release notes | Task 2.4 records it; validated notes include native dependency, whole supersession and owner boundary. |

## Owner-only next decision

Only the owner can review the observed inherited/restrictive stock socket modes
and this four-gate evidence, decide D24 and whether grpc-dart's custom connector
over in-process OpenSSL satisfies criterion 2 with its native dependency, then
tick **5.5** in `tasks.md`. Otherwise the required alternative/superseding ADR
must be explicitly decided. Tests never grant this decision. Nothing is pushed,
archived, merged or released by this implementation step.

## User-authorized pre-ship F1 follow-up

The first independent pre-ship review of `3c633d9` had no P0/P1 findings and one
P2: a concurrent stop could clear pending work before `drain` rechecked its
terminal state, causing successful drain completion without acknowledgements.
The owner explicitly requested fixing F1 and repeating independent review.
That permission does not approve transport/adoption task 5.5.

The existing real-process `bounded admission supports cancellation and stop
without transfer` case was extended while its first nonempty batch was held
unacknowledged at the receiver barrier. A concurrent drain was required to fail
with `StateError` when stop discarded that work. Against the original code it
failed behaviorally: expected a thrown `StateError`, but the future emitted
`null`. No compile/format failure was counted as red.

`drain` now checks failure and terminal stop at the top of every iteration,
before treating an empty pending map as success. Normal acknowledged draining,
progress failure and explicit restart semantics remain unchanged. The public
doc comment, API documentation and Release Notes describe the stop behavior.

Parent verification after the fix: **all 14 delivery tests passed** in 15
seconds, including the regression and the 10,000-event reconciliation. Workspace
`dart analyze --fatal-infos` returned `No issues found!`; scoped fix reported
nothing to fix; both changed Dart files formatted with zero changes. Serverpod
hot reload completed, Release Notes validation passed and strict change
validation passed. The new head's independent review is recorded separately by
Specwright rather than rewriting the already-reviewed head with a receipt.
