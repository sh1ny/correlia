# Protected stream and plugin-crash redelivery

## Result and scope

Runtime criterion 3 passes through stock go-plugin v1.8.0, default AutoMTLS,
P-521 certificates and the in-process OpenSSL TLS1.3 connector. There is no
plaintext run, proxy or automatic retry/fallback in these observations.
Versions/configuration and the separately failed built-in Dart TLS path are
recorded in [handshake-and-mtls.md](handshake-and-mtls.md).

The surviving Dart delivery owner retains unacknowledged work. This is not
host-crash delivery durability, an exactly-once guarantee, a production outbox,
criterion 4 proof or owner approval. Task 5.5 remains unticked.

## Parent-owned execution

Final Dart MCP `run_tests` request used:

```json
{"roots":[{"root":"file:///home/bgshi/Development/dart/correlia/correlia_server","paths":["test/plugin/plugin_delivery_test.dart","test/plugin/plugin_native_tls_test.dart"]}],"arguments":{"reporter":"expanded","file-reporter":"json:/home/bgshi/Development/dart/correlia/correlia_server/.dart_tool/plugin-native-verification/group3-final.jsonl"}}
```

Observed: **22 passed, 0 failed**, in 16 seconds: 14 delivery/resource tests and
8 native transport tests. These are fresh parent-run results, not worker claims.
The generated events came from the existing validated canonical codec and a
lazy producer; only expected id/digest metadata, not all event payloads, was
retained for reconciliation.

## Credit window and crash point

| Observation | Measured value |
|---|---:|
| Withheld-ACK configured credit window | 2 |
| Accepted unacknowledged batches in that run | 2 |
| Events retained after its progress timeout | 6 |
| Default credit window in the reconciliation run | 4 |
| Outstanding batches at its first pre-ACK barrier | 4 |
| Original unique event ids reconciled | 10,000 |
| Journal records before the second crash | 10,001 |
| Duplicated ids | 1 |
| First barrier sequence | 1 |
| Events recorded at that barrier | 1 |
| Pending events retained after the first crash | 1,024 |
| Pending canonical bytes retained after that crash | 1,408,538 |
| Acknowledged original events before the second crash | 10,000 |
| New records after the second restart | 1 |

The receiver wrote, flushed and synced the first nonempty batch, then notified
its Unix control socket and blocked before acknowledgement. The independent
observer captured the plugin's PID/start identity and sent SIGKILL only to that
exact process. The delivery owner's first terminal callback retired the epoch;
its immutable pending map survived. Restart omitted the barrier flag and used a
fresh connection epoch. Empty protected probes do not consume the barrier.
The obsolete exclusive claim-file implementation was removed.

Every journal id matched the original expected set; every SHA-256 payload digest
matched the original immutable structured JSON bytes. Every event recorded at
the uncertain barrier was actually delivered again with the same bytes, and
only that uncertain set appeared twice. This is an observed allowed duplicate,
not a claim that duplicate-free output would prove at-least-once recovery.

The mandatory first-batch barrier precedes any first-generation acknowledgement,
so a first-crash-only no-acknowledged-replay assertion would be vacuous. The test
therefore killed the second plugin after all original events had valid ACKs,
restarted a third plugin, and admitted one new event. Its one new journal record
was only that event: no previously acknowledged id was replayed.

## Failed restart and protocol errors

The failed-restart case killed its exact plugin at the pre-ACK barrier, retained
one event, then selected a fixture that exits before readiness. Restart returned
`PluginStartupException`; the owner remained failed with the same id and exact
bytes pending, its immutable pending snapshot could not be cleared, and no
receipt was falsely acknowledged.

Live-stream wrong-epoch, unknown sequence and duplicate ACKs fail the generation
with `FormatException`. The unknown-sequence fixture uses zero, not `+1`, which
could accidentally name another outstanding batch. A valid ACK preceding a
malicious duplicate may complete only its own batch; the duplicate cannot
complete the other pending event or create usable credit. Callback generation
fencing protects subsequent epochs. Withheld responses produce the injected
acknowledgement-progress `TimeoutException` while preserving work.

