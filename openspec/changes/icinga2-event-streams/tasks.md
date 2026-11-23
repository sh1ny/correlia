# Tasks

## Test map

Paths are relative to the repository root. Tiers follow AGENTS.md: `test/unit` is fast; `test/db` uses the `db`
tag; `test/e2e` uses the `e2e` tag and real `bin/main.dart` children; `test/load` is the manual `load` tier,
never in the default loop. Every new `withServerpod` call names its tier tag.

Scenarios that only a real Icinga 2 can produce map to named tests in `icinga2_stream_versions_test.dart`.
Each of those tests re-evaluates the committed capture evidence (stream lines, sync responses, Icinga 2 log
excerpts and the consumer's run record) that `tool/icinga2_capture.sh` records for each listed release
(group 2). A row turns green only when its capture is committed and its test passes.

Rows marked `green` are unchanged scenarios inside MODIFIED requirements whose existing test already passes;
their group re-runs that test. Every other row starts `red` and turns green when its group's test passes.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| alert-state → State converges in any processing order | ORD-3 equal source times are ordered deterministically | `correlia_server/test/db/alert_state_test.dart` | `ord_3_equal_source_times_ordered_deterministically` (existing; re-run) | green |
| alert-state → State converges in any processing order | ORD-7a two observations in both orders | `correlia_server/test/db/alert_state_test.dart` | `ord_7a_two_observations_in_both_orders` (existing; re-run) | green |
| alert-state → State converges in any processing order | ORD-7b late and new observations in any schedule | `correlia_server/test/db/alert_state_test.dart` | `ord_7b_late_and_new_observations_in_any_schedule` (existing; re-run) | green |
| alert-state → State converges in any processing order | Duplicate deliveries carry one observation | `correlia_server/test/db/alert_state_test.dart` | `duplicate_deliveries_carry_one_observation` (existing; re-run) | green |
| alert-state → State converges in any processing order | Same observation key from two sources | `correlia_server/test/db/alert_state_test.dart` | `same_observation_key_from_two_sources` (existing; re-run) | green |
| alert-state → State converges in any processing order | Late duplicate of a ready observation | `correlia_server/test/db/alert_state_test.dart` | `late_duplicate_of_a_ready_observation` (existing; re-run) | green |
| alert-state → State converges in any processing order | ORD-7c duplicate of a late observation | `correlia_server/test/db/alert_state_test.dart` | `ord_7c_duplicate_of_a_late_observation` (existing; re-run) | green |
| alert-state → Single writer for alert state | Effect counts per raw row | `correlia_server/test/db/alert_state_test.dart` | `effect_counts_per_raw_row` (existing; re-run) | green |
| alert-state → Single writer for alert state | Opposite fingerprint order in concurrent deliveries | `correlia_server/test/db/alert_state_test.dart` | `opposite_fingerprint_order_in_concurrent_deliveries` (existing; re-run) | green |
| alert-state → Single writer for alert state | Informational observation | `correlia_server/test/unit/state/transition_test.dart` | `informational_observation` (existing; re-run) | green |
| alert-state → Single writer for alert state | Silent reconcile write | `correlia_server/test/db/icinga2_stream_state_test.dart` | `silent_reconcile_write` | red |
| alert-state → Resolved alert fences late evidence after its events expire | ORD-6 late firing after resolution and expiry | `correlia_server/test/db/alert_state_test.dart` | `ord_6_late_firing_after_resolution_and_expiry` (existing; re-run) | green |
| alert-state → Resolved alert fences late evidence after its events expire | Late firing for a fingerprint with no alert | `correlia_server/test/db/alert_state_test.dart` | `late_firing_for_a_fingerprint_with_no_alert` (existing; re-run) | green |
| alert-state → Resolved alert fences late evidence after its events expire | Late stream item after resolution | `correlia_server/test/db/icinga2_stream_state_test.dart` | `late_stream_item_after_resolution` | red |
| alert-state → Applied observations update state in place | ID-7c severity changes in place | `correlia_server/test/db/alert_state_test.dart` | `id_7c_severity_changes_in_place` (existing; re-run) | green |
| alert-state → Applied observations update state in place | ID-7b severity-labelled alerts are separate | `correlia_server/test/db/alert_state_test.dart` | `id_7b_severity_labelled_alerts_are_separate` (existing; re-run) | green |
| alert-state → Applied observations update state in place | Newer repeat with no visible change | `correlia_server/test/unit/state/transition_test.dart` | `newer_repeat_with_no_visible_change` (existing; re-run) | green |
| alert-state → Duplicate deliveries carry one observation | Late stream copy after the prompt copy | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `late_stream_copy_after_the_prompt_copy` | red |
| alert-state → Duplicate deliveries carry one observation | Late stream copy is not a first delivery | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `late_stream_copy_is_not_a_first_delivery` | red |
| alert-state → Reconcile observations confirm or repair | Sync agrees with the alert | `correlia_server/test/unit/state/icinga2_reconcile_test.dart` | `sync_agrees_with_the_alert` | red |
| alert-state → Reconcile observations confirm or repair | Sync repairs a missed recovery | `correlia_server/test/unit/state/icinga2_reconcile_test.dart` | `sync_repairs_a_missed_recovery` | red |
| alert-state → Reconcile observations confirm or repair | Recovered object with no alert | `correlia_server/test/unit/state/icinga2_reconcile_test.dart` | `recovered_object_with_no_alert` | red |
| alert-state → Reconcile observations confirm or repair | Older problem after a silent tombstone | `correlia_server/test/db/icinga2_stream_state_test.dart` | `older_problem_after_a_silent_tombstone` | red |
| alert-state → Reconcile observations confirm or repair | Stale reconcile observation that disagrees | `correlia_server/test/unit/state/icinga2_reconcile_test.dart` | `stale_reconcile_observation_that_disagrees` | red |
| alert-state → Reconcile observations confirm or repair | Late reconcile observation | `correlia_server/test/unit/state/icinga2_reconcile_test.dart` | `late_reconcile_observation` | red |
| alert-state → Silent confirms keep no key | Stale stream copy beyond the skew | `correlia_server/test/db/icinga2_stream_state_test.dart` | `stale_stream_copy_beyond_the_skew` | red |
| alert-state → Silent confirms keep no key | Stream copy after a silent confirm | `correlia_server/test/db/icinga2_stream_state_test.dart` | `stream_copy_after_a_silent_confirm` | red |
| alert-state → Displayed source in a shared namespace | Webhook and sync in both orders | `correlia_server/test/db/icinga2_stream_state_test.dart` | `webhook_and_sync_in_both_orders` | red |
| alert-state → Tombstones are reclaimed after the lateness horizon | Objects deleted upstream | `correlia_server/test/db/icinga2_tombstone_test.dart` | `objects_deleted_upstream` | red |
| alert-state → Tombstones are reclaimed after the lateness horizon | Older problem after reclamation | `correlia_server/test/db/icinga2_tombstone_test.dart` | `older_problem_after_reclamation` | red |
| durable-pipeline → Atomic raw processing outcome | DUR-1 outbox failure rolls back event work | `correlia_server/test/db/pipeline_test.dart` | `dur_1_outbox_failure_rolls_back_event_work` (existing; re-run) | green |
| durable-pipeline → Atomic raw processing outcome | Invalid member after valid member | `correlia_server/test/db/pipeline_test.dart` | `invalid_member_after_valid_member` (existing; re-run) | green |
| durable-pipeline → Atomic raw processing outcome | Processing budget exhaustion | `correlia_server/test/db/pipeline_test.dart` | `processing_budget_exhaustion` (existing; re-run) | green |
| durable-pipeline → Atomic raw processing outcome | Sync row that stored nothing | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `sync_row_that_stored_nothing` | red |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5b rebatching and expired transport window | `correlia_server/test/db/pipeline_test.dart` | `ord_5b_rebatching_and_expired_transport_window` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5c retry of firing after a recovery | `correlia_server/test/db/alert_state_test.dart` | `ord_5c_retry_of_firing_after_recovery` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5d retry after the observation key expired | `correlia_server/test/db/alert_state_test.dart` | `ord_5d_retry_after_observation_key_expired` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5f generic retry without a native id | `correlia_server/test/db/alert_state_test.dart` | `ord_5f_retry_without_native_id` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | Duplicate of a late observation | `correlia_server/test/db/alert_state_test.dart` | `duplicate_of_late_observation` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | Future quarantine does not poison dedup | `correlia_server/test/db/pipeline_test.dart` | `future_quarantine_does_not_poison_dedup` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | Late observation evidence | `correlia_server/test/db/pipeline_test.dart` | `late_observation_evidence` (existing; re-run) | green |
| durable-pipeline → Durable observation deduplication and quarantine | Late or future stream item | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `late_or_future_stream_item` | red |
| durable-pipeline → Rows decode by their source's kind | Two kinds in one batch | `correlia_server/test/db/decoder_dispatch_test.dart` | `two_kinds_in_one_batch` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Existing rows after the upgrade | `correlia_server/test/db/decoder_dispatch_test.dart` | `existing_rows_after_the_upgrade` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Row pinned to a format version 1 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `row_pinned_to_a_format_version_1_snapshot` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Schema step 4 under lock contention | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_step_4_under_lock_contention` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Schema runner waits behind another starter | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_runner_waits_behind_another_starter` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Missing kind in a version 2 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `missing_kind_in_a_version_2_snapshot` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Offline upgrade with pending work | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `offline_upgrade_with_pending_work` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Body of another kind | `correlia_server/test/db/decoder_dispatch_test.dart` | `body_of_another_kind` (existing; re-run) | green |
| durable-pipeline → Rows decode by their source's kind | Stream row of a stream source | `correlia_server/test/db/decoder_dispatch_test.dart` | `stream_row_of_a_stream_source` | red |
| durable-pipeline → Rows decode by their source's kind | Unknown stream format | `correlia_server/test/db/decoder_dispatch_test.dart` | `unknown_stream_format` | red |
| durable-pipeline → Clamped source time is recorded | ORD-4 future source time beyond the skew limit | `correlia_server/test/db/pipeline_test.dart` | `ord_4_future_source_time_beyond_the_skew_limit` (existing; re-run) | green |
| durable-pipeline → Clamped source time is recorded | Events stored before the upgrade | `correlia_server/test/db/schema_step_test.dart` | `events_stored_before_the_upgrade` (existing; re-run) | green |
| durable-pipeline → Clamped source time is recorded | Sub-microsecond evidence | `correlia_server/test/db/schema_step_test.dart` | `sub_microsecond_evidence` (existing; re-run) | green |
| durable-pipeline → Clamped source time is recorded | Source time within the skew allowance | `correlia_server/test/db/pipeline_test.dart` | `source_time_within_the_skew_allowance` (existing; re-run) | green |
| durable-pipeline → Clamped source time is recorded | Clamped silent reconcile | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `clamped_silent_reconcile` | red |
| durable-pipeline → Processing errors retry within a budget | Deadlock retried | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `deadlock_retried` | red |
| durable-pipeline → Observation keys are reserved before alert locks | Stream and sync copies of one result at once | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `stream_and_sync_copies_of_one_result_at_once` | red |
| durable-pipeline → Observation keys are reserved before alert locks | Silent reconcile leaves no key | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `silent_reconcile_leaves_no_key` | red |
| durable-pipeline → Observation keys are reserved before alert locks | Stale sync item before an eligible stream copy | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `stale_sync_item_before_an_eligible_stream_copy` | red |
| durable-pipeline → Consumer admission into the raw inbox | Stream row processed | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `stream_row_processed` | red |
| durable-pipeline → Consumer admission into the raw inbox | Items received at different times | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `items_received_at_different_times` | red |
| durable-pipeline → Consumer admission into the raw inbox | Stream row under a snapshot without the source | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `stream_row_under_a_snapshot_without_the_source` | red |
| durable-pipeline → Reconcile observations are stored only when they change state | Hourly sync of a steady installation | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `hourly_sync_of_a_steady_installation` | red |
| durable-pipeline → Reconcile observations are stored only when they change state | Sync with one repair | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `sync_with_one_repair` | red |
| durable-pipeline → Raw row outcomes count stream results | Mixed sync row | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `mixed_sync_row` | red |
| durable-pipeline → Raw row outcomes count stream results | Webhook rows unchanged | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `webhook_rows_unchanged` | red |
| durable-pipeline → Stale stream observations are stored, not routed | Older stream problem after a tombstone | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `older_stream_problem_after_a_tombstone` | red |
| durable-pipeline → Stale stream observations are stored, not routed | Stale webhook observation | `correlia_server/test/db/icinga2_stream_pipeline_test.dart` | `stale_webhook_observation` | red |
| icinga2-event-streams → Stream source configuration | Valid stream source | `correlia_server/test/unit/ingest/icinga2_stream_config_test.dart` | `valid_stream_source` | red |
| icinga2-event-streams → Stream source configuration | Webhook-only field on a stream source | `correlia_server/test/unit/ingest/icinga2_stream_config_test.dart` | `webhook_only_field_on_a_stream_source` | red |
| icinga2-event-streams → Stream source configuration | URL with a path or plain http | `correlia_server/test/unit/ingest/icinga2_stream_config_test.dart` | `url_with_a_path_or_plain_http` | red |
| icinga2-event-streams → Stream source configuration | Sync interval out of range | `correlia_server/test/unit/ingest/icinga2_stream_config_test.dart` | `sync_interval_out_of_range` | red |
| icinga2-event-streams → Exclusive TLS trust for the Icinga 2 API | Server signed by the configured CA | `correlia_server/test/e2e/icinga2_stream_tls_e2e_test.dart` | `server_signed_by_the_configured_ca` | red |
| icinga2-event-streams → Exclusive TLS trust for the Icinga 2 API | Server signed by a public CA only | `correlia_server/test/e2e/icinga2_stream_tls_e2e_test.dart` | `server_signed_by_a_public_ca_only` | red |
| icinga2-event-streams → Exclusive TLS trust for the Icinga 2 API | Certificate for another host | `correlia_server/test/e2e/icinga2_stream_tls_e2e_test.dart` | `certificate_for_another_host` | red |
| icinga2-event-streams → Exclusive TLS trust for the Icinga 2 API | Redirect answer | `correlia_server/test/e2e/icinga2_stream_tls_e2e_test.dart` | `redirect_answer` | red |
| icinga2-event-streams → Exclusive TLS trust for the Icinga 2 API | Wrong password | `correlia_server/test/e2e/icinga2_stream_tls_e2e_test.dart` | `wrong_password` | red |
| icinga2-event-streams → Fixed state-bearing subscription | Subscription accepted | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `subscription_accepted` | red |
| icinga2-event-streams → Fixed state-bearing subscription | Headers never arrive | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `headers_never_arrive` | red |
| icinga2-event-streams → Fixed state-bearing subscription | Permission missing | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `permission_missing` | red |
| icinga2-event-streams → One durable writer per stream source | Two workers start | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `two_workers_start` | red |
| icinga2-event-streams → One durable writer per stream source | First start of a new source | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `first_start_of_a_new_source` | red |
| icinga2-event-streams → One durable writer per stream source | Expiry between the lease check and the commit | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `expiry_between_the_lease_check_and_the_commit` | red |
| icinga2-event-streams → One durable writer per stream source | Holder renews after expiry | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `holder_renews_after_expiry` | red |
| icinga2-event-streams → A holder closes its connection before its lease can expire | Holder frozen past expiry | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `holder_frozen_past_expiry` | red |
| icinga2-event-streams → A holder closes its connection before its lease can expire | Database lost before the first renewal | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `database_lost_before_the_first_renewal` | red |
| icinga2-event-streams → A holder closes its connection before its lease can expire | Renewal acknowledged after the deadline | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `renewal_acknowledged_after_the_deadline` | red |
| icinga2-event-streams → A holder closes its connection before its lease can expire | Database unreachable for the holder | `correlia_server/test/db/icinga2_stream_lease_test.dart` | `database_unreachable_for_the_holder` | red |
| icinga2-event-streams → Fenced consumer admission | Paused old holder after takeover | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `paused_old_holder_after_takeover` | red |
| icinga2-event-streams → Fenced consumer admission | Publication between the check and the commit | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `publication_between_the_check_and_the_commit` | red |
| icinga2-event-streams → Admission is idempotent by batch id | Lost acknowledgement of a stream batch | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `lost_acknowledgement_of_a_stream_batch` | red |
| icinga2-event-streams → Admission is idempotent by batch id | Lost acknowledgement of a sync batch | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `lost_acknowledgement_of_a_sync_batch` | red |
| icinga2-event-streams → Admission is idempotent by batch id | Lost acknowledgement of the batch that filled the cap | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `lost_acknowledgement_of_the_batch_that_filled_the_cap` | red |
| icinga2-event-streams → Admission is idempotent by batch id | Lost acknowledgement before a settings change | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `lost_acknowledgement_before_a_settings_change` | red |
| icinga2-event-streams → Admission is idempotent by batch id | Batch ids of a removed source | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `batch_ids_of_a_removed_source` | red |
| icinga2-event-streams → Failed consumer rows find their admission record | Sync row whose source was removed | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `sync_row_whose_source_was_removed` | red |
| icinga2-event-streams → Failed consumer rows find their admission record | Stream row refused before decoding | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `stream_row_refused_before_decoding` | red |
| icinga2-event-streams → Failed consumer rows find their admission record | Sync row exhausts its retries | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `sync_row_exhausts_its_retries` | red |
| icinga2-event-streams → Fenced status writes | Source removed while quiet | `correlia_server/test/db/icinga2_stream_status_test.dart` | `source_removed_while_quiet` | red |
| icinga2-event-streams → Fenced status writes | Rotation between batches | `correlia_server/test/db/icinga2_stream_status_test.dart` | `rotation_between_batches` | red |
| icinga2-event-streams → Consumers follow the active configuration | First stream source on a running worker | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `first_stream_source_on_a_running_worker` | red |
| icinga2-event-streams → Consumers follow the active configuration | Source disabled on a running worker | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `source_disabled_on_a_running_worker` | red |
| icinga2-event-streams → Configuration changes | Unrelated revision | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `unrelated_revision` | red |
| icinga2-event-streams → Configuration changes | Endpoint changed | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `endpoint_changed` | red |
| icinga2-event-streams → Lines are validated before batching | Bad line beside a valid recovery | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `bad_line_beside_a_valid_recovery` | red |
| icinga2-event-streams → Lines are stored as read | Malformed JSON and invalid UTF-8 | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `malformed_json_and_invalid_utf_8` | red |
| icinga2-event-streams → An echoed password is redacted before admission | Password echoed after a successful subscription | `correlia_server/test/e2e/icinga2_stream_secrets_e2e_test.dart` | `password_echoed_after_a_successful_subscription` | red |
| icinga2-event-streams → An echoed password is redacted before admission | Password echoed in a sync object | `correlia_server/test/e2e/icinga2_stream_secrets_e2e_test.dart` | `password_echoed_in_a_sync_object` | red |
| icinga2-event-streams → Failure paths name only known members | Unknown member whose name looks like a path | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `unknown_member_whose_name_looks_like_a_path` | red |
| icinga2-event-streams → Failure paths name only known members | Unknown nested member | `correlia_server/test/db/icinga2_stream_admission_test.dart` | `unknown_nested_member` | red |
| icinga2-event-streams → Oversize lines are skipped | Oversize line | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `oversize_line` | red |
| icinga2-event-streams → Bounded batches | Burst of events | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `burst_of_events` | red |
| icinga2-event-streams → Bounded batches | Large valid line | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `large_valid_line` | red |
| icinga2-event-streams → Bounded batches | Single slow event | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `single_slow_event` | red |
| icinga2-event-streams → Batches fit the pipeline's fanout limit | Fanout cut before the encoded cut | `correlia_server/test/unit/ingest/icinga2_stream_batcher_test.dart` | `fanout_cut_before_the_encoded_cut` | red |
| icinga2-event-streams → Batches fit the pipeline's fanout limit | Worst-case fanout | `correlia_server/test/load/icinga2_stream_load_test.dart` | `worst_case_fanout` | red |
| icinga2-event-streams → Retained work is bounded | Pipeline briefly behind | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `pipeline_briefly_behind` | red |
| icinga2-event-streams → Retained work is bounded | Pipeline stopped | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `pipeline_stopped` | red |
| icinga2-event-streams → Retained work is bounded | Failures accumulate | `correlia_server/test/db/icinga2_stream_backpressure_test.dart` | `failures_accumulate` | red |
| icinga2-event-streams → Retained work is bounded | Quiet connection | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `quiet_connection` | red |
| icinga2-event-streams → Retained work is bounded | Insert blocked below the cap | `correlia_server/test/db/icinga2_stream_backpressure_test.dart` | `insert_blocked_below_the_cap` | red |
| icinga2-event-streams → Sync rows that changed nothing are removed | Steady installation | `correlia_server/test/db/icinga2_sync_storage_test.dart` | `steady_installation` | red |
| icinga2-event-streams → Sync rows that changed nothing are removed | Kept rows follow stored events | `correlia_server/test/db/icinga2_sync_storage_test.dart` | `kept_rows_follow_stored_events` | red |
| icinga2-event-streams → Sustained read lag closes the connection | Repeated short pauses | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `repeated_short_pauses` | red |
| icinga2-event-streams → Sustained read lag closes the connection | Initial backlog with constant excess lag | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `initial_backlog_with_constant_excess_lag` | red |
| icinga2-event-streams → Sustained read lag closes the connection | Initial backlog with growing excess lag | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `initial_backlog_with_growing_excess_lag` | red |
| icinga2-event-streams → Sustained read lag closes the connection | Constant clock offset | `correlia_server/test/unit/ingest/icinga2_stream_backpressure_test.dart` | `constant_clock_offset` | red |
| icinga2-event-streams → Icinga 2's own queue is not bounded by Correlia | Residual risk documented | `correlia_server/test/unit/ingest/icinga2_stream_docs_test.dart` | `residual_risk_documented` | red |
| icinga2-event-streams → State sync on connect and periodically | Recovery missed while disconnected | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `recovery_missed_while_disconnected` | red |
| icinga2-event-streams → State sync on connect and periodically | Recovery missed nine days ago, checked since | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `recovery_missed_nine_days_ago_checked_since` | red |
| icinga2-event-streams → State sync on connect and periodically | Passive service not reported for nine days | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `passive_service_not_reported_for_nine_days` | red |
| icinga2-event-streams → State sync on connect and periodically | Sync on a large installation | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `sync_on_a_large_installation` | red |
| icinga2-event-streams → State sync on connect and periodically | Object without a check result | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `object_without_a_check_result` | red |
| icinga2-event-streams → State sync on connect and periodically | Sync request fails | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `sync_request_fails` | red |
| icinga2-event-streams → Sync objects share the stream's identity | Same service through stream and sync | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` | `same_service_through_stream_and_sync` | red |
| icinga2-event-streams → A bad sync object does not hide the objects after it | Persistent bad object before a missed recovery | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `persistent_bad_object_before_a_missed_recovery` | red |
| icinga2-event-streams → A bad sync object does not hide the objects after it | Bad object fixed in Icinga 2 | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `bad_object_fixed_in_icinga_2` | red |
| icinga2-event-streams → A bad sync object does not hide the objects after it | Per-object error in a 2.16 response | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `per_object_error_in_a_2_16_response` | red |
| icinga2-event-streams → Bad-object diagnostics are bounded and safe | Unreadable name | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `unreadable_name` | red |
| icinga2-event-streams → Bad-object diagnostics are bounded and safe | Every object bad | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `every_object_bad` | red |
| icinga2-event-streams → Broken sync framing ends the reading | Truncated response after a valid prefix | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `truncated_response_after_a_valid_prefix` | red |
| icinga2-event-streams → Broken sync framing ends the reading | Unterminated string | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `unterminated_string` | red |
| icinga2-event-streams → Broken sync framing ends the reading | Syncs that never finish | `correlia_server/test/unit/ingest/icinga2_sync_reader_test.dart` | `syncs_that_never_finish` | red |
| icinga2-event-streams → Sync completion means applied | All rows applied | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `all_rows_applied` | red |
| icinga2-event-streams → Sync completion means applied | Last row done before reading ends | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `last_row_done_before_reading_ends` | red |
| icinga2-event-streams → Sync completion means applied | Sync with no object | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `sync_with_no_object` | red |
| icinga2-event-streams → Sync completion means applied | Failed row while reading | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `failed_row_while_reading` | red |
| icinga2-event-streams → Sync completion means applied | Still applying | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `still_applying` | red |
| icinga2-event-streams → Sync completion means applied | Application blocked on a reachable database | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `application_blocked_on_a_reachable_database` | red |
| icinga2-event-streams → Sync completion means applied | Takeover during a sync | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `takeover_during_a_sync` | red |
| icinga2-event-streams → An interrupted sync is closed before the next one | Reconnect during a sync, same generation | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `reconnect_during_a_sync_same_generation` | red |
| icinga2-event-streams → An interrupted sync is closed before the next one | Close not recorded before the reconnect | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `close_not_recorded_before_the_reconnect` | red |
| icinga2-event-streams → An interrupted sync is closed before the next one | Takeover after a row failed during reading | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `takeover_after_a_row_failed_during_reading` | red |
| icinga2-event-streams → Syncs of a retired source are closed | Source removed during a database outage | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `source_removed_during_a_database_outage` | red |
| icinga2-event-streams → Syncs of a retired source are closed | Disabled source's progress pruned | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `disabled_source_s_progress_pruned` | red |
| icinga2-event-streams → Syncs of a retired source are closed | Source re-added after a long absence | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `source_re_added_after_a_long_absence` | red |
| icinga2-event-streams → Syncs of a retired source are closed | Source re-enabled during the retirement sweep | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `source_re_enabled_during_the_retirement_sweep` | red |
| icinga2-event-streams → Sync counts survive late rows | Rows removed before the outcome is read | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `rows_removed_before_the_outcome_is_read` | red |
| icinga2-event-streams → Sync counts survive late rows | Row done after a takeover | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `row_done_after_a_takeover` | red |
| icinga2-event-streams → Sync counts survive late rows | Row pending past 30 days | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `row_pending_past_30_days` | red |
| icinga2-event-streams → One sync at a time | Request during a sync | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `request_during_a_sync` | red |
| icinga2-event-streams → One sync at a time | Request and start at the same moment | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `request_and_start_at_the_same_moment` | red |
| icinga2-event-streams → One sync at a time | Request while paused | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `request_while_paused` | red |
| icinga2-event-streams → Syncs are spaced | Connection flapping | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `connection_flapping` | red |
| icinga2-event-streams → Syncs are spaced | Takeover inside the spacing window | `correlia_server/test/db/icinga2_sync_progress_test.dart` | `takeover_inside_the_spacing_window` | red |
| icinga2-event-streams → Stream and sync observation evidence | Sync of an already streamed change | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `sync_of_an_already_streamed_change` | red |
| icinga2-event-streams → Stream and sync observation evidence | Regressing execution end | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `regressing_execution_end` | red |
| icinga2-event-streams → Stream and sync observation evidence | Three observations in every order | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `three_observations_in_every_order` | red |
| icinga2-event-streams → Stream and sync observation evidence | Recovery by sync before an older stream problem, on an empty database | `correlia_server/test/db/icinga2_stream_state_test.dart` | `recovery_by_sync_before_an_older_stream_problem_on_an_empty_database` | red |
| icinga2-event-streams → Key time text and ordering time | Key times | `correlia_server/test/unit/ingest/icinga2_stream_keys_test.dart` | `key_times` | red |
| icinga2-event-streams → Key time text and ordering time | Invalid time | `correlia_server/test/unit/ingest/icinga2_stream_keys_test.dart` | `invalid_time` | red |
| icinga2-event-streams → Ordering holds within the clock and lateness limits | Icinga 2 clock ahead beyond the skew | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `icinga_2_clock_ahead_beyond_the_skew` | red |
| icinga2-event-streams → Ordering holds within the clock and lateness limits | Later SOFT result under hard_only | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `later_soft_result_under_hard_only` | red |
| icinga2-event-streams → Ordering holds within the clock and lateness limits | Another source writes the same alert | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `another_source_writes_the_same_alert` | red |
| icinga2-event-streams → Starts within one microsecond are equal starts | Equal start times | `correlia_server/test/db/icinga2_stream_state_test.dart` | `equal_start_times` | red |
| icinga2-event-streams → Starts within one microsecond are equal starts | Sync copy among equal starts | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `sync_copy_among_equal_starts` | red |
| icinga2-event-streams → Every disagreeing sync item counts diverged | Keyed sync copy of the losing result | `correlia_server/test/db/icinga2_stream_state_test.dart` | `keyed_sync_copy_of_the_losing_result` | red |
| icinga2-event-streams → Host state from the check result | Host raw WARNING | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `host_raw_warning` | red |
| icinga2-event-streams → Host state from the check result | Unreachable host | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `unreachable_host` | red |
| icinga2-event-streams → Host state from the check result | Unknown raw state | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `unknown_raw_state` | red |
| icinga2-event-streams → Soft and hard state policy | Missed recovery superseded by a SOFT result | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `missed_recovery_superseded_by_a_soft_result` | red |
| icinga2-event-streams → Soft and hard state policy | Soft problem under hard_only | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `soft_problem_under_hard_only` | red |
| icinga2-event-streams → Soft and hard state policy | Soft problem under soft_and_hard | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `soft_problem_under_soft_and_hard` | red |
| icinga2-event-streams → Soft and hard state policy | Policy changed between admission and claim | `correlia_server/test/db/icinga2_stream_state_test.dart` | `policy_changed_between_admission_and_claim` | red |
| icinga2-event-streams → Soft and hard state policy | Copies of one result under two policies | `correlia_server/test/db/icinga2_stream_state_test.dart` | `copies_of_one_result_under_two_policies` | red |
| icinga2-event-streams → Late and future stream items are counted, not stored | Late copy processed before the prompt copy | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `late_copy_processed_before_the_prompt_copy` | red |
| icinga2-event-streams → Late and future stream items are counted, not stored | Prompt copy processed first | `correlia_server/test/unit/state/icinga2_stream_ordering_test.dart` | `prompt_copy_processed_first` | red |
| icinga2-event-streams → Acknowledgement, downtime and flapping from the stream | Acknowledgement set | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `acknowledgement_set` | red |
| icinga2-event-streams → Acknowledgement, downtime and flapping from the stream | Two acknowledgements by different authors at one instant | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `two_acknowledgements_by_different_authors_at_one_instant` | red |
| icinga2-event-streams → Unsupported event types fail | Event type not subscribed | `correlia_server/test/unit/ingest/icinga2_stream_decoder_test.dart` | `event_type_not_subscribed` | red |
| icinga2-event-streams → Reconnect with backoff | Icinga 2 restarts | `correlia_server/test/unit/ingest/icinga2_stream_backoff_test.dart` | `icinga_2_restarts` | red |
| icinga2-event-streams → Reconnect with backoff | Icinga 2 down for an hour | `correlia_server/test/unit/ingest/icinga2_stream_backoff_test.dart` | `icinga_2_down_for_an_hour` | red |
| icinga2-event-streams → Consumer status | Status read locally | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `status_read_locally` | red |
| icinga2-event-streams → Consumer status | Holder died with no replacement | `correlia_server/test/db/icinga2_stream_status_test.dart` | `holder_died_with_no_replacement` | red |
| icinga2-event-streams → Consumer status | Status method in production | `correlia_server/test/e2e/icinga2_stream_consumer_e2e_test.dart` | `status_method_in_production` | red |
| icinga2-event-streams → Gaps counted once per connection | Gap recorded by the next holder | `correlia_server/test/db/icinga2_stream_status_test.dart` | `gap_recorded_by_the_next_holder` | red |
| icinga2-event-streams → Gaps counted once per connection | Gap already recorded | `correlia_server/test/db/icinga2_stream_status_test.dart` | `gap_already_recorded` | red |
| icinga2-event-streams → Gaps counted once per connection | Death between recording a connection and subscribing | `correlia_server/test/db/icinga2_stream_status_test.dart` | `death_between_recording_a_connection_and_subscribing` | red |
| icinga2-event-streams → Gaps counted once per connection | Late retry of an older gap | `correlia_server/test/db/icinga2_stream_status_test.dart` | `late_retry_of_an_older_gap` | red |
| icinga2-event-streams → Gaps counted once per connection | Status write during a database outage | `correlia_server/test/db/icinga2_stream_status_test.dart` | `status_write_during_a_database_outage` | red |
| icinga2-event-streams → Gaps counted once per connection | Two oversize lines on one connection | `correlia_server/test/db/icinga2_stream_status_test.dart` | `two_oversize_lines_on_one_connection` | red |
| icinga2-event-streams → A failed stream row requests a sync | Stream row exhausts its retries | `correlia_server/test/db/icinga2_stream_resync_test.dart` | `stream_row_exhausts_its_retries` | red |
| icinga2-event-streams → A failed stream row requests a sync | Failure before any status exists | `correlia_server/test/db/icinga2_stream_resync_test.dart` | `failure_before_any_status_exists` | red |
| icinga2-event-streams → A failed stream row requests a sync | Sync row fails | `correlia_server/test/db/icinga2_stream_resync_test.dart` | `sync_row_fails` | red |
| icinga2-event-streams → A failed stream row requests a sync | No failure | `correlia_server/test/db/icinga2_stream_resync_test.dart` | `no_failure` | red |
| icinga2-event-streams → Consumer database sessions end their own work | Stop during a stalled insert | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `stop_during_a_stalled_insert` | red |
| icinga2-event-streams → Consumer database sessions end their own work | Stop during a running statement | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `stop_during_a_running_statement` | red |
| icinga2-event-streams → Consumer database sessions end their own work | Insert finishing as stop begins | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `insert_finishing_as_stop_begins` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Many sources | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `many_sources` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Stop while reading | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `stop_while_reading` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Lease row still locked at stop | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `lease_row_still_locked_at_stop` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Two workers, 64 sources | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `two_workers_64_sources` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Session settings of the dedicated connection | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `session_settings_of_the_dedicated_connection` | red |
| icinga2-event-streams → Consumer stops within the shutdown deadline | Database unreachable at stop | `correlia_server/test/db/icinga2_stream_stop_test.dart` | `database_unreachable_at_stop` | red |
| icinga2-event-streams → Supported Icinga 2 releases for Event Streams | Version matrix | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` | `version_matrix` | red |
| icinga2-event-streams → Supported Icinga 2 releases for Event Streams | Listed release that fails | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` | `listed_release_that_fails` | red |
| icinga2-event-streams → Supported Icinga 2 releases for Event Streams | Release whose capture fails | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` | `release_whose_capture_fails` | red |
| icinga2-event-streams → Supported Icinga 2 releases for Event Streams | Real consumer against a release | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` (capture by `tool/icinga2_capture.sh`) | `real_consumer_against_a_release` | red |
| icinga2-event-streams → Supported Icinga 2 releases for Event Streams | Missing permission in the documented list | `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` (capture by `tool/icinga2_capture.sh`) | `missing_permission_in_the_documented_list` | red |
| icinga2-event-streams → Event Streams setup documentation | Setup items present | `correlia_server/test/unit/ingest/icinga2_stream_docs_test.dart` | `setup_items_present` | red |
| icinga2-event-streams → Event Streams limits documentation | Limits match the code | `correlia_server/test/unit/ingest/icinga2_stream_docs_test.dart` | `limits_match_the_code` | red |
| integration-icinga2 → Icinga2 webhook document | Service problem notification | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `service_problem_notification` (existing; re-run) | green |
| integration-icinga2 → Icinga2 webhook document | Wrong type on a known field | `correlia_server/test/db/icinga2_ingest_test.dart` | `wrong_type_on_a_known_field` (existing; re-run) | green |
| integration-icinga2 → Icinga2 webhook document | Unknown field name is not reflected | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `unknown_field_name_is_not_reflected` (existing; re-run) | green |
| integration-icinga2 → Icinga2 webhook document | Dotted unknown field name | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `dotted_unknown_field_name` (existing; re-run) | green |
| integration-icinga2 → Icinga2 webhook document | Unsupported format version | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `unsupported_format_version` (existing; re-run) | green |
| integration-icinga2 → Icinga2 webhook document | Delivery to a stream source | `correlia_server/test/db/icinga2_ingress_test.dart` | `delivery_to_a_stream_source` | red |
| process-roles → Event Streams consumers run in background roles | api role | `correlia_server/test/e2e/roles_e2e_test.dart` | `api_role` | red |
| process-roles → Event Streams consumers run in background roles | Shutdown order | `correlia_server/test/db/shutdown_order_test.dart` | `shutdown_order` | red |
| process-roles → Event Streams consumers run in background roles | Shutdown with the lease row locked | `correlia_server/test/db/shutdown_order_test.dart` | `shutdown_with_the_lease_row_locked` | red |
| process-roles → Event Streams consumers run in background roles | Shutdown with the database unreachable | `correlia_server/test/db/shutdown_order_test.dart` | `shutdown_with_the_database_unreachable` | red |
| secret-store → Secret bytes never leave their consumer | SEC-3 plugin config secret | `correlia_server/test/e2e/secret_store_e2e_test.dart` | `sec_3_plugin_config_secret` (existing; re-run) | green |
| secret-store → Secret bytes never leave their consumer | Decryption failure stays sanitized | `correlia_server/test/db/secret_store_test.dart` | `decryption_failure_stays_sanitized` (existing; re-run) | green |
| secret-store → Secret bytes never leave their consumer | Stream password and CA | `correlia_server/test/e2e/icinga2_stream_secrets_e2e_test.dart` | `stream_password_and_ca` | red |
| secret-store → Icinga 2 API passwords and CA bundles | Password imported | `correlia_server/test/db/secret_reuse_test.dart` | `password_imported` | red |
| secret-store → Icinga 2 API passwords and CA bundles | CA bundle too large | `correlia_server/test/db/secret_reuse_test.dart` | `ca_bundle_too_large` | red |
| secret-store → Passwords never share bytes with a bare commitment | Password equals a signing key | `correlia_server/test/db/secret_reuse_test.dart` | `password_equals_a_signing_key` | red |
| secret-store → Passwords never share bytes with a bare commitment | Credential added after the password | `correlia_server/test/db/secret_reuse_test.dart` | `credential_added_after_the_password` | red |
| secret-store → Passwords never share bytes with a bare commitment | Credential added after the password was rotated away | `correlia_server/test/db/secret_reuse_test.dart` | `credential_added_after_the_password_was_rotated_away` | red |
| secret-store → Passwords never share bytes with a bare commitment | Same bytes in one publication | `correlia_server/test/db/secret_reuse_test.dart` | `same_bytes_in_one_publication` | red |
| secret-store → Passwords never share bytes with a bare commitment | Different bytes | `correlia_server/test/db/secret_reuse_test.dart` | `different_bytes` | red |
| secret-store → Reuse digests are kept for every published secret | Reuse digest holds no bare digest | `correlia_server/test/db/secret_reuse_test.dart` | `reuse_digest_holds_no_bare_digest` | red |
| secret-store → Reuse digests are kept for every published secret | Removed password still checked | `correlia_server/test/db/secret_reuse_test.dart` | `removed_password_still_checked` | red |
| secret-store → Reuse digests are kept for every published secret | Upgrade with removed secrets | `correlia_server/test/db/secret_reuse_test.dart` | `upgrade_with_removed_secrets` | red |
| secret-store → The reuse inventory is complete before the first password | Password published during the backfill | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `password_published_during_the_backfill` | red |
| secret-store → The reuse inventory is complete before the first password | Backfill interrupted | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `backfill_interrupted` | red |
| secret-store → The reuse inventory is complete before the first password | Interrupted between passes | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `interrupted_between_passes` | red |
| secret-store → The reuse inventory is complete before the first password | Outbox pins are covered by snapshots | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `outbox_pins_are_covered_by_snapshots` | red |
| secret-store → The reuse inventory is complete before the first password | Large history | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `large_history` | red |
| secret-store → The reuse inventory is complete before the first password | Format version 1 token digest | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `format_version_1_token_digest` | red |
| secret-store → The reuse inventory is complete before the first password | Bare plugin commitment only in a pinned snapshot | `correlia_server/test/db/secret_reuse_backfill_test.dart` | `bare_plugin_commitment_only_in_a_pinned_snapshot` | red |
| secret-store → Only this release or newer publishes after the upgrade | Publication in flight at the cutover | `correlia_server/test/db/publisher_version_test.dart` | `publication_in_flight_at_the_cutover` | red |
| secret-store → Only this release or newer publishes after the upgrade | Older process publishes after the upgrade | `correlia_server/test/db/publisher_version_test.dart` | `older_process_publishes_after_the_upgrade` | red |
| secret-store → Only this release or newer publishes after the upgrade | Rollback after a password was published | `correlia_server/test/db/publisher_version_test.dart` | `rollback_after_a_password_was_published` | red |
| source-ingress → Source configuration format | Version 1 file still starts | `correlia_server/test/e2e/secret_store_e2e_test.dart` | `version_1_file_still_starts` (existing; re-run) | green |
| source-ingress → Source configuration format | Unsupported kind or field | `correlia_server/test/unit/ingest/source_config_test.dart` | `unsupported_kind_or_field` (existing; re-run) | green |
| source-ingress → Source configuration format | Supported kinds | `correlia_server/test/db/icinga2_ingress_test.dart` | `supported_kinds` (existing; re-run) | green |
| source-ingress → Source configuration format | Webhook mode by default | `correlia_server/test/unit/ingest/source_config_test.dart` | `webhook_mode_by_default` | red |
| source-ingress → Source configuration format | Existing snapshot republished after the upgrade | `correlia_server/test/unit/ingest/source_config_test.dart` | `existing_snapshot_republished_after_the_upgrade` | red |
| source-ingress → Source configuration format | Mode on another kind or unknown mode | `correlia_server/test/unit/ingest/source_config_test.dart` | `mode_on_another_kind_or_unknown_mode` | red |
| source-ingress → Credential rotation with overlap | Overlapping rotation | `correlia_server/test/db/ingress_credentials_test.dart` | `overlapping_rotation` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Expired and not yet valid credentials | `correlia_server/test/db/ingress_credentials_test.dart` | `expired_and_not_yet_valid_credentials` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Rotation during a body read | `correlia_server/test/db/ingress_credentials_test.dart` | `rotation_during_a_body_read` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Activation without a usable credential | `correlia_server/test/unit/ingest/source_config_test.dart` | `activation_without_a_usable_credential` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Stream source holds no credentials | `correlia_server/test/db/ingress_credentials_test.dart` | `stream_source_holds_no_credentials` | red |
| source-ingress → Per source request rate | Burst within budget | `correlia_server/test/unit/ingest/rate_limiter_test.dart` | `burst_within_budget` (existing; re-run) | green |
| source-ingress → Per source request rate | Budget exceeded | `correlia_server/test/db/ingress_credentials_test.dart` | `budget_exceeded` (existing; re-run) | green |
| source-ingress → Per source request rate | Unauthenticated traffic spends no budget | `correlia_server/test/db/ingress_credentials_test.dart` | `unauthenticated_traffic_spends_no_budget` (existing; re-run) | green |
| source-ingress → Per source request rate | Stream source has no request budget | `correlia_server/test/db/ingress_test.dart` | `stream_source_has_no_request_budget` | red |
| source-ingress → A source's mode never changes | Mode change refused | `correlia_server/test/db/ingest_config_test.dart` | `mode_change_refused` | red |
| source-ingress → A source's mode never changes | New source for the stream | `correlia_server/test/db/ingest_config_test.dart` | `new_source_for_the_stream` | red |
| source-ingress → Stream sources refuse webhook deliveries | Delivery to a stream source | `correlia_server/test/db/icinga2_ingress_test.dart` | `delivery_to_a_stream_source` | red |
| source-ingress → Stream sources refuse webhook deliveries | Webhook source unaffected | `correlia_server/test/db/icinga2_ingress_test.dart` | `webhook_source_unaffected` | red |

## 1. ADR 0030 and roadmap correction

- [ ] 1.1 Write `docs/adr/0030-pull-sources-leased-consumers.md` ("Pull sources: leased consumers, fenced admission and reconcile observations", `Status: accepted`) from design D2, D4, D5, D7, D13, D18–D32, listing its exceptions to ADRs 0016, 0017, 0024 and 0029 as the design's ADRs section states. It carries **C2** (fenced admission, pause rather than drop, batch id instead of a transport key) and **C14** (kept stream rows grow until change 7's watermark; empty sync rows are deleted). Add it to the in-force index in `openspec/architecture.md`. Verify: the file names C2 and C14's facts, `mise run check` passes the doc lints, and the index lists 0030.
- [ ] 1.2 Correct `openspec/roadmap.md:42`: the consumer subscribes to `StateChange`, acknowledgement, downtime and flapping events, and `CheckResult` is deliberately not consumed (S2, D16). Verify: the line no longer lists `CheckResult` as consumed and names the S2 decision.

