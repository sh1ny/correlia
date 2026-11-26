# Tasks

## Test map

Test paths are relative to `correlia_server/`. Green rows carry existing behavior and must be rerun. Red rows require a failing test before the implementation. Use independent DB connections, barriers and injected time; elapsed time is only a hang guard.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| dead-letter-operations → Dedicated operator authorization | Configured machine can operate | `test/e2e/dead_letter_operations_e2e_test.dart` | `operator_success_redacts_and_attributes` | red |
| dead-letter-operations → Dedicated operator authorization | Missing or wrong scope | `test/e2e/dead_letter_operations_e2e_test.dart` | `operator_denies_disabled_wrong_scope_and_worker` | red |
| dead-letter-operations → Dedicated operator authorization | Invalid credential file is not echoed | `test/e2e/dead_letter_operations_e2e_test.dart` | `bad_operator_file_fails_startup_without_echo` | red |
| dead-letter-operations → Bounded dead-letter listing | DUR-4 a failed output is visible to an operator | `test/e2e/dead_letter_recovery_e2e_test.dart` | `dur_4_dead_delivery_is_visible_and_replays` | red |
| dead-letter-operations → Bounded dead-letter listing | Equal failure times and invalid filters | `test/db/dead_letter_operations_test.dart` | `equal_times_and_invalid_filter_cursor` | red |
| dead-letter-operations → Bounded dead-letter listing | Filter remains pageable among unrelated failures | `test/db/dead_letter_operations_test.dart` | `sparse_filter_pages_use_matching_index` | red |
| dead-letter-operations → Bounded replay selection and audit | Bulk replay by filter | `test/db/dead_letter_operations_test.dart` | `filtered_replay_batches_report_and_audit` | red |
| dead-letter-operations → Bounded replay selection and audit | Replay races replay or expiry | `test/db/dead_letter_operations_test.dart` | `replay_and_expiry_lock_one_occurrence` | red |
| dead-letter-operations → Bounded replay selection and audit | Replay competes for the last pending slot | `test/db/raw_replay_test.dart` | `replay_and_ingress_share_last_slot` | red |
| dead-letter-operations → Current configuration for pipeline replay | DUR-13 a fixed mapping reaches its backlog | `test/db/raw_replay_test.dart` | `dur_13_mapping_fix_repins_at_replay` | red |
| dead-letter-operations → Current configuration for pipeline replay | Replaying a row from a finished or absent sync run | `test/db/raw_replay_test.dart` | `reconcile_replay_preserves_finished_and_pruned_runs` | red |
| dead-letter-operations → Current configuration for pipeline replay | Replay source missing or disabled | `test/db/raw_replay_test.dart` | `missing_and_disabled_sources_keep_failure_occurrence` | red |
| dead-letter-operations → Current configuration for pipeline replay | Restoring the same source makes the original occurrence replayable | `test/db/raw_replay_test.dart` | `restored_source_replays_with_admission_origin_policy` | red |
| dead-letter-operations → Current configuration for pipeline replay | Earlier error cannot spend replay allowance | `test/db/raw_replay_test.dart` | `stale_same_pin_error_cannot_cross_replay_epoch` | red |
| dead-letter-operations → Immutable delivery replay | DUR-4 delivery replay succeeds after recovery | `test/e2e/dead_letter_recovery_e2e_test.dart` | `dur_4_dead_delivery_is_visible_and_replays` | red |
| dead-letter-operations → Immutable delivery replay | Unavailable key or output lane | `test/db/delivery_replay_test.dart` | `delivery_replay_refuses_missing_key_or_new_lane` | red |
| dead-letter-operations → Immutable delivery replay | New retry allowance survives completion and recovery | `test/db/delivery_replay_test.dart` | `fresh_attempt_allowance_fences_completion_and_recovery` | red |
| dead-letter-operations → Protected operational status | Pressure and recovery visible to the demo | `test/e2e/dead_letter_recovery_e2e_test.dart` | `operator_status_tracks_pressure_and_recovery` | red |
| dead-letter-operations → Protected operational status | Maintenance fails after a previous success | `test/db/pipeline_retention_test.dart` | `failed_batch_reports_no_uncommitted_counts` | red |
| durable-pipeline → Rows decode by their source's kind | Two kinds in one batch | `test/db/decoder_dispatch_test.dart` | `two_kinds_in_one_batch` | green |
| durable-pipeline → Rows decode by their source's kind | Existing rows after the upgrade | `test/db/decoder_dispatch_test.dart` | `existing_rows_after_the_upgrade` | green |
| durable-pipeline → Rows decode by their source's kind | Row pinned to a format version 1 snapshot | `test/db/decoder_dispatch_test.dart` | `row_pinned_to_a_format_version_1_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Schema step 4 under lock contention | `test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_step_4_under_lock_contention` | green |
| durable-pipeline → Rows decode by their source's kind | Schema runner waits behind another starter | `test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_runner_waits_behind_another_starter` | green |
| durable-pipeline → Rows decode by their source's kind | Missing kind in a version 2 snapshot | `test/db/decoder_dispatch_test.dart` | `missing_kind_in_a_version_2_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Offline upgrade with pending work | `test/e2e/icinga2_upgrade_e2e_test.dart` | `offline_upgrade_with_pending_work` | green |
| durable-pipeline → Rows decode by their source's kind | Body of another kind | `test/db/decoder_dispatch_test.dart` | `body_of_another_kind` | green |
| durable-pipeline → Rows decode by their source's kind | Stream row of a stream source | `test/db/decoder_dispatch_test.dart` | `stream_row_of_a_stream_source` | green |
| durable-pipeline → Rows decode by their source's kind | Unknown stream format | `test/db/decoder_dispatch_test.dart` | `unknown_stream_format` | green |
| durable-pipeline → Rows decode by their source's kind | Generic mapping changes before the first claim | `test/db/decoder_dispatch_test.dart` | `generic_mapping_changes_before_the_first_claim` | green |
| durable-pipeline → Rows decode by their source's kind | Generic mapping changes after the first claim | `test/db/decoder_dispatch_test.dart` | `generic_mapping_changes_after_the_first_claim` | green |
| durable-pipeline → Rows decode by their source's kind | Generic row pinned to a snapshot without its mapping | `test/db/decoder_dispatch_test.dart` | `generic_row_pinned_to_a_snapshot_without_its_mapping` | green |
| durable-pipeline → Partitioned storage survives offline upgrade | Populated upgrade and fresh installation | `test/db/pipeline_partition_upgrade_test.dart` | `partition_cutover_fresh_and_populated` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | Parent-targeted writes retain index and cutoff behavior | `test/db/pipeline_partition_upgrade_test.dart` | `parent_indexes_helper_and_cross_child_cutoff` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | Overflow event lands inside the attached historical range | `test/db/output_pressure_test.dart` | `upgraded_historical_event_child_accepts_and_routes_notice` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | Partition work interrupted | `test/db/pipeline_partition_upgrade_test.dart` | `partition_cutover_rollback_and_retry` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | Default validation failure pauses only daily preparation | `test/db/pipeline_partition_maintenance_test.dart` | `default_validation_timeout_records_retry_without_blocking_writes` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | A delayed attachment failure cannot replace success | `test/db/pipeline_partition_maintenance_test.dart` | `late_attach_failure_cannot_replace_success` | red |
| durable-pipeline → Partitioned storage survives offline upgrade | Worker stops during maintenance | `test/e2e/pipeline_maintenance_e2e_test.dart` | `role_and_shutdown_wait_for_open_maintenance_batch` | red |
| durable-pipeline → Retention preserves unfinished pipeline work | DUR-10 a long worker outage | `test/db/pipeline_retention_test.dart` | `dur_10_retention_keeps_unfinished_work` | red |
| durable-pipeline → Retention preserves unfinished pipeline work | Old event with an unfinished delivery | `test/db/pipeline_retention_test.dart` | `unfinished_outbox_keys_protect_old_events` | red |
| durable-pipeline → Retention preserves unfinished pipeline work | Old fully eligible partition | `test/db/pipeline_retention_test.dart` | `eligible_closed_partition_drops` | red |
| durable-pipeline → Retention preserves unfinished pipeline work | Reclamation advances past protected pages | `test/db/pipeline_retention_test.dart` | `bounded_page_advances_past_protected_prefix` | red |
| durable-pipeline → Atomic dead-letter expiry | DUR-12 expiration makes old work eligible | `test/db/pipeline_retention_test.dart` | `dur_12_expiry_discards_and_ledgers_atomically` | red |
| durable-pipeline → Atomic dead-letter expiry | Expiry rollback | `test/db/pipeline_retention_test.dart` | `failed_batch_reports_no_uncommitted_counts` | red |
| durable-pipeline → Retention preserves retry and ordering evidence | Evidence still needed by old accepted work | `test/db/pipeline_retention_test.dart` | `replayable_work_protects_ordering_evidence` | red |
| durable-pipeline → Retention preserves retry and ordering evidence | Replayed pre-upgrade evidence predates reclaimed fences | `test/db/raw_replay_test.dart` | `preupgrade_icinga2_floor_keeps_older_evidence_late` | red |
| source-ingress → Shared inbox and storage pressure | DUR-9 inbox limits and recovery | `test/e2e/ingress_pressure_e2e_test.dart` | `dur_9_webhook_and_pull_pause_and_recover` | red |
| source-ingress → Shared inbox and storage pressure | Concurrent admission at the last slot | `test/db/ingress_pressure_test.dart` | `two_apis_and_pull_contend_for_last_slot` | red |
| source-ingress → Shared inbox and storage pressure | Sync admission contends with sync completion | `test/db/ingress_pressure_test.dart` | `sync_admission_orders_progress_before_count` | red |
| source-ingress → Shared inbox and storage pressure | Database pressure degrades readiness | `test/e2e/ingress_pressure_e2e_test.dart` | `oversize_database_pushes_back_and_degrades_readiness` | red |
| source-ingress → Pressure preserves known transport outcomes | Retry while capacity is exhausted | `test/db/ingress_pressure_test.dart` | `committed_webhook_and_pull_retries_beat_pressure` | red |
| source-ingress → Pressure preserves known transport outcomes | Conflicting key while capacity is exhausted | `test/db/ingress_pressure_test.dart` | `conflicting_live_key_beats_pressure` | red |
| source-ingress → Pressure preserves known transport outcomes | Expired key disappears during admission | `test/db/ingress_pressure_test.dart` | `expired_reservation_deleted_between_conflict_and_lock` | red |
| output-delivery → Immutable routed delivery intent | Fanout with configuration change | `test/db/pipeline_routing_test.dart` | `fanout_with_configuration_change` | green |
| output-delivery → Immutable routed delivery intent | Explicitly unrouted event | `test/db/pipeline_routing_test.dart` | `explicitly_unrouted_event` | green |
| output-delivery → No loss across worker death | Kill -9 during a 1,000-alert burst | `test/e2e/nats_burst_e2e_test.dart` | `Kill -9 during a 1,000-alert burst` | green |
| output-delivery → No loss across worker death | Worker killed before any delivery | `test/e2e/nats_burst_e2e_test.dart` | `worker_killed_before_any_delivery` | green |
| output-delivery → Historical secret lookup does not scan delivery payloads | Historical import and startup ignore backlog size | `test/db/pipeline_inventory_test.dart` | `historical_import_and_startup_use_distinct_metadata` | red |
| output-delivery → Historical secret lookup does not scan delivery payloads | Missing live signing material cannot be hidden | `test/db/pipeline_inventory_test.dart` | `layered_live_webhook_commitment_remains_visible_at_startup` | red |
| output-delivery → Per-output storage budget and default policy | DUR-11 discard policy isolates a failing output | `test/db/output_pressure_test.dart` | `dur_11_discard_preserves_other_fanout` | red |
| output-delivery → Per-output storage budget and default policy | Count or bytes bind across workers | `test/db/output_pressure_test.dart` | `parallel_workers_respect_both_caps` | red |
| output-delivery → Per-output storage budget and default policy | Completion and expired-lease recovery race | `test/db/output_pressure_test.dart` | `completion_and_recovery_order_one_capacity_delta` | red |
| output-delivery → Per-output storage budget and default policy | Lower limit does not purge existing work | `test/db/output_pressure_test.dart` | `lower_budget_leaves_old_work_intact` | red |
| output-delivery → Blocking-output policy protects accepted work | DUR-11 blocking policy preserves backlog | `test/db/output_pressure_test.dart` | `dur_11_block_defers_atomic_batch_without_spending_attempts` | red |
| output-delivery → Blocking-output policy protects accepted work | Blocking budget cannot fit a legal raw row | `test/db/pipeline_inventory_test.dart` | `undersized_blocking_budget_cannot_publish` | red |
| output-delivery → Output overflow notice does not recurse | Alert reaches a healthy output | `test/db/output_pressure_test.dart` | `notice_reaches_healthy_output_with_ledger_evidence` | red |
| output-delivery → Output overflow notice does not recurse | All other outputs are full | `test/db/output_pressure_test.dart` | `full_notice_destinations_do_not_enqueue_or_recurse` | red |
| output-delivery → Output overflow notice does not recurse | Notice uses a blocking output's last slot | `test/db/output_pressure_test.dart` | `notice_at_exact_cap_blocks_ingress_without_recurse` | red |
| output-delivery → Output overflow notice does not recurse | Notice selection races registry publication | `test/db/output_pressure_test.dart` | `notice_registry_race_keeps_live_lane_limit` | red |
| output-delivery → Output overflow notice does not recurse | Live lane lookup ignores backlog size | `test/db/pipeline_inventory_test.dart` | `lane_inventory_cost_does_not_follow_queue_depth` | red |
| output-delivery → Retention of terminal delivery evidence | Retention reclaims delivered intents and attempts | `test/db/pipeline_retention_test.dart` | `delivered_retention_reclaims_only_matching_attempts` | red |
| output-delivery → Retention of terminal delivery evidence | Old creation time with recent completion | `test/db/pipeline_retention_test.dart` | `new_terminal_time_overrides_old_creation_age` | red |
| output-delivery → Retention of terminal delivery evidence | A discarded intent has more attempts than one batch | `test/db/pipeline_retention_test.dart` | `retired_intent_attempts_reclaim_across_batches` | red |

