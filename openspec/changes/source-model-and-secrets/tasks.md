# Tasks

## Test map

Test paths are relative to `correlia_server/`. Tiers follow AGENTS.md: `test/unit` fast, `test/db` (`db` tag),
`test/e2e` (`e2e` tag, real `bin/main.dart` children), `test/plugin` (`plugin` tag).

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| secret-store → External key-encryption key | Key file accepted | `test/e2e/secret_store_e2e_test.dart` | `key_file_accepted` | green |
| secret-store → External key-encryption key | Key file rejected | `test/unit/secrets/key_file_test.dart` | `key_file_rejected` | green |
| secret-store → Encrypted secret records | Import seals secrets | `test/db/secret_store_test.dart` | `import_seals_secrets` | green |
| secret-store → Encrypted secret records | Rebinding refused | `test/db/secret_store_test.dart` | `rebinding_refused` | green |
| secret-store → Encrypted secret records | Tampered or moved record | `test/db/secret_store_test.dart` | `tampered_or_moved_record` | green |
| secret-store → Resolution from the store | Secret file not needed after import | `test/e2e/secret_store_e2e_test.dart` | `secret_file_not_needed_after_import` | green |
| secret-store → Resolution from the store | Fileless worker delivers both outputs | `test/plugin/fileless_worker_test.dart` | `fileless_worker_delivers_both_outputs` | green |
| secret-store → Resolution from the store | New reference without secret file | `test/db/secret_store_test.dart` | `new_reference_without_secret_file` | green |
| secret-store → Resolution from the store | M1 plugin work drains after upgrade | `test/plugin/secret_upgrade_test.dart` | `m1_plugin_work_drains_after_upgrade` | green |
| output-delivery → Kind-aware startup validation | M1 work with historical secret references drains after upgrade | `test/plugin/secret_upgrade_test.dart` | `m1_plugin_work_drains_after_upgrade` | green |
| output-delivery → Kind-aware startup validation | Missing webhook key still fails startup | `test/db/plugin_startup_secrets_test.dart` | `missing_webhook_key_fails_startup` | green |
| output-delivery → Kind-aware startup validation | Mixed live work with a missing plugin secret | `test/db/plugin_startup_secrets_test.dart` | `mixed_live_work_missing_plugin_secret` | green |
| output-delivery → Signing key availability before acquisition | Loaded historical signing reference | `test/db/output_relay_test.dart` | `loaded_historical_signing_reference` | green |
| output-delivery → Signing key availability before acquisition | Unloaded live signing reference | `test/db/output_relay_test.dart` | `unloaded_live_signing_reference` | green |
| output-delivery → Signing key availability before acquisition | Unverifiable pinned signing commitment | `test/db/output_relay_test.dart` | `unverifiable_pinned_signing_commitment` | green |
| secret-store → Resolution from the store | Historical outputs drain after a revision change | `test/plugin/fileless_worker_test.dart` | `historical_outputs_drain_after_a_revision_change` | green |
| secret-store → Resolution from the store | Plugin and webhook share a stored reference | `test/plugin/secret_upgrade_test.dart` | `plugin_and_webhook_share_a_stored_reference` | green |
| secret-store → Resolution from the store | More stored references than a process caches | `test/db/secret_store_test.dart` | `more_stored_references_than_a_process_caches` | green |
| secret-store → Resolution from the store | Wrong key after restore | `test/db/secret_store_test.dart` | `wrong_key_after_restore` | green |
| secret-store → Secret bytes never leave their consumer | SEC-3 plugin config secret | `test/e2e/secret_store_e2e_test.dart` | `sec_3_plugin_config_secret` | green |
| secret-store → Secret bytes never leave their consumer | Decryption failure stays sanitized | `test/db/secret_store_test.dart` | `decryption_failure_stays_sanitized` | green |
| source-ingress → Source scoped authentication | Authenticated source delivery | `test/e2e/ingress_e2e_test.dart` | `authenticated_source_delivery` (existing; re-run) | green |
| source-ingress → Source scoped authentication | SEC-1 another source token | `test/e2e/ingress_e2e_test.dart` | `sec_1_another_source_token` (existing; re-run) | green |
| source-ingress → Source scoped authentication | Route kind mismatch | `test/db/ingress_credentials_test.dart` | `route_kind_mismatch` | green |
| source-ingress → Source configuration format | Version 1 file still starts | `test/e2e/secret_store_e2e_test.dart` | `version_1_file_still_starts` | green |
| source-ingress → Source configuration format | Unsupported kind or field | `test/unit/ingest/source_config_test.dart` | `unsupported_kind_or_field` | green |
| source-ingress → Credential rotation with overlap | Overlapping rotation | `test/db/ingress_credentials_test.dart` | `overlapping_rotation` | green |
| source-ingress → Credential rotation with overlap | Expired and not yet valid credentials | `test/db/ingress_credentials_test.dart` | `expired_and_not_yet_valid_credentials` | green |
| source-ingress → Credential rotation with overlap | Rotation during a body read | `test/db/ingress_credentials_test.dart` | `rotation_during_a_body_read` | green |
| source-ingress → Credential rotation with overlap | Activation without a usable credential | `test/unit/ingest/source_config_test.dart` | `activation_without_a_usable_credential` | green |
| source-ingress → HMAC signed deliveries | Valid signature admitted | `test/db/ingress_credentials_test.dart` | `valid_signature_admitted` | green |
| source-ingress → HMAC signed deliveries | Bad, stale or misplaced signature | `test/db/ingress_credentials_test.dart` | `bad_stale_or_misplaced_signature` | green |
| source-ingress → HMAC signing input | Published signing vector | `test/unit/ingest/hmac_signing_test.dart` | `published_signing_vector` | green |
| source-ingress → HMAC signing input | Signed replay with a new idempotency key | `test/db/ingress_credentials_test.dart` | `signed_replay_with_a_new_idempotency_key` | green |
| source-ingress → Per source request rate | Burst within budget | `test/unit/ingest/rate_limiter_test.dart` | `burst_within_budget` | green |
| source-ingress → Per source request rate | Budget exceeded | `test/db/ingress_credentials_test.dart` | `budget_exceeded` | green |
| source-ingress → Per source request rate | Unauthenticated traffic spends no budget | `test/db/ingress_credentials_test.dart` | `unauthenticated_traffic_spends_no_budget` | green |
| source-ingress → Declared shared namespaces | ID-2 same names from two sources | `test/db/ingest_scenarios_test.dart` | `id_2_same_names_from_two_sources` | green |
| source-ingress → Declared shared namespaces | Undeclared or UUID shaped namespace | `test/unit/ingest/source_config_test.dart` | `undeclared_or_uuid_shaped_namespace` | green |
| integration-alertmanager → Bounded explicit display and metadata mapping | Display and provenance mapping | `test/unit/ingest/alertmanager_decoder_test.dart` | `display_and_provenance_mapping` (existing; re-run) | green |
| integration-alertmanager → Bounded explicit display and metadata mapping | Map or aggregate event overflow | `test/unit/ingest/alertmanager_decoder_test.dart` | `map_or_aggregate_event_overflow` (existing; re-run) | green |
| integration-alertmanager → Bounded explicit display and metadata mapping | Oversize identity label projection | `test/unit/ingest/alertmanager_decoder_test.dart` | `oversize_identity_label_projection` (existing; re-run) | green |
| integration-alertmanager → Bounded explicit display and metadata mapping | Oversize annotation value | `test/unit/ingest/alertmanager_decoder_test.dart` | `oversize_annotation_value` (extended in 7.1) | green |
| integration-alertmanager → Bounded explicit display and metadata mapping | ID-3 maximum length values through HTTP ingress | `test/db/ingest_scenarios_test.dart` | `id_3_maximum_length_values_through_http_ingress` | green |

