# Tasks

Plan only; no implementation tasks are complete. The FULL design gate passed in review round 3. All groups use the project AGENTS.md Dart/Serverpod rules and applicable installed skills. Add behavioral tests before implementation, use typed constructor-injected fakes only at pure boundaries, and use independent non-rollback embedded-Postgres connections for concurrency proofs. Run tests through Dart MCP (or the project mise task fallback), with explicit db/e2e tags. Never edit generated test tools or generated code by hand.

## Test map

All paths are relative to `correlia_server/`. These are planned tests, not executed results: every row starts red. Use the Test name column verbatim; parameterized cases cover each scenario's distinct edge conditions. Original map ids remain stable; review-added cases are T41–T54.

| # | Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|---|
| T01 | source-ingress: Source scoped authentication | Authenticated source delivery | `test/e2e/ingress_e2e_test.dart` | `authenticated_source_delivery` | red |
| T02 | source-ingress: Source scoped authentication | SEC-1 another source token | `test/e2e/ingress_e2e_test.dart` | `sec_1_another_source_token` | red |
| T03 | source-ingress: Credential safe request handling | SEC-5 path token redaction | `test/e2e/ingress_e2e_test.dart` | `sec_5_path_token_redaction` | red |
| T04 | source-ingress: Credential safe request handling | Conflicting credentials | `test/e2e/ingress_e2e_test.dart` | `conflicting_credentials` | red |
| T05 | source-ingress: Bounded durable admission | Accepted body above endpoint default | `test/e2e/ingress_e2e_test.dart` | `accepted_body_above_endpoint_default` | red |
| T06 | source-ingress: Bounded durable admission | Chunked oversized delivery | `test/e2e/ingress_e2e_test.dart` | `chunked_oversized_delivery` | red |
| T07 | source-ingress: Bounded durable admission | Admission commit fails | `test/db/ingress_test.dart` | `admission_commit_fails` | red |
| T08 | source-ingress: Atomic transport retry deduplication | ORD-5a concurrent exact retries | `test/db/transport_dedup_test.dart` | `ord_5a_concurrent_exact_retries` | red |
| T09 | source-ingress: Atomic transport retry deduplication | Key conflict and expiry | `test/db/transport_dedup_test.dart` | `key_conflict_and_expiry` | red |
| T10 | source-ingress: Validated immutable bootstrap configuration | Bootstrap publication and rotation | `test/db/ingest_config_test.dart` | `bootstrap_publication_and_rotation` | red |
| T11 | source-ingress: Validated immutable bootstrap configuration | Empty registry and missing secret | `test/db/ingest_config_test.dart` | `empty_registry_and_missing_secret` | red |
| T12 | integration-alertmanager: Per alert webhook decoding | Mixed group and upstream truncation | `test/unit/ingest/alertmanager_decoder_test.dart` | `mixed_group_and_upstream_truncation` | red |
| T13 | integration-alertmanager: Per alert webhook decoding | Unsupported version or malformed member | `test/unit/ingest/alertmanager_decoder_test.dart` | `unsupported_version_or_malformed_member` | red |
| T14 | integration-alertmanager: Per alert webhook decoding | Empty group | `test/unit/ingest/alertmanager_decoder_test.dart` | `empty_group` | red |
| T15 | integration-alertmanager: Canonical identity from original labels | ID-6 rebatching and fingerprint independence | `test/unit/ingest/alertmanager_decoder_test.dart` | `id_6_rebatching_and_fingerprint_independence` | red |
| T16 | integration-alertmanager: Canonical identity from original labels | ID-7b and ID-7c severity labels | `test/unit/ingest/alertmanager_decoder_test.dart` | `id_7b_and_id_7c_severity_labels` | red |
| T17 | integration-alertmanager: Explicit timestamp evidence | Firing zero end and resolved end | `test/unit/ingest/alertmanager_decoder_test.dart` | `firing_zero_end_and_resolved_end` | red |
| T18 | integration-alertmanager: Explicit timestamp evidence | Invalid source evidence | `test/unit/ingest/alertmanager_decoder_test.dart` | `invalid_source_evidence` | red |
| T19 | integration-alertmanager: Bounded explicit display and metadata mapping | Display and provenance mapping | `test/unit/ingest/alertmanager_decoder_test.dart` | `display_and_provenance_mapping` | red |
| T20 | integration-alertmanager: Bounded explicit display and metadata mapping | Map or aggregate event overflow | `test/unit/ingest/alertmanager_decoder_test.dart` | `map_or_aggregate_event_overflow` | red |
| T21 | durable-pipeline: Schema readiness on fresh and upgraded databases | Fresh and populated schema paths | `test/db/schema_step_test.dart` | `fresh_and_populated_schema_paths` | red |
| T22 | durable-pipeline: Schema readiness on fresh and upgraded databases | Failed schema step | `test/db/schema_step_test.dart` | `failed_schema_step` | red |
| T23 | durable-pipeline: Durable first claim configuration pin | Pin survives crash and activation | `test/e2e/pipeline_recovery_e2e_test.dart` | `pin_survives_crash_and_activation` | red |
| T24 | durable-pipeline: Durable first claim configuration pin | Concurrent claiming | `test/db/pipeline_test.dart` | `concurrent_claiming` | red |
| T25 | durable-pipeline: Atomic raw processing outcome | DUR-1 outbox failure rolls back event work | `test/db/pipeline_test.dart` | `dur_1_outbox_failure_rolls_back_event_work` | red |
| T26 | durable-pipeline: Atomic raw processing outcome | Invalid member after valid member | `test/db/pipeline_test.dart` | `invalid_member_after_valid_member` | red |
| T27 | durable-pipeline: Durable observation deduplication and quarantine | ORD-5b rebatching and expired transport window | `test/db/pipeline_test.dart` | `ord_5b_rebatching_and_expired_transport_window` | red |
| T28 | durable-pipeline: Durable observation deduplication and quarantine | Future quarantine does not poison dedup | `test/db/pipeline_test.dart` | `future_quarantine_does_not_poison_dedup` | red |
| T29 | durable-pipeline: Durable observation deduplication and quarantine | Late observation evidence | `test/db/pipeline_test.dart` | `late_observation_evidence` | red |
| T30 | durable-pipeline: Role scoped bounded lifecycle | Split roles and restart | `test/e2e/pipeline_lifecycle_e2e_test.dart` | `split_roles_and_restart` | red |
| T31 | durable-pipeline: Role scoped bounded lifecycle | Shutdown during processing | `test/e2e/pipeline_lifecycle_e2e_test.dart` | `shutdown_during_processing` | red |
| T32 | output-delivery: Immutable routed delivery intent | Fanout with configuration change | `test/db/pipeline_routing_test.dart` | `fanout_with_configuration_change` | red |
| T33 | output-delivery: Immutable routed delivery intent | Explicitly unrouted event | `test/db/pipeline_routing_test.dart` | `explicitly_unrouted_event` | red |
| T34 | output-delivery: Fenced at least once delivery | DUR-2 restart after processing commit | `test/e2e/output_recovery_e2e_test.dart` | `dur_2_restart_after_processing_commit` | red |
| T35 | output-delivery: Fenced at least once delivery | DUR-3 acknowledgement lost before local commit | `test/e2e/output_recovery_e2e_test.dart` | `dur_3_acknowledgement_lost_before_local_commit` | red |
| T36 | output-delivery: Fenced at least once delivery | Expired owner completion | `test/db/output_relay_test.dart` | `expired_owner_completion` | red |
| T37 | output-delivery: Isolated attempts retry and dead letters | One output fails while another succeeds | `test/e2e/output_delivery_e2e_test.dart` | `one_output_fails_while_another_succeeds` | red |
| T38 | output-delivery: Isolated attempts retry and dead letters | Interrupted attempt exhausts budget | `test/db/output_relay_test.dart` | `interrupted_attempt_exhausts_budget` | red |
| T39 | output-delivery: Signed structured webhook output | Receiver verifies signed event | `test/e2e/output_delivery_e2e_test.dart` | `receiver_verifies_signed_event` | red |
| T40 | output-delivery: Signed structured webhook output | Redirect timeout and rejection | `test/e2e/output_delivery_e2e_test.dart` | `redirect_timeout_and_rejection` | red |
| T41 | source-ingress: Credential safe request handling | Unconfigured ingress still protects token paths | `test/e2e/ingress_e2e_test.dart` | `unconfigured_ingress_still_protects_token_paths` | red |
| T42 | source-ingress: Validated immutable bootstrap configuration | Stale bootstrap cannot revoke the rotation | `test/db/ingest_config_test.dart` | `stale_bootstrap_cannot_revoke_the_rotation` | red |
| T43 | source-ingress: Validated immutable bootstrap configuration | Missing config with durable work | `test/e2e/pipeline_lifecycle_e2e_test.dart` | `missing_config_with_durable_work` | red |
| T44 | source-ingress: Validated immutable bootstrap configuration | Dead intent does not require signing material | `test/db/ingest_config_test.dart` | `dead_intent_does_not_require_signing_material` | red |
| T45 | integration-alertmanager: Canonical identity from original labels | Empty selected identity | `test/unit/ingest/alertmanager_decoder_test.dart` | `empty_selected_identity` | red |
| T46 | integration-alertmanager: Bounded explicit display and metadata mapping | Oversize identity label projection | `test/unit/ingest/alertmanager_decoder_test.dart` | `oversize_identity_label_projection` | red |
| T47 | output-delivery: Signing key availability before acquisition | Loaded historical signing reference | `test/e2e/output_delivery_e2e_test.dart` | `loaded_historical_signing_reference` | red |
| T48 | output-delivery: Signing key availability before acquisition | Unloaded live signing reference | `test/db/output_relay_test.dart` | `unloaded_live_signing_reference` | red |
| T49 | source-ingress: Validated immutable bootstrap configuration | Revert by higher revision | `test/db/ingest_config_test.dart` | `revert_by_higher_revision` | red |
| T50 | source-ingress: Validated immutable bootstrap configuration | Conflicting equal revision | `test/db/ingest_config_test.dart` | `conflicting_equal_revision` | red |
| T51 | source-ingress: Validated immutable bootstrap configuration | Missing worker config after drained queue | `test/e2e/pipeline_lifecycle_e2e_test.dart` | `missing_worker_config_after_drained_queue` | red |
| T52 | source-ingress: Validated immutable bootstrap configuration | Malformed secret or credential-bearing input is not echoed | `test/e2e/ingest_bootstrap_e2e_test.dart` | `malformed_secret_or_credential_bearing_input_is_not_echoed` | red |
| T53 | integration-alertmanager: Bounded explicit display and metadata mapping | Oversize annotation value | `test/unit/ingest/alertmanager_decoder_test.dart` | `oversize_annotation_value` | red |
| T54 | durable-pipeline: Atomic raw processing outcome | Processing budget exhaustion | `test/db/pipeline_test.dart` | `processing_budget_exhaustion` | red |