## 1. Record the architecture and migrate durable storage

- [ ] 1.1 Record ADR 0034 or the next free number and update `openspec/architecture.md` in the same group. Carry C3, C5, C7–C11, C15 and C16. Check the new ADR against D1–D13 and run strict OpenSpec validation.
- [ ] 1.2 Verify A1 with embedded PostgreSQL on the immediately preceding SQL schema and on a fresh install. Write the partition cutover, catalog and interrupted-upgrade tests first and observe missing partition behavior. Assert composite keys and preserved bytes, trigger behavior across children and the effective-time function using the new row type.
- [ ] 1.3 Implement forward-only offline attachment and cutover metadata. Run `test/db/pipeline_partition_upgrade_test.dart`, `test/db/schema_step_test.dart` and the mapped cases in `test/e2e/icinga2_upgrade_e2e_test.dart`; update fixtures that name latest versions. Document the offline cutover and schema repair exclusions.

## 2. Publish capacity policy and account for shared writes

- [ ] 2.1 Write failing policy, inventory, historical commitment and webhook/pull contention cases first. Cover omitted and explicit-default snapshot hashes, rejection of undersized `block_ingest`, one committed slot, credential/lease precedence and the expired-receipt deletion interleaving. Check the actual pin-to-intent handoff with historical matching and mismatched imports on both sides of the commit. Count inspected metadata at 10× and 100× payload depth.
- [ ] 2.2 Implement validated `pipeline_operations` and transactional capacity, route and commitment counts. Migrate publication, worker startup, pin and completion writers to the same counts. Prove unchanged historical verification and pin-to-intent visibility with `test/db/pipeline_inventory_test.dart`. Document complete defaults and controlled config publication.
- [ ] 2.3 Verify A3 with the existing database-readiness e2e case once the new indicator is installed. Implement shared lag/storage checks in webhook and leased pull admission, disk readiness, and receipt preservation under pressure. Use barriers to assert progress-row-before-count ordering for success and failure. Run `test/db/ingress_pressure_test.dart`, `test/e2e/ingress_pressure_e2e_test.dart` and `test/e2e/health_e2e_test.dart`. Document 429/503, retry hints and sampled disk behavior.