## 2. Captures from real releases and the version matrix

- [ ] 2.1 Verify A1: extend `tool/icinga2_capture.sh` with a stream scenario (an ApiUser with the documented permissions, a subscription to the fixed types, a `/v1/objects/{hosts,services}` sync), run it against the official images of each listed release (2.13 to 2.16), and read the captured lines and responses against design Context (unbounded inbox, `vars_after` contents, start-based rejection, framing, attribute errors, short service `name`). A release whose capture disagrees is removed from the supported list; with no qualifying release, stop under the drift rule. Verify: the per-release fixtures exist under `correlia_server/test/unit/ingest/fixtures/icinga2/<release>/stream/` and the findings are in the run record.
- [ ] 2.2 Verify A2: in the same captures, compare the parsed `execution_start` doubles of the stream line and the sync object of one check result. Verify: a capture check in `icinga2_stream_versions_test.dart` (`stream_and_sync_copies_parse_to_equal_doubles`) passes for each listed release; a disagreement is design drift for D1/D17.
- [ ] 2.3 Write failing tests in `correlia_server/test/unit/ingest/icinga2_stream_versions_test.dart` for the rows mapped to it (supported releases, permission list, real consumer run, stream and sync identity), reading the committed captures; they fail until 2.4 and group 11 commit the real consumer run. Verify: they fail for the missing run record, not a parse error.
- [ ] 2.4 Commit the captured fixtures and the capture script's stream scenario; document the scenario in `tool/README.md`. Verify: `mise run test` reaches the versions test with real fixtures; rows still waiting on the consumer run stay red until 11.4.