## 1. Identity evidence ADR and schema ownership

- [ ] 1.1 Write ADR 0024 per D6, restating 0019's identity decisions unchanged except upstream fingerprint evidence location; update architecture's in-force/superseded index, affected ownership/configuration/resource-bound sections and references, and correct the integration catalog. Verify the reviewed evidence mapping matches the existing codec and the ADR contains alternatives/reversal cost; keep accepted 0019 untouched.
- [ ] 1.2 Add failing fresh/populated/concurrent/failure schema tests T21–T22, then implement ordered schema steps, version lock/transactions and exception-table ownership. Add managed model definitions and generated migration/model outputs, never hand-edit generated definitions. Verify T21–T22 on embedded Postgres with independent connections and that the existing baseline data survives upgrade.
- [ ] 1.3 Run the schema initializer from normal startup and handwritten non-rollback db-test schema helper (leave generated tools untouched) after Serverpod managed migrations and before ingest work; document fresh/upgrade/repair ownership in docs/ingest-pipeline.md. Verify T21–T22 through both entry paths and the narrow existing startup-gate tests; schema failure must not start background work.

## 2. Immutable bootstrap and source credentials

- [ ] 2.1 Add failing T10–T11/T42/T44/T49–T50 configuration tests and actual-startup T52 and boundary cases for invalid registry references, secret-file permissions/size, repeated snapshot publication and secret-reference rebinding. Implement typed sanitized bootstrap parsing, monotonic revision activation/higher-revision revert, immutable snapshots, active pointer and source credential rotation through one transactional publication service (D1). Verify T10–T11 and rejected activation leaves the prior snapshot intact.
- [ ] 2.2 Implement historical signing-key reference validation, retained-output admission bounds and no-bootstrap behavior. Verify pending intents keep old material after rotation, missing/rebound live historical secrets prevent startup, dead intents need commitments only, stale bootstrap cannot reactivate revoked tokens, and removed sources cannot admit; add those behavioral cases beside T10–T11. Document real secret generation, file ownership, bounded non-secret example input and the non-reverting snapshot startup/rotation policy in docs/ingest-pipeline.md.

