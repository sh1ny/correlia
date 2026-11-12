# Tasks

## Test map

Paths are relative to the repository root. `S/` is `correlia_server/test/`, `T/` is `tool/test/`.
Tiers: `unit/` fast, `db/` db, `plugin/` plugin, `e2e/` e2e.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| plugin-output-protocol → Versioned plugin identification | Output plugin identifies itself | S/plugin/plugin_protocol_test.dart | output_plugin_identifies_itself | green |
| plugin-output-protocol → Versioned plugin identification | Plugin without the output kind | S/plugin/plugin_protocol_test.dart | plugin_without_output_kind | green |
| plugin-output-protocol → Versioned plugin identification | Spike probe cookie | S/plugin/plugin_protocol_test.dart | spike_probe_cookie_rejected | green |
| plugin-output-protocol → Configuration with separated secrets | Accepted configuration | S/plugin/plugin_protocol_test.dart | accepted_configuration | green |
| plugin-output-protocol → Configuration with separated secrets | Rejected configuration | S/plugin/plugin_protocol_test.dart | rejected_configuration | green |
| plugin-output-protocol → Credit-controlled batched delivery | Batches within limits | S/plugin/plugin_protocol_test.dart | batches_within_limits | green |
| plugin-output-protocol → Credit-controlled batched delivery | Batches within limits | S/db/plugin_relay_test.dart | aggregate_limit_defers_fitting_event | green |
| plugin-output-protocol → Credit-controlled batched delivery | Plugin advertises limits above the host bounds | S/plugin/plugin_protocol_test.dart | plugin_limits_above_host_bounds | green |
| plugin-output-protocol → Per-event delivery outcome | Mixed outcomes in one batch | S/plugin/plugin_protocol_test.dart | mixed_outcomes_in_one_batch | green |
| plugin-output-protocol → Per-event delivery outcome | Malformed batch answer | S/plugin/plugin_protocol_test.dart | malformed_batch_answer | green |
| plugin-output-protocol → Plugin health reporting | Plugin reports serving | S/plugin/plugin_protocol_test.dart | plugin_reports_serving | green |
| plugin-output-protocol → Plugin health reporting | Health call stalls | S/plugin/plugin_protocol_test.dart | health_call_stalls | green |
| plugin-supervision → Verified plugin launch | Pinned executable launches | S/plugin/plugin_supervision_test.dart | pinned_executable_launches | green |
| plugin-supervision → Verified plugin launch | Replaced or unsafe executable | S/plugin/plugin_supervision_test.dart | replaced_or_unsafe_executable | green |
| plugin-supervision → Restart with backoff | DUR-8 plugin crashes mid-stream | S/e2e/nats_dur8_e2e_test.dart | DUR-8 plugin crashes mid-stream | green |
| plugin-supervision → Restart with backoff | Repeated startup failure grows the delay | S/unit/plugin/supervision_policy_test.dart | repeated_startup_failure_grows_delay | green |
| plugin-supervision → Crash budget circuit | DUR-8 crash budget exceeded | S/e2e/nats_dur8_e2e_test.dart | DUR-8 crash budget exceeded | green |
| plugin-supervision → Crash budget circuit | Degraded plugin recovers | S/unit/plugin/supervision_policy_test.dart | degraded_plugin_recovers | green |
| plugin-supervision → Fair instance slots | More busy outputs than slots | S/unit/plugin/slot_scheduler_test.dart | more_busy_outputs_than_slots | green |
| plugin-supervision → Fair instance slots | Idle active output releases its slot | S/unit/plugin/slot_scheduler_test.dart | idle_active_output_releases_slot | green |
| plugin-supervision → Fair instance slots | Idle active output releases its slot | S/plugin/plugin_supervision_test.dart | held_permit_survives_voluntary_idle | green |
| plugin-supervision → Fair instance slots | More live definitions than one sweep page | S/db/plugin_admission_test.dart | pinned_generations_beyond_one_page | green |
| plugin-supervision → Fair instance slots | Five busy definitions of one output | S/unit/plugin/slot_scheduler_test.dart | five_busy_definitions_of_one_output | green |
| plugin-supervision → Fair instance slots | Probe under slot contention | S/unit/plugin/slot_scheduler_test.dart | probe_under_slot_contention | green |
| plugin-supervision → Fair instance slots | Healthy definition at the end of a long queue | S/unit/plugin/slot_scheduler_test.dart | healthy_definition_at_end_of_long_queue | green |
| plugin-supervision → Fair instance slots | Healthy definition behind unavailable historical ones | S/unit/plugin/slot_scheduler_test.dart | healthy_behind_unavailable_historical | green |
| plugin-supervision → Durable supervision history | Failing definitions cycle through slots | S/db/plugin_health_test.dart | failing_definitions_cycle_through_slots | green |
| plugin-supervision → Persisted plugin status | Status of a ready plugin | S/plugin/plugin_supervision_test.dart | status_of_a_ready_plugin | green |
| plugin-supervision → Persisted plugin status | Worker killed | S/e2e/nats_burst_e2e_test.dart | worker_killed_status_goes_stale | green |
| plugin-supervision → Bounded plugin shutdown | Graceful worker stop | S/e2e/nats_shutdown_e2e_test.dart | graceful_worker_stop | green |
| plugin-supervision → Bounded plugin shutdown | Graceful worker stop | S/db/plugin_relay_shutdown_test.dart | does not send a committed claim and recovers it | green |
| plugin-supervision → Bounded plugin shutdown | Graceful worker stop | S/plugin/plugin_supervision_test.dart | held_permit_survives_voluntary_shutdown | green |
| plugin-supervision → Bounded plugin shutdown | Plugin ignores shutdown | S/plugin/plugin_supervision_test.dart | plugin_ignores_shutdown | green |
| integration-nats → Event subject scheme | Alert event subject | S/plugin/nats_output_test.dart | alert_event_subject | green |
| integration-nats → Event subject scheme | Unsafe subject token | S/plugin/nats_output_test.dart | unsafe_subject_token | green |
| integration-nats → Exact body and identifying headers | Subscriber parses the event | S/plugin/nats_output_test.dart | subscriber_parses_the_event | green |
| integration-nats → Exact body and identifying headers | Envelope without traceparent | S/plugin/nats_output_test.dart | envelope_without_traceparent | green |
| integration-nats → Acknowledged and deduplicated publish | DUR-3 redelivery after the acknowledgement was lost | S/e2e/nats_dur3_e2e_test.dart | DUR-3 redelivery after the acknowledgement was lost | green |
| integration-nats → Acknowledged and deduplicated publish | NATS unavailable | S/plugin/nats_output_test.dart | nats_unavailable | green |
| integration-nats → Acknowledged and deduplicated publish | Payload too large | S/plugin/nats_output_test.dart | payload_too_large | green |
| integration-nats → Operator-owned stream | Stream captures the subjects | S/plugin/nats_output_test.dart | stream_captures_the_subjects | green |
| integration-nats → Operator-owned stream | No stream for the subjects | S/plugin/nats_output_test.dart | no_stream_for_the_subjects | green |
| integration-nats → Credentials only from secrets | Token authentication | S/plugin/nats_output_test.dart | token_authentication | green |
| integration-nats → Credentials only from secrets | Wrong credentials | S/plugin/nats_output_test.dart | wrong_credentials | green |
| integration-nats → Exit when the host is gone | Worker killed with SIGKILL | S/e2e/nats_burst_e2e_test.dart | nats_plugin_exits_after_host_sigkill | green |
| integration-nats → Exit when the host is gone | Stdin stays open | S/plugin/nats_output_test.dart | stdin_stays_open | green |
| output-delivery → Kind-aware startup validation | Restart with pending unauthenticated plugin work | S/db/plugin_startup_secrets_test.dart | restart_with_pending_unauthenticated_plugin_work | green |
| output-delivery → Kind-aware startup validation | Mixed live work with a missing plugin secret | S/db/plugin_startup_secrets_test.dart | mixed_live_work_missing_plugin_secret | green |
| output-delivery → Kind-aware startup validation | Missing webhook key still fails startup | S/db/plugin_startup_secrets_test.dart | missing_webhook_key_fails_startup | green |
| output-delivery → Kind-aware startup validation | Plugin secret reference rebound | S/db/ingest_config_test.dart | plugin_secret_reference_rebound | green |
| output-delivery → Validated plugin output definitions | Plugin output activates | S/db/ingest_config_test.dart | plugin_output_activates | green |
| output-delivery → Validated plugin output definitions | Invalid plugin output | S/unit/ingest/bootstrap_test.dart | invalid_plugin_output | green |
| output-delivery → Plugin secret values | Secret file sizes | S/unit/ingest/bootstrap_file_test.dart | secret_file_sizes | green |
| output-delivery → Plugin secret values | Long plugin secret | S/unit/ingest/bootstrap_test.dart | long_plugin_secret | green |
| output-delivery → Readiness-gated plugin acquisition | Plugin degraded while work is queued | S/db/plugin_relay_test.dart | plugin_degraded_while_work_queued | green |
| output-delivery → Readiness-gated plugin acquisition | Plugin becomes ready again | S/db/plugin_relay_test.dart | plugin_becomes_ready_again | green |
| output-delivery → Readiness-gated plugin acquisition | Older unavailable definition beside a ready one | S/db/plugin_relay_test.dart | older_unavailable_beside_ready | green |
| output-delivery → Readiness-gated plugin acquisition | Instance leaves ready between selection and claim | S/db/plugin_relay_test.dart | instance_leaves_ready_before_permit | green |
| output-delivery → Readiness-gated plugin acquisition | Plugin exit observed while the claim is still open | S/db/plugin_relay_test.dart | plugin_exit_observed_during_open_claim | green |
| output-delivery → Readiness-gated plugin acquisition | Plugin exit observed while the claim is still open | S/db/plugin_relay_test.dart | oversized_rejection_rolls_back_on_readiness_loss | green |
| output-delivery → Pinned plugin definition delivery | NATS stream changed with work pending | S/e2e/nats_pinning_e2e_test.dart | nats_server_changed_with_work_pending | green |
| output-delivery → Pinned plugin definition delivery | Pinned definition cannot run | S/plugin/plugin_supervision_test.dart | pinned_definition_cannot_run | green |
| output-delivery → Batched plugin delivery with per-event completion | Batch with one bad event | S/db/plugin_relay_test.dart | batch_with_one_bad_event | green |
| output-delivery → Batched plugin delivery with per-event completion | Batch with one bad event | S/db/plugin_relay_test.dart | oversized_oldest_does_not_block_definition | green |
| output-delivery → Batched plugin delivery with per-event completion | Batch with one bad event | S/db/plugin_relay_test.dart | only_oversized_commits_deadletters | green |
| output-delivery → Batched plugin delivery with per-event completion | Plugin dies with the batch unanswered | S/plugin/plugin_supervision_test.dart | plugin_dies_with_batch_unanswered | green |
| output-delivery → Batched plugin delivery with per-event completion | Plugin dies with the batch unanswered | S/plugin/plugin_supervision_test.dart | held_permit_survives_voluntary_failure | green |
| output-delivery → Batched plugin delivery with per-event completion | Full batch completed within its budget | S/db/plugin_relay_test.dart | full_batch_within_budget | green |
| output-delivery → Batched plugin delivery with per-event completion | Batch over its deadline | S/plugin/nats_relay_deadline_test.dart | batch_over_its_deadline | green |
| output-delivery → Batched plugin delivery with per-event completion | Stale batch completion | S/db/plugin_relay_test.dart | stale_batch_completion | green |
| output-delivery → No loss across worker death | Kill -9 during a 1,000-alert burst | S/e2e/nats_burst_e2e_test.dart | Kill -9 during a 1,000-alert burst | green |
| output-delivery → No loss across worker death | Worker killed before any delivery | S/e2e/nats_burst_e2e_test.dart | worker_killed_before_any_delivery | green |
| output-delivery → Signing key availability before acquisition (MODIFIED) | Loaded historical signing reference | S/db/output_relay_test.dart | loaded_historical_signing_reference | green |
| output-delivery → Signing key availability before acquisition (MODIFIED) | Unloaded live signing reference | S/db/output_relay_test.dart | unloaded_live_signing_reference | green |
| output-delivery → Signing key availability before acquisition (MODIFIED) | Plugin intents need no signing reference | S/db/plugin_relay_test.dart | plugin_intents_need_no_signing_reference | green |
| workspace-tooling → Reproducible plugin protocol generation | Current protocol outputs | T/proto_command_test.dart | plugin_protocol_outputs_current | green |
| workspace-tooling → Reproducible plugin protocol generation | Stale protocol output | T/proto_command_test.dart | stale_plugin_protocol_output | green |
| workspace-tooling → Pinned plugin and NATS tool builds | Plugin tier on a clean clone | T/plugin_build_test.dart | plugin_tier_on_clean_clone | green |
| workspace-tooling → Pinned plugin and NATS tool builds | Module checksum mismatch | T/plugin_build_test.dart | module_checksum_mismatch | green |
| workspace-tooling → Tests use only their own NATS server | Test-owned server | S/plugin/natsdev_test.dart | test_owned_server | green |
| workspace-tooling → Tests use only their own NATS server | Server fails to start | S/plugin/natsdev_test.dart | server_fails_to_start | green |