## 3. Source mode and stream configuration

- [ ] 3.1 Write failing tests for the rows mapped to `source_config_test.dart`, `icinga2_stream_config_test.dart`, `ingest_config_test.dart`, `ingress_credentials_test.dart` (stream source holds no credentials), `ingress_test.dart` (no request budget) and `icinga2_ingress_test.dart` (stream sources refuse webhook deliveries, delivery to a stream source). Verify: each fails on the missing `mode` handling.
- [ ] 3.2 Implement `mode` (`webhook` default, `event_streams`) with the stream fields (`url`, `password_ref`, `ca_ref`, `state_policy`, `sync_interval_seconds`), immutable mode across disable and re-enable, the 401 webhook refusal, and no credentials or request budget for stream sources. Verify: the 3.1 tests pass; flip their rows green.
- [ ] 3.3 Write **C7** ("a source keeps the mode it was first published with, also across disable and re-enable") into the requirement "A source's mode never changes" of `openspec/specs/source-ingress/spec.md` as it merges at archive; until then confirm the delta carries it. Verify: the requirement text holds the sentence.
- [ ] 3.4 Re-run the green rows of `source-ingress` and `integration-icinga2` (`version_1_file_still_starts`, `unsupported_kind_or_field`, `supported_kinds`, the credential and rate rows, and the webhook rows in `icinga2_mapper_test.dart`, `icinga2_webhook_test.dart`, `icinga2_ingest_test.dart`). Verify: all pass unchanged.