## 3. Secure HTTP admission and transport deduplication

- [ ] 3.1 Add failing actual-HTTP T01–T06/T41 before implementing session-independent ingress routes, reject-route coverage, source authentication, unpadded-base64url credential validation, readiness/admission gates and bounded streaming reads (D2). Verify source-mismatched tokens are 401, path credentials are absent from console/persistent session metadata/diagnostic events, conflicting forms reject, unconfigured /hooks stays session-safe, the existing admission slot is taken before the authentication lookup and saturation rejects without exhausting the shared DB pool, D7 counter snapshots match source/unknown outcomes without DB-source-lock writes, chunked overflow is 413, and a body above 512 KiB below the configured limit receives 202 with exact persisted bytes. Inspect rejection/error/close paths, not merely successful application logs.
- [ ] 3.2 Add failing T07–T09 using real Postgres, then implement atomic source-row recheck, transport-key reservation/expiry/conflict and raw insert. Verify concurrent equal requests create one raw row, changed-body key reuse conflicts, expiry is not sliding, and forced commit failure leaves neither reservation nor raw insertion.
- [ ] 3.3 Document bearer/path-token sender setup, Retry-After/status behavior, body limits and reverse-proxy redaction in docs/ingest-pipeline.md. Verify the guide's Correlia-owned example against T01/T05 and mark source-side UI captures as not collected rather than fabricating a screenshot or an owner's real-source result.