## 3. Enforce output limits and publish overflow notices

- [ ] 3.1 Write the failing output pressure and relay tests, including both relay/recovery acquisition orders, partial fit by count and bytes, policy lowering, rollback on blocking deferral, exact saturation, nonrecursive fanout, disjoint-registry contention and real overflow delivery into a historical event child. Check event evidence against the emitted reference and byte hash.
- [ ] 3.2 Implement the budgeted output insert and finalization paths, capacity accounting and deferral, and the bounded maintenance claim for Correlia-origin notices. Run `test/db/output_pressure_test.dart` and `test/db/pipeline_routing_test.dart`. Document overflow defaults, notice delivery and the difference between deferring accepted work and dropping a new output intent by policy.

## 4. Expire and reclaim work without losing replay evidence

- [ ] 4.1 Write failing expiry, retention, default-partition and shutdown tests. Force D13's delayed failure after rollback, safe restart and eventual successful attach with unrelated default rows present. Exercise api, worker and all through the runtime registry. Check that a failing active batch rolls back and records its outcome before session close, with no second claim. Cover candidate bounds and many attempts without elapsed-time assertions.
- [ ] 4.2 Implement the role-owned maintenance loop, bounded batches, DDL retry fence, discard ledger, dedup key and tombstone protection, and staged attempt cleanup. Run `test/db/pipeline_retention_test.dart`, `test/db/pipeline_partition_maintenance_test.dart`, `test/db/icinga2_tombstone_test.dart` and `test/e2e/pipeline_maintenance_e2e_test.dart`. Record C4, C6, C12 and C17 at their spec destinations. Document status outcomes, protected records and offline daily-partition repair.

