## Metadata

- **Change** `icinga2-event-streams`, working-tree amendments D31 and D32 at base commit `793d649`.
- **Scope** Independent design review against the supplied round 9. Citations point to tracked paths. No tests were run and no files were written.

## Findings

1. **D31 can write the password back into the sanitized payload.** The allowed password range includes `password`. An authenticated acknowledgement can echo it as `p\u0061ssword`. The lexical scanner recovers the match and replaces it with `[redacted:password]`, which contains the exact password bytes. The raw item therefore contains the password, and the acknowledgement description can carry it into the CloudEvent and outbox. This contradicts the secret-store requirement even when escape matching works correctly. [D31](openspec/changes/icinga2-event-streams/design.md#L813) · [Password constraints and secret contract](openspec/changes/icinga2-event-streams/specs/secret-store/spec.md#L5) · [Acknowledgement mapping](openspec/changes/icinga2-event-streams/design.md#L442) · [Event persistence](correlia_server/lib/src/pipeline/pipeline.dart#L525) · [Outbox payload](correlia_server/lib/src/pipeline/pipeline.dart#L611)

2. **D31's literal replacement can corrupt a valid JSON escape.** With password `u0041`, the wire comment `"before \u0041 after"` contains a literal byte match inside an escape, while the decoded comment is `before A after`. Replacing the literal span leaves `\[` and turns a valid acknowledgement into an `invalid_json` failure. Leaving the span intact violates the literal-byte scrubbing rule. The design needs a rule for rewriting the enclosing escape while preserving unrelated decoded text. [D31](openspec/changes/icinga2-event-streams/design.md#L815) · [Storage and validation requirements](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L229)

3. **The escaped-sync scenario requires a raw item in cases where sync must discard it.** A valid sync object can echo the escaped password in its check output and only confirm an existing alert. The amended scenario requires a stored raw item with the marker, while the eventless-sync requirement deletes that row in the processing transaction. A rejected sync object likewise produces no raw row under the bad-object requirement. The new scenario needs a retained repair fixture for the committed-storage assertion and a separate assertion for the sanitized admission input of an eventless confirm. [Escaped echo scenario](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L261) · [Eventless sync rows](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L346) · [Bad sync objects](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L435)

4. **D32's webhook exception omits the live-key body conflict.** Commit body A with an explicit key, then submit body B under the same key with a receipt inside the original window. Hold the second request until the cutoff passes its receipt. The amended requirement says a reservation within its window returns its existing result. The owner-approved transport behavior returns **409** before any raw insert, so the cutoff trigger never runs. The mapped inside/outside-window case covers exact retries and leaves this contradiction unresolved. [Cutoff requirement](openspec/changes/icinga2-event-streams/specs/source-ingress/spec.md#L109) · [Baseline transport contract](openspec/specs/source-ingress/spec.md#L57) · [Body comparison](correlia_server/lib/src/ingest/admission.dart#L117) · [HTTP outcome](correlia_server/lib/src/ingest/ingress.dart#L408) · [Task mapping](openspec/changes/icinga2-event-streams/tasks.md#L305)

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

- Define a collision-safe replacement for every allowed password and specify how literal matches that intersect JSON escapes are rewritten. Map both cases to assertions on sanitized bytes, decoded fields and diagnostics.
- Make the escaped-sync storage case produce a retained repair. Assert eventless confirmation cleanup and bad-object handling at their respective observation points.
- Limit the webhook duplicate exception to exact retries. Cover a live explicit key with different bytes and a receipt behind the cutoff, asserting 409 and zero new writes.

## Rebuttals

- The receipt-time proof holds with the specified Read Committed sequence. Admission checks the cutoff returned by the locking read, and the sweep reads pending receipts in a fresh statement after taking the exclusive lock. A claim or retry leaves the row visible as pending until its outcome commits. The oldest pending receipt and durable cutoff together protect delayed work across shared namespaces. [D32](openspec/changes/icinga2-event-streams/design.md#L829) · [Claim and retry paths](correlia_server/lib/src/pipeline/pipeline.dart#L750)
- The amendment addresses round 9's missing state effect. Observation reservations precede alert locks, and a missing locking read following an insert conflict triggers reacquisition within the row deadline. The mapped race requires the new alert, `created` activity, event and outbox intents to commit together. The opposite schedule preserves the ID and records a refire. The marker, retained-evidence probes, bounded cursor and cancellable connection also address the prior identity and sweep-bound findings. [Reservation order](openspec/changes/icinga2-event-streams/specs/durable-pipeline/spec.md#L144) · [D32 sweep and retry](openspec/changes/icinga2-event-streams/design.md#L848) · [Lifecycle scenarios](openspec/changes/icinga2-event-streams/specs/alert-state/spec.md#L196) · [CloudEvent subject projection](correlia_server/lib/src/event/canonical_event.dart#L671)