## 4. Alertmanager decoder and canonical mapping

- [ ] 4.1 Add failing T12–T20/T45–T46/T53 as pure deterministic decoder tests over Correlia-authored fixtures based on the documented v4 format (mark provenance). Implement typed JSON edge validation and complete field mapping with the existing event/identity/time codecs; no dynamic domain values, invented identity fields or arrival-derived times. Verify per-alert mixed status, zero-end semantics, exact timestamp evidence, default/excluded severity identity, rebatching independence, empty/truncated groups, empty-identity rejection, full-original long-label hashes versus truncated projections and long-annotation display truncation, and whole-delivery failures at actual canonical bounds.
- [ ] 4.2 Document field mapping and unsupported/custom fields beside the decoder fixtures and setup guide. Verify canonical structured CloudEvents produced by fixtures pass the existing full event codec; no new schema/protobuf baseline or identity bytes are introduced.

## 5. Pinned atomic pipeline processing

- [ ] 5.1 Add failing T24–T29, T32–T33/T54 against real Postgres, with independent connections for claim/dedup interleavings. Implement durable pin phase, locked bounded processing phase, sorted observation-key inserts, event dispositions, immutable event/output writes and raw/failure outcomes (D4). Verify transaction rollback removes keys/events/intents together, invalid siblings produce no partial effects, duplicate observations do not route and future quarantine can later admit its first eligible key; transient retries beyond five attempts retain their pin without consuming the internal-error budget, fanout bytes respect the aggregate batch bound and only repeated non-transient errors become processing_exhausted.
- [ ] 5.2 Add failing process-crash T23, then connect worker/all pipeline ownership to the existing subsystem lifecycle. Verify a committed pin survives kill/restart and a changed active snapshot; use explicit event/barrier synchronization, not sleeps. Any necessary fault switch must be test-run-mode-only with a rejection test outside test mode.
- [ ] 5.3 Document pin/retry/disposition/count semantics, SQL-only failure inspection and finite processing retry exhaustion in docs/ingest-pipeline.md. Verify the T54 non-transient exhaustion case added in 5.1 retains raw/config evidence, and verify no repeated internal failure silently discards accepted bytes. State explicitly that alert freshness/state, full ORD-5 and the complete DUR-1 state mutation extension belong to the following roadmap change.

