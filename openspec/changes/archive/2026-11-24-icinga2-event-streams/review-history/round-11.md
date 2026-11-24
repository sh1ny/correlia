## Metadata

- **Change** `icinga2-event-streams`, working-tree amendments to D31 and D32 at base commit `793d649`.
- **Scope** Independent follow-up on the four round 10 findings and blockers introduced by the amendments. Reviewed the amended specs, test map, and relevant tracked code. No tests run or files written. [Round 10](openspec/changes/icinga2-event-streams/review-history/round-10.md)

## Findings

1. **D31 leaves the original malformed verdict unspecified after redaction.** Take a schema-valid `AcknowledgementSet` and put a literal tab byte inside its comment string. Use that one-byte tab as the password. The original line is invalid JSON. The malformed-input branch replaces the tab with printable letters, making the sanitized line valid JSON. If the batcher and pipeline determine validity from the sanitized text alone, the line can produce an acknowledgement event instead of an isolated raw row that fails with `invalid_json`. The lexical pass already classifies the original line, but D31 does not say that this verdict survives admission and controls processing. [D31](openspec/changes/icinga2-event-streams/design.md#L813) · [Malformed-line contract](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L229)

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

- Carry the lexical pass’s original malformed JSON or invalid UTF-8 verdict through admission and processing as a fixed failure code. Map the literal-tab counterexample to assertions that the sanitized line is stored alone, the row fails with `invalid_json`, and no event is emitted even though the sanitized text parses.

## Rebuttals

- **Round 10 finding 1 is resolved.** At most five forbidden forms exclude at most ten ASCII letters through their first and last bytes. A forbidden match starting or ending inside the marker would require an excluded boundary byte. A match spanning the entire marker with bytes on both sides would be longer than the longest forbidden form. Merging overlapping match spans covers the original occurrences. The proof holds across the retained password range, and the test map includes marker-boundary coverage. [D31](openspec/changes/icinga2-event-streams/design.md#L822) · [Test map](openspec/changes/icinga2-event-streams/tasks.md#L138)
- **Round 10 finding 2 is resolved.** For valid JSON, `\u0041` decodes to `A`, so password `u0041` leaves the escape and decoded content intact. Malformed input uses literal-byte matching and scans recoverable strings for decoded echoes. The `line_b64` audit checks the unwrapped sanitized bytes. Coincidental matches in fixed metadata and serialization syntax are outside the owner’s echo rule. [D31](openspec/changes/icinga2-event-streams/design.md#L815) · [Escape scenario](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L273) · [Secret contract](openspec/changes/icinga2-event-streams/specs/secret-store/spec.md#L5)
- **Round 10 finding 3 is resolved.** The retained repair supplies the committed raw-row assertion. The eventless confirmation is checked at admission for sanitization and after processing for deletion. The rejected object is checked for absence of admission and clean diagnostics. The test map assigns separate scenarios to those boundaries. [Sync echo scenarios](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L257) · [Deletion contract](openspec/changes/icinga2-event-streams/specs/icinga2-event-streams/spec.md#L360) · [Test map](openspec/changes/icinga2-event-streams/tasks.md#L135)
- **Round 10 finding 4 is resolved.** A live explicit key with a different body returns **409** before a raw insert can fire the cutoff trigger. Tracked admission code already compares the body digest and returns the conflict before insertion, and ingress maps that result to 409. The new scenario asserts no raw insert or reservation change. Exact live retries return the committed result, and expired reservations take the new-admission path. Round 10’s acceptance of the receipt-time and acquisition race fixes still stands. [Cutoff contract](openspec/changes/icinga2-event-streams/specs/source-ingress/spec.md#L109) · [Admission](correlia_server/lib/src/ingest/admission.dart#L117) · [HTTP mapping](correlia_server/lib/src/ingest/ingress.dart#L408) · [Test map](openspec/changes/icinga2-event-streams/tasks.md#L308)