## 5. List and replay dead letters through the operator RPC

- [ ] 5.1 Verify A2 with the generated client over real HTTP and normal framework logging. Write failing tests for access off/wrong scope/worker, invalid credential files and successful-call redaction. Use distinct secret, payload, destination and reference sentinels. Write failing indexed list and replay tests, including stale occurrence, expiry, same-pin old errors, last-slot contention, pin-at-request and sync semantics. Use barriers for races and an injected clock for attempt allowance and expiry.
- [ ] 5.2 Implement the protected credential loader and typed RPC, indexed list and status reads, bounded raw and delivery replay and its audit. Carry C1, C2, C13 and C14 into the dead-letter spec. Run `test/db/dead_letter_operations_test.dart`, `test/db/raw_replay_test.dart`, `test/db/delivery_replay_test.dart` and `test/e2e/dead_letter_operations_e2e_test.dart`. Rerun all mapped cases in `test/db/decoder_dispatch_test.dart`, and regenerate Serverpod code rather than editing generated files. Document credentials, replay filter/continuation and Change 9's operator entry points, plus the deferred DUR-4 console check.

## 6. Verify the combined change

- [ ] 6.1 Write and run `test/e2e/dead_letter_recovery_e2e_test.dart` for the combined DUR-4 recovery and status flows. Exercise the normal delivery relay before and after replay, prove identical bytes and IDs, and show pressure clearing via the same authenticated API Change 9 will call.
- [ ] 6.2 Rerun the two mapped existing crash cases in `test/e2e/nats_burst_e2e_test.dart` and run strict OpenSpec validation. Before heavy local verification check the owner gaming guard and record any equivalent checks deferred to CI. Publish the ingest runbook changes and changelog updates from their owning task groups.

## Workflow follow-up

- Rebase before first push. Move this change's schema steps after every `origin/main` version, including Change 6 if it landed, and rerun affected migration cases.
- Pass pre-ship review, ship and watch the PR. Archive on its branch after checks and review settle. Verify final-head CI and review as required. Do not merge.