## 4. Schema step, secret records and password reuse

- [ ] 4.1 Write failing tests for the rows mapped to `secret_reuse_test.dart`, `secret_reuse_backfill_test.dart` and `publisher_version_test.dart`, including the 10,000-snapshot history, interruption between passes and the in-flight publication at the cutover. Verify: they fail for the missing tables, trigger and passes.
- [ ] 4.2 Add the schema step: the reuse inventory, `secret_reuse_backfill` (three marks and one `complete` flag), the publisher-version trigger and the backfill boundaries, installed in one transaction that takes `pg_advisory_xact_lock(1129271884)` after the schema lock `1129271885` (D26). Write **C26** as the doc comment of that step in `correlia_server/lib/src/schema/schema_steps.dart`. Verify: `publisher_version_test.dart` passes; the doc comment states C26.
- [ ] 4.3 Implement password and CA records (keyed commitments, size limits), the reuse check in both directions, and the bounded backfill passes (snapshots by revision, commitment rows, credential rows by serial id, batches of 500, outside the publication lock) in `correlia_server/lib/src/secrets/reuse_backfill.dart`; refuse password publication with `reuse_inventory_pending` until every pass completes. Write **C29** as the doc comment in `reuse_backfill.dart`. Verify: `secret_reuse_test.dart` and `secret_reuse_backfill_test.dart` pass; flip their rows green.
- [ ] 4.4 Write **C9** into "Passwords never share bytes with a bare commitment" and **C21** into "Only this release or newer publishes after the upgrade" (`specs/secret-store/spec.md`). Verify: both requirement texts hold the facts.
- [ ] 4.5 Re-run the green secret-store rows (`sec_3_plugin_config_secret`, `decryption_failure_stays_sanitized`). Verify: both pass.

