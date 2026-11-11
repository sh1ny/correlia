# Direct host death and bounded shutdown

## Result and scope

Runtime criterion 4 passes for the original **stdin-watched** Go fixture using
stock AutoMTLS, the in-process OpenSSL connector, TLS1.3 and an observed 0600
Unix socket. Normal controller shutdown and forced shutdown/reaping also pass.
This is not a host-crash delivery-durability proof or a guarantee for arbitrary
plain-stock plugins. D24, criterion-2 interpretation and production adoption
remain owner-only task 5.5; consolidated gate reporting is tracked in group 5.

The pinned environment and separately failed built-in Dart TLS path remain in
[handshake-and-mtls.md](handshake-and-mtls.md). No plaintext/proxy/fallback was
used for these observations.

## Parent execution and initial state

Parent Dart MCP `run_tests` request:

```json
{"roots":[{"root":"file:///home/bgshi/Development/dart/correlia/correlia_server","paths":["test/plugin/plugin_lifecycle_test.dart"]}],"arguments":{"reporter":"expanded","file-reporter":"json:/home/bgshi/Development/dart/correlia/correlia_server/.dart_tool/plugin-lifecycle-verification/baseline.jsonl"}}
```

Observed: **2 passed, 0 failed**, in five seconds. Both named checks passed on
their first execution against the already-implemented fixture/startup lifecycle;
no missing lifecycle behavior or production fix was observed. The owner
explicitly approved recording those initially-green observations, and applying
the same truthful policy to task 5.1 only if its real checks also pass initially.
No failures were manufactured and no behavioral criterion was waived. Task 4.1
and the test-map preamble record this evidence-history decision.

## Direct launch and exact parent proof

The actual command was the resolved Dart executable directly, not `dart run`, a
shell parent or a timeout wrapper. These paths are the captured run's receipts;
a fresh suite generates its own private paths:

```json
["/home/bgshi/.local/share/mise/http-tarballs/b5d3ec5cd207f356d62aa86969b95bad987785aaf420fad5d78d9b3db9c90af3/bin/cache/dart-sdk/bin/dart","/home/bgshi/Development/dart/correlia/correlia_server/test/plugin/fixtures/dart/host_lifecycle_child.dart","/tmp/correlia-plugin-fixture-isaj4zMX/bin/stdin-watched","/tmp/correlia-plugin-fixture-isaj4zMX/host-death-6gU3934M","/tmp/correlia-plugin-fixture-isaj4zMX/credentials/client-certificate.pem","/tmp/correlia-plugin-fixture-isaj4zMX/credentials/client-private-key.pem","native-authenticated-tls"]
```

| Captured process | PID | Linux start tick |
|---|---:|---:|
| Direct Dart host | 923221 | 38565544 |
| Watched Go plugin | 923235 | 38565735 |
| Unrelated decoy | 923220 | 38565543 |

Before the signal, the observer independently read the plugin's atomic `/proc`
snapshot and required **PPid 923221**, equal to the directly launched Dart PID.
The child's `dart:io` PID receipt also matched `Process.pid`. Both start
identities were captured before SIGKILL, and the observer opened a pidfd pinned
to the Go child. Identity was checked again after opening it and before the
host signal. No process-name match or wrapper PID was used.

Only the direct Dart host created the Go process and held its stdin writer.
The observer's separate stdin handle belonged to the Dart host, not to Go;
it retained no duplicate/inherited Go-stdin writer. The host wrote no bytes to
Go stdin. The watched fixture used its default serving mode, not a flood mode;
its shared runtime disables gRPC diagnostics and its logger discards output
so the host-death path has no post-handshake fd-1/fd-2 writes.

## EOF cause, death, then teardown

The exact host identity received SIGKILL; the direct host was reaped with exit
status **-9**. Within **16 ms** of that signal, the pidfd was readable, the Go
PID was **absent**, and its private marker contained the complete synced bytes
`stdin-eof\n`. The five-second ceiling covers both observations, not merely
receipt of a marker or a death notification.

The observer reads final process identity/state and the marker before entering
its cleanup `finally`. A present process is accepted only when its captured
start identity matches and its state is `Z`; a running process or reused PID
fails the assertion. This run observed absence, not a zombie. A distinct marker
is essential: SIGPIPE or a teardown kill alone cannot satisfy the proof.
The watched runtime writes/flushes the EOF marker only after a successful stdin
EOF read, then exits; an input error exits without creating the cause marker.

The exact decoy remained running before and after those observations. Only after
all proof checks can cleanup signal the plugin, and it does so only if that
same identity is still running. No plugin signal was needed on this successful
absent-child path. The direct Dart child is reapable by this observer; the Go
orphan is not. An accepted same-identity zombie would mean terminated, never
"reaped by the observer".

All owned FFI poll buffers and pidfds close in `finally`; cleanup acts only on
captured identities. The suite removes its private attempt files after process
termination. The run's exact scratch root
`/tmp/correlia-plugin-fixture-isaj4zMX` was subsequently checked and was absent.

## Normal controller and uncooperative shutdown

Both shutdown cases used **plain-stock**, without the stdin watcher, and passed
real health plus protected application probes before stop. Thus an EOF watcher
cannot substitute for the normal stock controller behavior. Both observed
TLS1.3, server/client P-521 and socket mode 0600.

| Observation | Cooperative | Uncooperative |
|---|---:|---:|
| Plugin PID | 923257 | 923269 |
| Start tick | 38565756 | 38565770 |
| Observed parent PID | 923081 | 923081 |
| Stop elapsed, microseconds | 10645 | 2001784 |
| Forced | false | true |
| Actual exit code | 0 | -9 |
| Exact child reaped | true | true |
| Decoy survived | true | true |

The uncooperative fixture waits ignoring termination after stock serving returns.
The host's two-second controller/grace interval ends in SIGKILL and an awaited
five-second exit/reap watchdog. Both actual stops completed inside the
seven-second test ceiling. The independently captured shutdown decoy was PID
923254/start tick 38565754; it survived both operations before its own cleanup.

## Source, documentation and verification

Original proof support is under `test/plugin/support/plugin_*_observer.dart`;
the direct child is `test/plugin/fixtures/dart/host_lifecycle_child.dart`.
The observer uses the atomic process-snapshot helper, not the older standalone
`isZombie` getter. `docs/event-contract-tooling.md` documents the actual topology,
controller/force distinction, orphan/reaping definition and plain-stock limit.

Scoped Dart fix reported `Nothing to fix!`; the formatter formatted the four
owned sources, targeted MCP analysis returned `No errors`, and Serverpod hot
reload completed. Release Notes validation returned `ok: true`; strict
OpenSpec validation reported this change valid. No accepted ADR was modified.

The temporary JSON reporter is not shipped and is removed after capturing this
record. Full plugin-tier/workspace verification and the independent consolidated
verdict are later tasks; these passing lifecycle observations do not claim them.

After formatting, the parent checked returned-worker process ownership (only the
managed LSP service remained), re-read the VCS path state, and re-ran both named
lifecycle tests through Dart MCP with the expanded reporter. Both passed again,
with no runtime changes; this is the final parent verification for the group.