## 1. Decision records

- [x] 1.1 Write `docs/adr/0025-plugin-protocol-v1-output-contract-and-supervision.md` (Status: accepted) covering D1, D4, D5, D6 as policy, D7, D12, D15, D18 and D19, each with its rejected alternative and reversal cost; verify by `mise run spec:validate` and a read-back against design.md's Decision summary.
- [x] 1.2 Update `openspec/architecture.md`: the Boundaries plugin-protocol bullet, the outbox, plugin status and plugin health ownership rows, the plugin-process resource bound, and ADR 0025 in the in-force index; verify by `mise run check` (validate step) passing.

## 2. Protocol, Go layout and NATS tooling

- [x] 2.1 Write failing `T/proto_command_test.dart` cases `plugin_protocol_outputs_current` and `stale_plugin_protocol_output`; verify they fail because `proto/correlia/plugin/v1/` does not exist yet.
- [x] 2.2 Add `proto/correlia/plugin/v1/plugin.proto` (D1: `PluginService`, `OutputService.Deliver`, error-class pattern) and extend `mise run proto` / `proto:check` and `buf lint` to generate the Dart and Go code; verify the 2.1 tests pass, the event-v1.0 baseline is byte-identical, and flip their rows green.
- [x] 2.3 Write failing `T/plugin_build_test.dart` cases `plugin_tier_on_clean_clone` and `module_checksum_mismatch`; verify they fail on the missing `plugins:build` task.
- [x] 2.4 Create the Go modules `plugins/` (`github.com/sh1ny/correlia/plugins`, output-nats skeleton on stock `plugin.Serve()` with the ADR 0018 stdin watcher) and `tool/natsdev/` (`serve`/`stream`/`sub`, pinned `nats-server` and `nats.go` with `go.sum`); add mise tasks `plugins:build`, `nats:dev`, `nats:stream`, `nats:sub`, and make the `plugin` and `e2e` tiers build first (D12, D13); verify the 2.3 tests pass and flip their rows green.
- [x] 2.5 Write failing `S/plugin/natsdev_test.dart` cases `test_owned_server` and `server_fails_to_start`, then add the test support that starts `natsdev serve` on a free loopback port with private scratch storage and removes it on teardown; verify both pass, that no other NATS is contacted, and flip their rows green.