## Actual test-first history

| Mapped check | Initial observation |
|---|---|
| Withheld acknowledgements | Behavioral red: 6 outstanding with a configured limit of 2 |
| Invalid acknowledgement | Behavioral red: no failure at the explicit six-second checkpoint after an invalid epoch ACK |
| Missing acknowledgement progress | Behavioral red: no failure at the explicit five-second checkpoint with a 400 ms progress deadline |
| Pre-ACK crash/reconciliation | Passed on its first observation |
| Failed restart retention | Passed on its first valid restart observation |

The first failed-restart attempt stopped at the then-missing progress timer and
did not exercise restart; it is not claimed as recovery red evidence. The two
proper recovery observations already worked in the prototype. The owner
explicitly approved recording them as initially green instead of manufacturing
failures, with all behavioral acceptance unchanged. Task 3.1 records exactly
that exception. It does not approve task 5.5 or weaken a runtime criterion.

## Resource-boundary observations

- Count and byte admission budgets were exercised independently. Cancellation
  before admission and terminal stop released blocked callers with errors,
  without transferring extra work. Duplicate currently pending ids were rejected
  rather than replacing a receipt.
- Batch event-count and encoded protobuf-byte limits were tested independently
  against real receiver records reconstructed with the generated serializer.
  Over-limit single events were rejected before admission. Partial input flushed
  without waiting for a full batch.
- Healthy acknowledged traffic continued for 1.5 seconds with a one-second
  progress policy: there was no whole-stream deadline. The production stream
  has no `CallOptions(timeout)`; the business timer runs only with outstanding
  work and resets only on valid ACK progress.
- The added native input-boundary regression initially accepted a 256 KiB + 1
  source chunk. It now rejects that chunk before queuing or any OS write; a
  subsequent exact 256 KiB chunk succeeds byte-identically on the same verified
  connection. Actual short writes and paused ciphertext reads remained green.
- A four-MiB stderr flood reached its subsequent malformed handshake, proving
  the child was drained rather than merely timing out on a blocked pipe. The
  retained diagnostic tail remained bounded and the exact child was reaped.
- A separate real stock AutoMTLS mode emitted four MiB across stdout/stderr
  during its first application call, then journalled and acknowledged a canonical
  event. Its id/digest matched the producer and no pending event remained. The
  host-death fixture uses neither flood mode.
- Torn journal tails, over-bound files and invalid digest records were rejected.

An independent original Go probe exercised the real `Journal.AppendBatch`, fed
by canonical bytes from the Dart codec, using 64-event batches until the cap.
It measured:

| Writer observation | Value |
|---|---:|
| Journal byte limit | 33,554,432 |
| Accepted bytes at the boundary | 33,551,552 |
| Accepted batches | 3,325 |

The next append returned `journal would exceed 33554432-byte bound`; the size
was unchanged. A repeated rejected append also preserved a streaming SHA-256
hash of the entire accepted prefix. This was a real bounded file/write/fsync
proof, not a mocked size counter. The driver ran with:

```sh
mise exec -- dart run .dart_tool/plugin-native-verification/journal_cap_smoke.dart
```

A public-import smoke delivered eight canonical events with zero remaining
work. Its test-only VM reflection then placed the sequence counter at its
representable end: the initial run failed to reject wrap, the fix failed the
generation before sending a nonpositive sequence, and an explicit restart
acknowledged the retained event. No production counter-injection port was added.

## Tooling and limits

Scoped Dart fix/formatting completed; the final formatter checked 28 files with
zero further changes. Targeted MCP analysis returned `No errors`, Serverpod hot
reload completed, Release Notes validation returned `ok: true`, and strict
OpenSpec validation passed. Mechanical lint fixes also covered this change's
already-owned native/startup files; no unrelated repository code was swept in.

The temporary public/counter/journal-cap drivers and JSON reporters are not
shipped. Their owned scratch is removed after recording this evidence. The
permanent process tests, original fixtures and public delivery API remain.
The full plugin tier/workspace gate and direct host-death proof are later
tracked tasks, not inferred from these results.