## 5. Keys, decoder and stream event mapping

- [ ] 5.1 Write failing tests for the rows mapped to `icinga2_stream_keys_test.dart` and `icinga2_stream_decoder_test.dart` (key time text including `4294967296.000001` and integral times, host state from `vars_after` and `reachable`, soft/hard policy, acknowledgement, downtime and flapping, unsupported event types), over the group 2 fixtures. Verify: they fail on the missing decoder.
- [ ] 5.2 Implement `correlia_server/lib/src/ingest/icinga2/stream/keys.dart` and the stream decoder for format `correlia.icinga2.stream.v1`, dispatched by the pinned source's kind and format. Write **C11** as the doc comment of `keys.dart`. Verify: the 5.1 tests and the `decoder_dispatch_test.dart` rows "Stream row of a stream source" and "Unknown stream format" pass; flip their rows green.
- [ ] 5.3 Write **C1** into "Stream and sync observation evidence" and **C12** into "Soft and hard state policy" (`specs/icinga2-event-streams/spec.md`). Verify: both requirement texts hold the facts.
- [ ] 5.4 Re-run the green `decoder_dispatch_test.dart`, `icinga2_upgrade_e2e_test.dart` and `schema_step_test.dart` rows. Verify: all pass.

## 6. Alert state, reconcile and the durable pipeline

