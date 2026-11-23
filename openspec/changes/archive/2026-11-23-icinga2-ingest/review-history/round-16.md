# Review

## Metadata

- **Round:** 16
- **Prior round:** round 15 (omp) REVISE: 2 Critical (invalid UTF-8 argv stops Dart before `main`; `DART_VM_OPTIONS` is parsed before `main`), 4 Moderate (file bounds were prechecks and synchronous CA loading blocked the deadline; author truncation changed identity; Icinga logs argv on failure; floating-point parsing lost microseconds).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** Proposal, design, four spec deltas, round 15, four baseline specs, project rules and applicable skill guidance, M2 roadmap and acceptance scenarios, architecture and ADRs 0016/0017/0020/0021/0024/0028/0029, cited ingest/pipeline/state/identity/schema/runtime/model/protobuf sources, and the Alertmanager capture precedent. Cross-checked Icinga 2 v2.13.0 and pinned Dart runtime source. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **The shipped command can turn an invalid object name into another object's valid identity.** D3 (`design.md:136–153`) applies the same UTF-8 repair to host/service names and display text. U+0000 is valid UTF-8, so the function copies it; Icinga then builds argv with [`strdup(arg.CStr())`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L94-L103), which drops the NUL and everything after it. The [DSL lexer can produce a NUL through an octal escape](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/config/config_lexer.ll#L67-L79), and the [config item builder's name check](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/config/configitembuilder.cpp#L71-L88) does not reject it. A recovery for `db1<NUL>x` can therefore reach Correlia as `db1` and resolve the wrong alert if it outranks that alert's fence. Replacing malformed name bytes with U+FFFD has the same aliasing problem with a name that contains a literal U+FFFD. D8's decoder rejection and the direct-HTTP NUL scenario cannot protect evidence already changed before `main`. Validate identity names before argv; keep lossy repair for display text only. Also define what happens to NUL in non-name text so it cannot silently shorten an author key.

### Moderate

1. **The environment scenarios disagree, and the preload test does not prove the stated launch boundary.** `integration-icinga2/spec.md:97–99` requires a sender started with a nonempty environment to exit 2 before I/O. At `:128–130`, the sender starts with variables set and must complete a delivery. Put those variables on the Icinga process and launch through the shipped command in the latter scenario. Separately, Icinga passes the inherited environment to the first `exec`, which is `/usr/bin/env`, not Dart. On a dynamically linked `env`, the [loader processes `LD_PRELOAD` before `env` can clear it](https://man7.org/linux/man-pages/man8/ld.so.8.html). A missing library does not demonstrate isolation from a loadable one. Either require the Icinga service environment to be loader-safe and scope the guarantee to the subsequent Dart exec, or use a first executable that does not consume inherited loader settings.

2. **D3 bounds check text but leaves the launch budget unbounded.** `design.md:149–152` explicitly leaves names unlimited and then claims `execvpe` never returns `E2BIG`. The cited Icinga name validator supplies no byte ceiling. The initial exec also includes Icinga's inherited environment, which `env -i` cannot clear until it has started. A notification can therefore fail before the sender runs, with no retry. Set a supported pre-launch byte ceiling for identity names and reject oversized names rather than truncating them. Document the combined argv/environment limit separately; the 200 KiB check-output case proves neither boundary.

3. **The file cap now applies to the read, but the regular-file check still applies only to the path before open.** D3 (`design.md:184–195`) handles growth and a swapped-in blocking FIFO. It does not handle a replacement that is non-regular and returns promptly: a FIFO with a writer can supply an otherwise valid credential or CA bundle under the cap. The timer will not fire, and the sender can use those bytes despite the regular-file-only contract. Validate the opened input, or explicitly require trusted, non-writable parent directories and narrow the contract to a path precheck. The blocking-FIFO scenario does not distinguish those contracts.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Reject malformed UTF-8 and disallowed control characters in host/service names before Icinga constructs argv. Prove through the shipped command that an invalid name cannot create or resolve the alert for its valid prefix. Specify and test pre-argv NUL handling for display text and authors.
2. Reconcile the environment scenarios and state where loader safety is enforced. Prove the supported Icinga launch path clears `DART_VM_OPTIONS` and exits 0 only after 202.
3. Define a supported launch-size bound without truncating identity names. Test oversized-name rejection and remove the unconditional `E2BIG` claim.
4. Align the regular-file contract with the check actually enforced. If regular-file-only is retained, test a non-regular replacement that returns valid bytes promptly, not only a blocking replacement.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 15 C1 — invalid UTF-8 in argv:** The character-boundary cut and replacement rule address the split-sequence failure for display text. Critical 1 is a separate failure: valid UTF-8 can still contain NUL, and repairing an identity field can silently change its meaning.
- **Round 15 C2 — pre-`main` runtime options:** `env -i` addresses inherited `DART_VM_OPTIONS` at the Dart exec. Moderate 1 concerns the first exec and the conflicting scenarios.
- **Round 15 M1 — file bounds and deadline:** The cap-plus-one read, asynchronous I/O and byte-based CA loading address the byte cap and blocking path load. Opened-file type is still unchecked.
- **Round 15 M2 — author identity:** The delivered-author rule and equal-prefix scenario explicitly settle truncation semantics. NUL is a separate, undocumented argv transformation.
- **Round 15 M3 — Icinga failure logs:** Addressed in the design. The runbook requirement and real-Icinga rejection scenario cover the command line as well as sender stderr.
- **Round 15 M4 — timestamp precision:** Addressed at the decoder boundary by fixed decimal strings, integer conversion and exact vectors. The release captures still have to prove that the shipped Icinga formatter preserves the promised precision.