## 6. Durable output relay and signed webhook

- [ ] 6.1 Add failing T36–T38/T48 at their mapped database/HTTP boundaries. Implement the narrow typed output contract, fenced DB-clock leases, durable started/interrupted attempts, finite retry/dead transitions and shared bounded discovery with independent per-output lanes (D5). Verify stale completions cannot mutate successor claims, interrupted attempts exhaust the budget and a failed output does not prevent a healthy output from delivering; missing live signing references remain queued without attempts and emit bounded diagnostics.
- [ ] 6.2 Add failing real-receiver T39–T40/T47; implement exact-byte CloudEvents POST, message id, HMAC signing, URL validation, non-followed redirects, bounded response draining and total HTTP deadline. Verify receiver-computed signatures, fixed ids/bytes, response classification and absent signing/response-body secrets in diagnostics.
- [ ] 6.3 Add failing T34–T35 real-process recovery tests using the receiver acknowledgement as a kill barrier. Verify pending work after processing commit is delivered after restart and remote-accepted/local-uncommitted work redelivers byte-identically with the same message id. Document at-least-once duplicates, attempt/dead inspection, old-target/key retention and HTTP-only development restrictions in docs/ingest-pipeline.md.

## 7. Integrated lifecycle proof

- [ ] 7.1 Add failing T30–T31/T43/T51 and complete api/worker/all registry composition, ingress-before-console mounting, schema/config admission gates and stop order. Verify api accepts while worker is absent, worker exposes no ingest route, a no-config worker with an active snapshot fails even after its queue drained rather than reporting ready, restart drains durable work and shutdown cancels acquisition/HTTP before sessions/database close. Reuse ChildServer file-backed logs, EOF shutdown and owned stable cluster roots; leave unrelated PostgreSQL untouched.
- [ ] 7.2 Run the focused tests named by all map rows through the Dart MCP test tool with explicit tier tags, then the project gate and non-load tiers through mise. Update README/setup links and the server changelog with delivered behavior and limits. Verify the complete config→HTTP→raw→canonical→signed receiver path with no placeholder stages or output adapter; do not claim the later console/NATS milestone acceptance.

## Workflow follow-up

- After implementation and its required pre-ship review, verify and archive via the separate OpenSpec workflow; do not tick archive/merge work in this implementation checklist.
- M1's owner real-Alertmanager/console/NATS criterion remains a milestone-close check, not an agent tick here. The next changes add state/live console and external NATS output before it can be judged.