- [ ] 6.1 Write failing fast tests for the rows mapped to `icinga2_stream_ordering_test.dart` and `icinga2_reconcile_test.dart` (ordering permutations, equal starts, duplicate deliveries, late and future items, confirm, repair and silent tombstone). Verify: they fail on the missing reconcile path.
- [ ] 6.2 Implement reconcile observations in the alert-state machine: silent confirm with no key and unchanged display fields, published repair, silent tombstone, `diverged` for every disagreeing sync item except `soft_info`. Verify: the 6.1 tests pass; flip their rows green.
- [ ] 6.3 Write failing db tests for the rows mapped to `icinga2_stream_state_test.dart`, `icinga2_stream_pipeline_test.dart` and `icinga2_tombstone_test.dart` (key reserved before the alert lock and removed when no event is stored, stale stream observation stored but not routed, eventless sync rows deleted, raw row outcome counts, clamped silent reconcile, stale copy beyond the skew in both orders, displayed source in both orders, tombstone reclamation in batches of 500). Verify: they fail for the missing behaviour.
- [ ] 6.4 Implement the pipeline side: reservation before alert locks, deletion of every reconcile reservation that stores no event, stored-not-routed stale stream observations, deletion of sync rows that stored nothing, and tombstone reclamation after the lateness horizon. Verify: the 6.3 tests pass; flip their rows green.
- [ ] 6.5 Write **C3** into "Reconcile observations confirm or repair", **C33** into "Silent confirms keep no key", **C34** into "Displayed source in a shared namespace", **C36** into "Tombstones are reclaimed after the lateness horizon" (`specs/alert-state/spec.md`); **C17** and **C30** into "Observation keys are reserved before alert locks", **C25** into "Stale stream observations are stored, not routed" (`specs/durable-pipeline/spec.md`); **C13** into "Late and future stream items are counted, not stored" (`specs/icinga2-event-streams/spec.md`). Verify: each requirement text holds its fact.
- [ ] 6.6 Re-run the green `alert_state_test.dart`, `transition_test.dart`, `pipeline_test.dart` and `identity_test.dart` rows. Verify: all pass unchanged.

