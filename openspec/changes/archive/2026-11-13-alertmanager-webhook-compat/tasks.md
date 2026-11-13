# Tasks

## Test map

Unit tests are in `correlia_server/test/unit/ingest/alertmanager_decoder_test.dart` (decoder),
`correlia_server/test/unit/ingest/alertmanager_versions_test.dart` (version matrix) and
`correlia_server/test/unit/pipeline/unknown_field_warning_test.dart` (warning text). Database tests are in
`correlia_server/test/db/pipeline_unknown_fields_test.dart` (tag `db`).

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| integration-alertmanager → Per alert webhook decoding | Mixed group and upstream truncation | `test/unit/ingest/alertmanager_decoder_test.dart` | `mixed_group_and_upstream_truncation` | green |
| integration-alertmanager → Per alert webhook decoding | Unsupported version or malformed member | `test/unit/ingest/alertmanager_decoder_test.dart` | `unsupported_version_or_malformed_member` | green |
| integration-alertmanager → Per alert webhook decoding | Empty group | `test/unit/ingest/alertmanager_decoder_test.dart` | `empty_group` | green |
| integration-alertmanager → Recognised group metadata | Group metadata of a current release | `test/unit/ingest/alertmanager_decoder_test.dart` | `group_metadata_of_a_current_release` | green |
| integration-alertmanager → Recognised group metadata | externalURL link is kept | `test/unit/ingest/alertmanager_decoder_test.dart` | `external_url_link_is_kept` | green |
| integration-alertmanager → Recognised group metadata | Wrong-typed group metadata | `test/db/pipeline_unknown_fields_test.dart` | `wrong_typed_group_metadata` | green |
| integration-alertmanager → Top-level field tolerance | A future Alertmanager adds a field | `test/db/pipeline_unknown_fields_test.dart` | `future_top_level_field_is_processed_and_flagged` | green |
| integration-alertmanager → Top-level field tolerance | Credential-shaped unknown key | `test/db/pipeline_unknown_fields_test.dart` | `credential_shaped_unknown_key_never_logged` | green |
| integration-alertmanager → Top-level field tolerance | Many or oversized unknown names | `test/db/pipeline_unknown_fields_test.dart` | `many_or_oversized_unknown_names` | green |
| integration-alertmanager → Top-level field tolerance | Worker dies between commit and warning | `test/db/pipeline_unknown_fields_test.dart` | `warning_lost_after_commit_is_not_retried` | green |
| integration-alertmanager → Top-level field tolerance | Unknown field inside an alert stays fatal | `test/unit/ingest/alertmanager_decoder_test.dart` | `unknown_field_inside_an_alert_stays_fatal` | green |
| integration-alertmanager → Supported Alertmanager releases | Every supported release decodes | `test/unit/ingest/alertmanager_versions_test.dart` | `every_supported_release_decodes` | green |
| integration-alertmanager → Supported Alertmanager releases | Release without fingerprint or truncatedAlerts | `test/unit/ingest/alertmanager_versions_test.dart` | `release_without_fingerprint_or_truncated_alerts` | green |

`unsupported_version_or_malformed_member` starts red because its `'unexpected': true` top-level case changes
meaning (it now decodes and is flagged); the case moves to the tolerance tests and the test gains a wrong-typed
`routeLabels` and `notification_reason` case.

## 1. Decoder: recognised group metadata and top-level tolerance

- [x] 1.1 Write the failing decoder unit tests: `group_metadata_of_a_current_release` (string
  `notification_reason`, `routeLabels` with values and `{}`; fingerprint, event id, status, labels, annotations,
  severity, summary and links equal those of the same group without the two fields; neither appears in the
  event), `external_url_link_is_kept`, `unknown_field_inside_an_alert_stays_fatal` (the error names the alert's
  field path), and decoder-level tolerance cases (`newField` yields `unknownTopLevelFields == ['newField']`; 20
  unknown names with one 300 characters long yield 16 sorted listed names and overflow 4). Move the
  `'unexpected': true` top-level case out of `unsupported_version_or_malformed_member` and add wrong-typed
  `routeLabels` (`{'a': 1}`, a list) and `notification_reason` (a number) cases to it, each failing with
  `EventFieldError` whose path is `routeLabels` or `notification_reason`. Verify with `mise run test` that they
  fail on `unknown_field` for the right reason.