## 3. Outbox schema, bootstrap and secrets

- [x] 3.1 Write failing `S/unit/ingest/bootstrap_test.dart` cases `invalid_plugin_output` and `long_plugin_secret`, and `S/unit/ingest/bootstrap_file_test.dart` case `secret_file_sizes` (real files through `IngestBootstrap.load`: 300 KiB encoded passes, decoded total and encoded limit fail `bound`); verify they fail for the right reason.
- [x] 3.2 Implement the plugin output keys and `CORRELIA_PLUGIN_DIR` checks (D9), the `{"bytes": ...}` secret form with the 16 KiB / 256 KiB bounds and 32-byte checks for source and webhook references, and the per-kind loader cap of 512 KiB for secrets while config stays 64 KiB; verify the 3.1 tests pass, existing bootstrap tests stay green, and flip the rows green.
- [x] 3.3 Write failing `S/db/ingest_config_test.dart` cases `plugin_output_activates` and `plugin_secret_reference_rebound`, and `S/db/plugin_startup_secrets_test.dart` cases `restart_with_pending_unauthenticated_plugin_work`, `mixed_live_work_missing_plugin_secret` and `missing_webhook_key_fails_startup`; verify they fail.
- [x] 3.4 Add schema step `0003_plugin_outputs.sql` (D8: `output_kind`, `definition_digest`, relaxed webhook columns with the check, index) with its fresh- and populated-database step tests in `S/db/schema_step_test.dart`; publish plugin secret commitments, validate rebinding across kinds, and restrict `validateLiveSecrets` to webhook rows (D18); verify the 3.3 tests and the schema step tests pass and flip the rows green.