## 7. Lease, fenced admission and status writes

- [ ] 7.1 Verify A4: read the PostgreSQL server version of the embedded cluster from a `db` test (`SHOW server_version`) and record it in the run notes. If it is 17 or newer, note that `transaction_timeout` can be added as a second bound (D13). Verify: the version is recorded before 7.3 relies on statement timeouts.
- [ ] 7.2 Write failing tests for the rows mapped to `icinga2_stream_lease_test.dart`, `icinga2_stream_admission_test.dart` and `icinga2_stream_status_test.dart` (lease create, acquire, renew, expiry versus commit, late acknowledgement, frozen holder; fenced admission; batch-id retries for stream and sync batches, a full cap and a settings change; admission records on early refusal and retry exhaustion; lines stored as read; failure paths; fenced status; gap sequence; `stale` after a dead holder). Add a test for a retained count beside another source's 100,000-row backlog that checks the plan uses the partial index. Verify: they fail for the missing tables and paths.
- [ ] 7.3 Implement the lease row with generation, acquisition that locks the source first, the local deadline from the acknowledged send time, `icinga2_admitted_batch`, `icinga2_raw_origin`, fenced admission and fenced status writes. Verify: the 7.2 tests pass; flip their rows green.
- [ ] 7.4 Write **C15** into "A holder closes its connection before its lease can expire", **C27** into "Failed consumer rows find their admission record" and **C28** into "Admission is idempotent by batch id" (`specs/icinga2-event-streams/spec.md`). Verify: each requirement text holds its fact.