- [x] 1.2 In `correlia_server/lib/src/ingest/alertmanager_decoder.dart`: add `routeLabels` to the top-level
  allowlist, type-checked as a string map like `groupLabels` (D5); replace the top-level `_keys` failure with
  tolerance that collects unknown names, keeps the first 16 sorted names matching 1-64 characters of
  `[A-Za-z0-9_.-]` and counts the rest; add `unknownTopLevelFields` (a `List<String>`) and
  `unknownTopLevelOverflow` (an `int`) to `AlertmanagerBatch` (D1). Per-alert `_keys` stays fatal. Document the
  new members with `///`. Verify the 1.1 tests and the whole fast tier pass (`mise run test`) and flip their
  test-map rows green.
- [x] 1.3 Re-run `mixed_group_and_upstream_truncation` and `empty_group` unchanged and confirm they pass (rows
  stay green).

## 2. Version matrix from real captures

- [x] 2.1 Copy the 40 files of `openspec/changes/alertmanager-webhook-compat/evidence/alertmanager-captures/*.json`
  into `correlia_server/test/unit/ingest/fixtures/alertmanager/`, with a short `README.md` saying where they came
  from (Correlia's own captures from `tool/alertmanager_capture.sh`, see the runbook) (D6). Verify with
  `ls ... | wc -l` (40 JSON files plus the README).
- [x] 2.2 Write `correlia_server/test/unit/ingest/alertmanager_versions_test.dart`: one test per fixture under
  `every_supported_release_decodes` (status matches the file name, zero unknown top-level fields and overflow 0,
  and the canonical fingerprint of the alert is the same for every release) and
  `release_without_fingerprint_or_truncated_alerts` (0.16-0.18 fixtures: zero upstream omissions and identity
  equal to the 0.35 alert). Verify with `mise run test` that it passes and flip both rows green; then remove
  `routeLabels` from the allowlist for one run and confirm the 0.34 and 0.35 cases fail, and restore it.

## 3. Pipeline: safe paths, raw outcome and the warning

- [x] 3.1 Write `correlia_server/test/unit/pipeline/unknown_field_warning_test.dart` for the warning formatter:
  `pipeline source=<uuid> unknown_top_level_fields=<count> tags=<t1,t2>`, each tag the first 12 hex of SHA-256 of
  the name, the count the listed plus overflow total, and the line never containing a listed name. Verify it
  fails (formatter missing).
- [x] 3.2 Write `correlia_server/test/db/pipeline_unknown_fields_test.dart` (`testGroupTagsOverride: ['db']`) with
  a captured log function: `future_top_level_field_is_processed_and_flagged` (events and output intents committed
  with the same identity as without the field; `outcome_json` has `unknown_top_level_fields: ['newField']` and
  `unknown_top_level_overflow: 0`; one warning with count 1 and the tag, never `newField`),
  `credential_shaped_unknown_key_never_logged` (the key equals a source token; it appears in no log line),
  `many_or_oversized_unknown_names` (16 listed, overflow 4, warning count 20 and 16 tags),
  `warning_lost_after_commit_is_not_retried` (the log function throws; the raw row is done with its names, a
  second claim pass does not process it again, and no later warning is logged), and `wrong_typed_group_metadata`
  (the `pipeline_failures` row names `routeLabels` or `notification_reason`, not `*`, and no event or intent
  commits). Also assert that a delivery without unknown fields carries both keys as `[]` and `0` (D2). Verify
  with `mise run test -- --tags db` that they fail for the right reason.
- [x] 3.3 In `correlia_server/lib/src/pipeline/pipeline.dart`: add `routeLabels` to `_safePath` (D5); write
  `unknown_top_level_fields` and `unknown_top_level_overflow` into the done row's `outcome_json` on every
  outcome (D2); give `PipelineRepository` and `PipelineSubsystem` an optional `void Function(String) log` and
  log the warning only after the done-row transaction commits, swallowing a failing log (D3, D4); add the
  formatter from 3.1. Wire the log in `correlia_server/lib/src/ingest/ingest_workers.dart` like the other
  subsystems. Verify 3.1 and 3.2 pass, the existing `pipeline_test.dart` and `pipeline_routing_test.dart` still
  pass (`mise run test -- --tags db`), and flip the rows green.
- [x] 3.4 Update `docs/ingest-pipeline.md`: supported Alertmanager releases 0.16-0.35 and the per-release field
  table; unknown top-level fields processed and flagged, unknown per-alert fields and wrong types fatal; the two
  new `outcome_json` keys; the warning format and what a tag is; an SQL query listing unknown names per source
  from `raw_inbox.outcome_json`. Update the AGENTS.md "reject unmapped fields loudly" rule with this one
  exception (Alertmanager top-level fields: processed and flagged). Verify by reading both against the spec
  delta.

## 4. Reproducible capture tooling and runbook

- [x] 4.1 Write `tool/alertmanager_capture.sh` (bash, Linux, Docker): for each requested release it writes an
  Alertmanager config (`group_wait: 1s`, `group_interval: 2s`, webhook to a local receiver, `send_resolved:
  true`), runs `prom/alertmanager:<v>` on host networking with `--cluster.listen-address=` on its own port,
  fires one alert through `/api/v2/alerts`, resolves it with `endsAt`, saves both notifications pretty-printed
  with sorted keys and `externalURL` replaced by `http://alertmanager.example:9093`, and always removes its
  containers and temporary folder on exit (a trap). The receiver is a small Dart or Python script inside the
  tool, bound to 127.0.0.1. Verify by running it for `v0.35.0` and one old release (`v0.16.2`) into a temporary
  directory and diffing against the fixtures (only timestamps may
  differ), then confirming with `docker ps -a` that no `amcap-*` container is left.
- [x] 4.2 Write `docs/runbooks/alertmanager-compatibility.md`: how the compatibility captures were made (Docker
  image per minor, config, ports, firing and resolving through the API, the receiver, sanitising), how to add a
  new release's fixture with `tool/alertmanager_capture.sh`, and the real-Alertmanager end-to-end check used for
  the M1 exit criterion (natsdev serve/stream/sub, ingest config with the `output-nats` plugin and its sha256, a
  secrets file at mode 0600, the server with `SERVERPOD_*_PORT` overrides and `--apply-migrations`, Alertmanager
  with a Bearer `credentials_file`, the console and the NATS subscriber), and teardown (remove containers and
  images, stop natsdev and the server, delete the temporary folders). Point the captures' evidence `README.md`
  at it. Verify every command in it by following it in 4.1 and 5.2.

## 5. Integration and the exit criterion

- [x] 5.1 Run `mise run check` and `mise run test:all`; both pass. Verify by their exit status and test counts.
- [x] 5.2 [evidence] Follow the runbook's end-to-end check against Alertmanager 0.35.0 and an older release
  (0.27): the alerts reach the console's alert list and the NATS subscriber, the raw rows show no unknown fields,
  and everything started is torn down → evidence/e2e-alertmanager-0.35.md
- [x] 5.3 [user] The owner points a real Alertmanager 0.35 at a dev instance, following
  `docs/runbooks/alertmanager-compatibility.md`, and sees the alerts in the console and on a NATS subscriber
  (M1 exit criterion). Checked by the owner on 2026-11-13: an alert from Alertmanager 0.35.0 fired and
  resolved, in the console and on the NATS subscriber (`EVENT_STATUS_FIRING`, then `EVENT_STATUS_RESOLVED`).
  The owner said "All good, tick the thing"; the agent ticked it on that instruction.

## Workflow follow-up

- Archive and finish locally (`finish: local`) once 5.3 is ticked.
- Re-run `/specwright-roadmap close` for M1.