## 4. Production plugin host

Owner-approved sequencing exception (2026-11-12): for groups 4 and 5, real API implementation may
precede the first behavioral test run because no callable baseline exists. No placeholders are allowed;
every specified scenario still requires verification. Do not claim a pre-implementation behavioral red
for these groups. Thereafter, failures follow red/fix/green.

Configure diagnostics amendment (2026-11-12, approved by owner): tasks 4.1–4.4, 6.4 and 7.1–7.2 also
cover D1's typed, validated plugin error class and bounded configuration information. The existing
accepted and rejected configuration scenarios include diagnostic bounds, validation precedence,
exclusivity, secret scrubbing and separate host/plugin classification. Task 4.4 records ADR 0026 and
the architecture update; 6.4 mirrors the scrubbed plugin class separately in status. Regenerate both
languages and rerun design review before implementing this amendment.

- [x] 4.1 Write `S/plugin/plugin_protocol_test.dart` cases for every plugin-output-protocol scenario (11 rows), driven by Go fixture plugins added under `correlia_server/test/plugin/fixtures/go/`; verify each scenario's assertions run against the real API, with no placeholder or skipped case, under the 2026-11-12 sequencing exception.
- [x] 4.2 Extract the protocol-neutral launch core shared by the spike and production clients (D2), and add the libcrypto bindings that mint the ephemeral P-521 host identity in memory (D3), with a plugin-tier test of the certificate's group, SAN, validity and key match plus a repeated-minting allocation check; verify the spike tests in `S/plugin/` still pass.
- [x] 4.3 Implement the `correlia.plugin.v1` client: metadata validation, Configure with separated secrets, credit-bounded batches, per-event outcomes and health calls; verify the 4.1 tests pass and flip their rows green.
- [x] 4.4 Write accepted ADR `docs/adr/0026-plugin-configure-diagnostics.md`, superseding only ADR 0025 D1's Configure response without editing that immutable ADR, and update the architecture protocol boundary and in-force index for diagnostic fields, bounds, exclusivity, secret scrubbing and separate host/plugin classification; verify by `mise run spec:validate` and read-back against D1.