## 8. Stream reader, batching, redaction and backpressure

- [ ] 8.1 Write failing tests for the rows mapped to `icinga2_stream_batcher_test.dart`, `icinga2_stream_backpressure_test.dart` (fast and db) and `icinga2_stream_backoff_test.dart` (line validation, oversize lines, encoded and ×9 fanout bounds with the encoded limit raised so the fanout cut is reached, retained-work cap, reader-blocked stall, quiet connection, lag with an initial backlog of constant and of growing excess, jittered backoff). Verify: they fail on the missing reader.
- [ ] 8.2 Implement `stream_reader.dart`, the batcher and the backpressure rules; redact an echoed password (bytes, base64, base64url) to `[redacted:password]` before any parse, batch, sample or log. Write **C16** as the doc comment of `StreamReader` and **C4** as the doc comment of `streamTypes` in `subscription.dart`. Verify: the 8.1 tests pass; flip their rows green; both doc comments state their facts.
- [ ] 8.3 Write **C35** into "An echoed password is redacted before admission" (`specs/icinga2-event-streams/spec.md`). Verify: the requirement text holds it.

## 9. Sync reader and sync progress

- [ ] 9.1 Write failing tests for the rows mapped to `icinga2_sync_reader_test.dart`, `icinga2_sync_progress_test.dart` and `icinga2_sync_storage_test.dart` (incremental parse, bad objects isolated and counted with safe identifiers, 20 log entries plus one summary, broken framing, completion means applied, interrupted close by `readEndAt IS NULL`, retired-source sweep with a concurrent re-enable, re-add after 40 days, late-row counts, one sync at a time, spacing across a takeover). Verify: they fail on the missing sync path.
- [ ] 9.2 Implement `sync_reader.dart` and the sync progress record with guarded finalization. Write **C6** as the doc comment of `SyncReader`. Verify: the 9.1 tests pass; flip their rows green; the doc comment states C6.
- [ ] 9.3 Write **C18** into "A bad sync object does not hide the objects after it", **C19** into "A failed stream row requests a sync", **C23** into "An interrupted sync is closed before the next one" and **C24** into "Sync counts survive late rows" (`specs/icinga2-event-streams/spec.md`). Verify: each requirement text holds its fact.

## 10. HTTPS client, supervisor, stop and roles

- [ ] 10.1 Verify A3: write a spike test that sets TCP keepalive options through `HttpClient.connectionFactory` and `RawSocketOption` on the pinned SDK, and read the socket option back. If it fails, the client opens the `SecureSocket` itself and writes the request (D8). Verify: the outcome is recorded before 10.2.
- [ ] 10.2 Write failing tests for the rows mapped to `icinga2_stream_tls_e2e_test.dart` (public-CA certificate, wrong host, redirect, hostile `SSL_CERT_FILE` and `https_proxy`), `icinga2_stream_resync_test.dart`, `icinga2_stream_stop_test.dart` and `shutdown_order_test.dart` (lease row free, database unreachable, lease row locked). Verify: they fail on the missing client and supervisor.
- [ ] 10.3 Implement the HTTPS client with exclusive CA trust, no proxy and no redirect; the supervisor (acquisition, retired-source sweep, batch-id expiry after 1 h, pruning that never touches lease, status or resync rows); resync requests; the 10 s local stop with the dedicated connection closed by 4 s and a release recorded only when it commits. Write **C31** as the doc comment of the pruning in `supervisor.dart`. Verify: the 10.2 tests pass with lock release measured from an independent connection; flip their rows green.
- [ ] 10.4 Write **C8** into "Exclusive TLS trust for the Icinga 2 API" and **C20** into "Gaps counted once per connection" (`specs/icinga2-event-streams/spec.md`), and **C32** into "Event Streams consumers run in background roles" (`specs/process-roles/spec.md`). Verify: each requirement text holds its fact.

## 11. Consumer end to end, secrets and documentation

- [ ] 11.1 Write failing tests for the rows mapped to `icinga2_stream_consumer_e2e_test.dart`, `icinga2_stream_secrets_e2e_test.dart`, `roles_e2e_test.dart` (api role) and `icinga2_stream_docs_test.dart`. Verify: they fail on the missing wiring and docs.
- [ ] 11.2 Wire the consumer into the background roles and the status endpoint, with configuration adoption every 30 s. Verify: the consumer and secrets e2e tests pass with console and persistent logging enabled and no password or CA bytes in any response, row or log; flip their rows green.
- [ ] 11.3 Write the Event Streams setup and limits sections in `docs/ingest-pipeline.md` (all roles upgraded before the first stream password, no older release; permissions; residual queue risk; gap losses) and an ApiUser example in `contrib/icinga2/`. Write **C10** into the Event Streams setup section, and **C5** and **C22** into the requirement "Event Streams limits documentation" (`specs/icinga2-event-streams/spec.md`). Verify: `icinga2_stream_docs_test.dart` passes against the constants; flip its rows green.
- [ ] 11.4 [evidence] Run `tool/icinga2_capture.sh` with the built consumer against each listed release and commit the run record with the fixtures → evidence/icinga2-stream-capture-run.md. Verify: the versions test's real-consumer and permission rows pass; flip them green.

## 12. Load and integration

- [ ] 12.1 [evidence] Run the manual load tier (`mise run test -- --tags load`): D6's worst-case batch within the row deadline, and a 10-minute run at full input with the drain rate measured over its last 5 minutes → evidence/icinga2-stream-load.md. Verify: the worst-case batch finishes within the row deadline and the measured drain rate is recorded in the docs' limits section.
- [ ] 12.2 Run `mise run test:all` and `mise run check`. Verify: both pass and every test-map row reads `green`.

## Workflow follow-up

- The owner's day-long real Icinga 2 feed is judged at the M2 close (proposal), with the setup from 11.3.
- Pre-ship review, PR and archive follow `specwright-commit`, `specwright-pr` and `specwright-finish`.