Scenario names in `test/` match the scenario names above, so the M2 close can find ID-2, ID-3 and SEC-3 by
name. Every `withServerpod` call names its tier tag. Clocks, rate-limit time and HMAC timestamps are
injected; no test sleeps. Concurrency in `rotation_during_a_body_read` is driven by a completer that holds
the request body open while the publication commits.

## 1. ADRs and architecture

- [x] 1.1 Write `docs/adr/0028-encrypted-secret-store.md` (design D1–D5, D8: algorithm, record and AAD
  format, scheme-tagged commitments with keyed plugin commitments, key file, import-then-resolve, residual
  M1 hash exposure, D31 default taken by the agent) and `docs/adr/0029-source-credentials-and-admission-limits.md`
  (D6, D7 with the exact signing-input bytes, D9, D10, D11), both `Status: accepted` with today's date after
  this review, MADR-short form, each with its rejected alternative and reversal cost. Add both rows to the
  in-force index in `openspec/architecture.md`, rewrite its "Plugin configs and secrets" state row (secrets
  encrypted in Postgres under an external key; the operator file is an import input) and the "M1 ingest
  configuration" paragraph. Verify: `mise run check` passes (validate step) and `grep -n "0028\|0029"
  openspec/architecture.md` shows both index rows.

## 2. Key file, AEAD and commitments

Skills: `dart-use-pattern-matching`, `dart-write-documentation`, `dart-run-static-analysis`, `dart-add-unit-test`.

- [x] 2.1 Write failing `test/unit/secrets/key_file_test.dart` (`key_file_rejected`: absent, group-readable,
  symlink, other owner, wrong length, padded or non-canonical base64url; assert the error has file kind
  `secret_key`, a fixed code, and that no file content appears in `toString()`) and
  `test/unit/secrets/aead_test.dart` (NIST AES-256-GCM vectors; AAD tamper, nonce tamper, ciphertext and tag
  tamper all fail; two seals of equal bytes differ; keyed plugin commitment and HKDF match fixed vectors;
  bare-hex and `hmac-sha256:` commitments verify by scheme and reject the other scheme's value). Run
  `mise run test -- test/unit/secrets`: they fail because `lib/src/secrets/` does not exist.
- [x] 2.2 Implement `lib/src/secrets/`: key file loader (reusing the secret-file ownership, mode and symlink
  checks from `bootstrap.dart`), OpenSSL EVP AES-256-GCM and `RAND_bytes` over FFI on `libcrypto.so.3` with
  native buffers zeroed and freed in `finally` and `crypto_unavailable` when the library is missing, key
  commitment, HKDF-SHA256 commitment key and the scheme-tagged commitment verifier. Verify: both unit test
  files pass and flip `key_file_rejected` green; `mise run check` is clean.

## 3. Secret store, migration and publication import

Skills: `serverpod-models`, `serverpod-database`, `serverpod-migrations`, `serverpod-testing`, plus group 2's.

- [x] 3.1 Write failing `test/db/secret_store_test.dart` with `import_seals_secrets`, `rebinding_refused`,
  `tampered_or_moved_record`, `new_reference_without_secret_file`, `wrong_key_after_restore`,
  `more_stored_references_than_a_process_caches` (cache bound injected as 4, more than 4 references across
  successive publications, every one resolves) and `decryption_failure_stays_sanitized` (captured log lines
  contain only reference and code). Run `mise run test -- --tags db test/db/secret_store_test.dart`: they fail.
- [x] 3.2 Add the managed models `secret_record` (D2) and `ingest_source_credential` (D6) and the
  non-null `ingest_source.kind` (`String, default='alertmanager'`). Generate code and one managed migration
  with the deliberate destructive drop of `ingest_source.tokenDigest`; inspect and remove unrelated
  operations on SQL-owned tables per `docs/ingest-pipeline.md`. Verify: the `mise run check` generated-code
  step and `test/db/schema_step_test.dart` pass; apply the migration to a populated M1 database and assert
  the old source rows retain their UUIDs and have `kind=alertmanager`.
- [x] 3.3 Implement the store and the `SecretResolver` LRU (1024 entries / 16 MiB, store fallback through the
  four-lookup gate, 5 s read timeout) and change `IngestConfigRepository.publish` to import unstored
  references under the advisory lock, including file entries pinned by live webhook intents or plugin
  definitions absent from the new config. Verify pinned commitments by scheme, detect rebinding by
  decrypted-byte comparison (keeping the M1 `ingest_secret_commitment` check for unstored references),
  refuse `key_mismatch`, and write credential rows. Validate live webhook keys against the store in the
  publication transaction, including records it imports; update `missing_webhook_key_fails_startup` to
  seed a reference absent from both store and file. Change `IngestBootstrap.load` so the secret file is
  optional when the config file is set, and `IngestStartup` to load the key file and resolve from the store.
  In the same group as the column
  drop, move existing bearer/path lookup and the transactional admission fence to credential rows in
  `ingress.dart` and `admission.dart`. In `test/db/ingest_config_test.dart`, assert credential rows instead
  of `tokenDigest` and rotate under new references. Keep plugin snapshots in the M1 commitment scheme
  until group 4; the group 3 resolver must already verify both schemes. Update
  `test/unit/ingest/bootstrap_file_test.dart` for an optional secret file, and update affected admission
  test inputs. Add `secret_record` and `ingest_source_credential` to explicit DB/plugin cleanup wherever
  rollback is disabled (including ingest config, startup secrets, transport dedup, pipeline, alert state,
  and plugin supervision suites). Update the e2e harness to supply a 0600 key file to configured children.
  Before switching consumers, add `fileless_worker_delivers_both_outputs` and
  `historical_outputs_drain_after_a_revision_change` in `test/plugin/fileless_worker_test.dart` (`plugin`).
  Restart without the secret file after importing revision A in both cases. In the second case, publish
  revision B to remove both references while the fileless worker stays running, then drain revision A's
  pinned work without another restart. Run `mise run test -- --tags plugin test/plugin/fileless_worker_test.dart`
  and confirm both fail. Add `unverifiable_pinned_signing_commitment` in `test/db/output_relay_test.dart`
  before the cutover: a present record with a mismatched pinned commitment leaves its intent queued,
  keeps `attempt_count` unchanged, writes no attempt row, emits a rate-limited diagnostic with only
  output, reference and fixed code, and does not block unrelated outputs.
  Move webhook relay and plugin Configure readers to `SecretResolver.resolve(reference, commitment)`
  before allowing fileless startup. Discover candidates by record reference, resolve before holding
  the claim transaction, and recheck the selected reference and pinned commitment before starting
  an attempt. Emit the same rate-limited diagnostic on claim-time resolution failure; remove
  `loadedReferences`. Verify the affected unit tests and `mise run test -- --tags db` and
  `mise run test -- --tags plugin`. Flip the group 3 rows green, including the two new plugin tests,
  `loaded_historical_signing_reference`, `unloaded_live_signing_reference`,
  `unverifiable_pinned_signing_commitment`, `missing_webhook_key_fails_startup` and
  `mixed_live_work_missing_plugin_secret`.

## 4. Secret consumers and historical work

Skills: group 3's.

- [x] 4.1 Write failing `test/plugin/secret_upgrade_test.dart`: `m1_plugin_work_drains_after_upgrade` (seed
  queued plugin outbox rows pinned to an M1 definition with a bare SHA-256 commitment and an M1 webhook
  row pinned to a historical signing key; both references are absent from the upgraded config but present
  in the M1 secret file. Publish with the M1 secret file and key, assert historical records imported and
  startup succeeded, restart without the file at a higher revision, and assert both deliveries succeed with
  the original bytes and unchanged pinned digest; new plugin definitions carry `hmac-sha256:` commitments)
  and `plugin_and_webhook_share_a_stored_reference` (both drain using one record with different pinned
  schemes; an intent with the wrong commitment cannot start a delivery attempt). Before changing the
  writer, also add assertions in `test/db/ingest_config_test.dart` for the keyed commitment, an unchanged
  restart with the file present, and a rejected rebinding of the stored keyed reference
  (`reference_rebound`; record and active snapshot unchanged). Run the focused plugin and DB tests
  (`mise run test -- --tags plugin test/plugin/secret_upgrade_test.dart` and
  `mise run test -- --tags db test/db/ingest_config_test.dart`); the new keyed-commitment cases are red.
- [x] 4.2 Switch the plugin snapshot commitment writer to `hmac-sha256:` and update the
  `plugin_output_activates` assertion in `ingest_config_test.dart`. The consumer cutover is already
  verified in group 3; preserve the old pins and prove that both schemes resolve. Write keyed
  plugin values to `ingest_secret_commitment`; limit the legacy comparison to references without
  a stored record in the transaction and verify by the recorded scheme.
  Verify: group 4 tests pass and flip green; `mise run test -- --tags db` and `--tags plugin` pass.

## 5. Source configuration format version 2

Skills: group 2's.

- [x] 5.1 Write failing `test/unit/ingest/source_config_test.dart`: `unsupported_kind_or_field`,
  `activation_without_a_usable_credential` (five credentials, duplicate reference, all expired relative to an
  injected clock, `not_before >= not_after`), `undeclared_or_uuid_shaped_namespace`, plus version 1 mapping
  (one bearer credential, kind `alertmanager`, default rate limit, namespace kept) and rate-limit bounds. Run
  `mise run test -- test/unit/ingest/source_config_test.dart`: they fail.
- [x] 5.2 Implement the version 2 parser (in a new `lib/src/ingest/source_config.dart`, keeping
  `bootstrap.dart` focused on files and secrets), the version 1 mapping, declared namespaces and the snapshot
  version 2 shape; retain the existing routing and identity fields so M1 and v2 pins both work. Share
  reference parsing with stored-material lookup (`token_ref` and `credentials[].ref`). In the common
  `_publish` path, after parsing and before any writes, reject v2 at `format_version` with a distinct
  `not_enabled` code. In `test/db/ingest_config_test.dart`, add `v2_publication_cutover`: both publication
  paths reject v2 (including fileless input using stored references), preserve the active snapshot and
  add no snapshot, secret or credential rows; a higher v1 revision still publishes and admits its bearer
  over HTTP. In `docs/ingest-pipeline.md` ("Bootstrap and rotation"), document the upcoming v2 example,
  credentials and windows, namespaces and rate limits without advertising live activation yet,
  `CORRELIA_SECRET_KEY_FILE` with key generation, the one-time revision bump on upgrade, key backup and loss,
  per-process rate limits with several api processes, rotation under new source references instead of
  overwriting an existing `token_ref`, and rotating low-entropy M1 plugin secrets. Verify:
  group 5 tests pass and flip green; `mise run check`, the DB and plugin tiers, and the
  `authenticated_source_delivery` and `sec_1_another_source_token` e2e cases pass.

## 6. Ingress: kinds, credentials, HMAC and rate limits

Skills: `serverpod-webserver`, `serverpod-database`, `serverpod-testing`, plus group 2's.

- [x] 6.1 Write failing `test/unit/ingest/hmac_signing_test.dart` (`published_signing_vector`, using the vector
  also printed in `docs/ingest-pipeline.md`) and `test/unit/ingest/rate_limiter_test.dart`
  (`burst_within_budget`, refill and `Retry-After` arithmetic with an injected clock, rekey on revision). Run
  `mise run test -- test/unit/ingest`: the new tests fail.
- [x] 6.2 Write failing `test/db/ingress_credentials_test.dart` over real HTTP: `route_kind_mismatch`,
  `overlapping_rotation`, `expired_and_not_yet_valid_credentials`, `rotation_during_a_body_read`,
  `valid_signature_admitted` (raw row stores no signature or timestamp header),
  `bad_stale_or_misplaced_signature` (captured logs contain neither signature nor key),
  `signed_replay_with_a_new_idempotency_key` (including the `k`/`1.23` versus `k.1`/`23` pair),
  `budget_exceeded` and `unauthenticated_traffic_spends_no_budget`. Run
  `mise run test -- --tags db test/db/ingress_credentials_test.dart`: they fail.
- [x] 6.3 Extend the group 3 credential-row lookup and admission fence in `ingress.dart` and `admission.dart`:
  `/hooks/<kind>/<id>` routing with the kind check, lookup over at most four rows with no early exit and
  receipt-time windows, HMAC (header checks and timestamp before buffering, signature after bounded read,
  keys from the resolver), and the post-authentication token bucket (429 with `Retry-After`, counted as
  rejected). Complete the `FOR SHARE` recheck of credential, kind, enabled and path-token policy.
  Remove the temporary publication gate. Replace the rejection in `v2_publication_cutover` with a
  fileless v2 publication using stored credentials and a 202 bearer admission. Verify group 6 tests pass and flip green;
  `authenticated_source_delivery`, `sec_1_another_source_token`, `test/db/ingress_http_test.dart`,
  `test/db/ingress_test.dart` and `test/db/transport_dedup_test.dart` still pass.

## 7. Named scenarios and process-level proofs

Skills: `serverpod-testing`, `dart-add-unit-test`.

- [x] 7.1 Write `test/db/ingest_scenarios_test.dart`: `id_2_same_names_from_two_sources` (two default
  namespaces → two fingerprints and two alerts; two sources in one declared namespace → one fingerprint and
  one alert; distinct observation ids) and `id_3_maximum_length_values_through_http_ingress` (256-byte
  `instance` label, 4097-scalar description, second delivery differing only in the last scalar, neither
  with an `Idempotency-Key`: both 202, two byte-exact raw rows, one event and one duplicate observation,
  4096 description scalars and 1024 annotation scalars ending with the marker, label whole, one fingerprint,
  no pipeline failure row and no 5xx). Add exact-length assertions to `oversize_annotation_value` before
  changing the display description to use the original annotation; include a value between the bounds.
  Identity and deduplication are unchanged.
  Verify: both named DB scenarios and the decoder regression pass; flip green.
- [x] 7.2 Write `test/e2e/secret_store_e2e_test.dart` over real `bin/main.dart --mode test` children:
  `key_file_accepted` (no table dump or child log contains the key or its text), `version_1_file_still_starts`
  (seed the old M1 revision, assert the equal-revision publication conflicts and leaves the old snapshot active,
  then bump the revision and verify the existing token, UUID and namespace), `secret_file_not_needed_after_import` and
  `sec_3_plugin_config_secret` (plugin output with a secret, Configure failure echoing it, every existing
  endpoint and the public snapshot read back, console and persistent logging on; the bytes and their
  base64url form appear in no response, row dump, log file or captured output). Verify: all pass with
  `mise run test -- --tags e2e`, and flip green.
- [x] 7.3 Re-run the unchanged rows (`display_and_provenance_mapping`, `map_or_aggregate_event_overflow`,
  `oversize_identity_label_projection`, `authenticated_source_delivery`, `sec_1_another_source_token`): all pass.

## 8. Integration

- [ ] 8.1 Run `mise run check` and `mise run test:all`: both pass. Confirm every Test map row is green.

## Workflow follow-up

- The M2 user-verified criterion (a day of real feeds checked by the owner) is judged at the M2 close, after
  `icinga2-ingest` and `thanos-and-generic-webhook`; this change adds no `[user]` task.
- D31 remains open for the owner in `docs/plan/open-decisions.md`; this change follows its assumed default.