## 5. Relay: ready digests, permits, deadline and batch completion

- [x] 5.1 Write `S/db/plugin_relay_test.dart` cases `plugin_degraded_while_work_queued`, `plugin_becomes_ready_again`, `older_unavailable_beside_ready`, `instance_leaves_ready_before_permit`, `plugin_exit_observed_during_open_claim` (barrier inside the claim transaction after the permit is granted), `batch_with_one_bad_event`, `full_batch_within_budget`, `stale_batch_completion` and `plugin_intents_need_no_signing_reference`, plus `loaded_historical_signing_reference` in `S/db/output_relay_test.dart`; verify each scenario's assertions run against the real API, with no placeholder or skipped case, under the 2026-11-12 sequencing exception.
- [x] 5.2 Implement `claim(outputId, limit, readyDigests)`, the generation-checked delivery permit checked last before COMMIT (D5), the 27 s batch deadline with per-statement remaining-time timeouts, and `completeBatch` in one transaction fenced by `claim_id`, status and `lease_until > clock_timestamp()` with an exact row count (D4); keep webhook claims at limit 1; verify the 5.1 tests pass, existing `S/db/output_relay_test.dart` cases (including `unloaded_live_signing_reference`) stay green, and flip the rows green.

## 6. Supervisor

Owner-approved extension (2026-11-12): the API-first sequencing exception also covers 6.1, 6.2 and
the new admission API in 6.3. No pre-implementation behavioral red was observed for those APIs.
The durable-health test retains its observed missing-table red. All scenario assertions remain required.

- [x] 6.1 Write `S/unit/plugin/supervision_policy_test.dart` cases `repeated_startup_failure_grows_delay` and `degraded_plugin_recovers` on an injected clock; implement the pure-Dart state machine with the D6 constants under the owner-approved API-first exception; verify both scenarios' real assertions pass without skips or placeholders and flip the rows green.
- [x] 6.2 Write `S/unit/plugin/slot_scheduler_test.dart` cases for the six in-memory Fair instance slots scenarios; implement admission by key cursor, waiting demand per blocking scope, idle release, rotation and probe protection (D7) over an injected clock and in-memory demand under the owner-approved API-first exception; verify every scenario's real assertions pass without skips or placeholders and flip the rows green.
- [x] 6.3 Write `S/db/plugin_admission_test.dart` case `pinned_generations_beyond_one_page` (real post-pin barrier, activate B before A's work creates rows) under the API-first exception, and red-confirm `S/db/plugin_health_test.dart` case `failing_definitions_cycle_through_slots`; add managed health/status models, forward migrations, admission and waiting-demand keyset queries, and pruning (D11, D19); verify both scenarios pass and flip the rows green.
- [x] 6.4 Write failing `S/plugin/plugin_supervision_test.dart` cases `pinned_executable_launches`, `replaced_or_unsafe_executable`, `status_of_a_ready_plugin`, `plugin_ignores_shutdown`, `pinned_definition_cannot_run` and `plugin_dies_with_batch_unanswered`; wire the supervisor to verified launches, health checks, status rows with heartbeat, `plugin_degraded`/`plugin_recovered` activity entries and the relay's ready set, inside `IngestWorkers` in the D16 order; verify they pass, a test proves the console alert list ignores plugin activity entries, and flip the rows green.

## 7. output-nats plugin

- [x] 7.1 Write failing `S/plugin/nats_output_test.dart` cases for the integration-nats scenarios mapped there (11 rows) against a test-owned `natsdev` server; verify they fail on the plugin skeleton.
- [x] 7.2 Implement subjects, exact body and headers, `PublishMsgAsync` with `WithMsgID` and `WithExpectStream` under the 10 s deadline, per-event error mapping, stream lookup without creation, and credentials from Configure secrets only (D14); add Go unit tests for subject token validation in `plugins/output-nats/`; verify the 7.1 tests and `go test` through mise pass, and flip the rows green.
- [x] 7.3 Write `docs/runbooks/output-nats.md`: stream setup with `natsdev stream` or an operator-owned stream, the duplicate window against the lease, the tested NATS version, and secret forms; verify every command in it runs against a test-owned server.

## 8. Exit-criteria proofs

- [x] 8.1 Add the test-mode completion barrier (D17, compiled in only for run mode `test`), then write `S/e2e/nats_burst_e2e_test.dart` cases `Kill -9 during a 1,000-alert burst` (barrier hold, SQL check for a live delivering claim, SIGKILL, replacement worker, full reconciliation), `worker_killed_before_any_delivery`, `worker_killed_status_goes_stale` and `nats_plugin_exits_after_host_sigkill`; verify they pass and flip the rows green.
- [x] 8.2 [evidence] Capture the burst run's reconciliation counts and the plugin pid's stdin-exit marker (the NATS plugin's ADR 0020 criterion 4) → evidence/burst-kill9.txt
- [x] 8.3 Write `S/e2e/nats_dur3_e2e_test.dart`, `S/e2e/nats_dur8_e2e_test.dart`, `S/e2e/nats_pinning_e2e_test.dart`, `S/e2e/nats_shutdown_e2e_test.dart` and `S/plugin/nats_relay_deadline_test.dart` for their mapped rows (DUR-3, DUR-8, pinned NATS server change, graceful stop, batch over its deadline); verify they pass and flip the rows green.
- [x] 8.4 Add a test named `ORD-5e future-dated observation is quarantined` beside the existing future-dated coverage in `S/db/alert_state_test.dart`; verify it passes under that name.
- [x] 8.5 Add a demo-path e2e test (Alertmanager fixture body → feed endpoint shows the alert → `natsdev sub` receives it) and document the owner's demo steps (`mise run nats:dev`, `nats:stream`, `run`, `nats:sub`) in the runbook; verify the test passes.
- [x] 8.6 [evidence] Run `mise run check` and `mise run test:all` on a clean clone and capture the summaries, including the plugin build and the NATS-backed tests → evidence/check-gate.txt

## Workflow follow-up

- The owner's real-Alertmanager criterion is judged at M1 close, not in this change (proposal S4).
- After apply: pre-ship review, archive, local merge (`finish: local`).
