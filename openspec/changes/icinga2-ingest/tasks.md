# Tasks

## Test map

Paths are relative to the repository root. Tiers follow AGENTS.md: `test/unit` is fast; `test/db` uses the `db`
tag; `test/e2e` uses the `e2e` tag and real `bin/main.dart` children. `correlia_icinga2_notify/test/` holds the
sender's own tests: `sender_test.dart` is fast and `binary_test.dart` runs the compiled executable (`e2e` tag).

Scenarios that only a real Icinga 2 can produce map to named tests in `icinga2_versions_test.dart`. Each of those
tests re-evaluates the committed capture evidence (requests, responses, Icinga 2 log excerpts and decoded
events, plus the raw outcome of each newly admitted request, committed alert state and event counts) that
`tool/icinga2_capture.sh` records for each listed release and architecture pair (group 9). A row
turns green only when its capture is committed and its test passes. The capture script is the mechanical check
that produces the evidence, and the test is what judges it.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| alert-state → State converges in any processing order | ORD-3 equal source times are ordered deterministically | `correlia_server/test/db/alert_state_test.dart` | `ord_3_equal_source_times_ordered_deterministically` (existing; re-run) | green |
| alert-state → State converges in any processing order | Source times less than a microsecond apart | `correlia_server/test/db/alert_state_test.dart` | `source_times_less_than_a_microsecond_apart` (existing; re-run) | green |
| alert-state → State converges in any processing order | ORD-7a two observations in both orders | `correlia_server/test/db/alert_state_test.dart` | `ord_7a_two_observations_in_both_orders` | green |
| alert-state → State converges in any processing order | ORD-7b late and new observations in any schedule | `correlia_server/test/db/alert_state_test.dart` | `ord_7b_late_and_new_observations_in_any_schedule` | green |
| alert-state → State converges in any processing order | Duplicate deliveries carry one observation | `correlia_server/test/db/alert_state_test.dart` | `duplicate_deliveries_carry_one_observation` | green |
| alert-state → State converges in any processing order | Same observation key from two sources | `correlia_server/test/db/alert_state_test.dart` | `same_observation_key_from_two_sources` | green |
| alert-state → State converges in any processing order | Late duplicate of a ready observation | `correlia_server/test/db/alert_state_test.dart` | `late_duplicate_of_a_ready_observation` | green |
| alert-state → State converges in any processing order | ORD-7c duplicate of a late observation | `correlia_server/test/db/alert_state_test.dart` | `ord_7c_duplicate_of_a_late_observation` | green |
| alert-state → Resolved alert fences late evidence after its events expire | ORD-6 late firing after resolution and expiry | `correlia_server/test/db/alert_state_test.dart` | `ord_6_late_firing_after_resolution_and_expiry` | green |
| alert-state → Resolved alert fences late evidence after its events expire | Late firing for a fingerprint with no alert | `correlia_server/test/db/alert_state_test.dart` | `late_firing_for_a_fingerprint_with_no_alert` | green |
| durable-pipeline → Rows decode by their source's kind | Two kinds in one batch | `correlia_server/test/db/decoder_dispatch_test.dart` | `two_kinds_in_one_batch` | green |
| durable-pipeline → Rows decode by their source's kind | Existing rows after the upgrade | `correlia_server/test/db/decoder_dispatch_test.dart` | `existing_rows_after_the_upgrade` | green |
| durable-pipeline → Rows decode by their source's kind | Row pinned to a format version 1 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `row_pinned_to_a_format_version_1_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Schema step 4 under lock contention | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_step_4_under_lock_contention` | green |
| durable-pipeline → Rows decode by their source's kind | Schema runner waits behind another starter | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_runner_waits_behind_another_starter` | green |
| durable-pipeline → Rows decode by their source's kind | Missing kind in a version 2 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `missing_kind_in_a_version_2_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Offline upgrade with pending work | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `offline_upgrade_with_pending_work` | green |
| durable-pipeline → Rows decode by their source's kind | Body of another kind | `correlia_server/test/db/decoder_dispatch_test.dart` | `body_of_another_kind` | green |
| durable-pipeline → Clamped source time is recorded | ORD-4 future source time beyond the skew limit | `correlia_server/test/db/pipeline_test.dart` | `ord_4_future_source_time_beyond_the_skew_limit` | green |
| durable-pipeline → Clamped source time is recorded | Events stored before the upgrade | `correlia_server/test/db/schema_step_test.dart` | `events_stored_before_the_upgrade` | green |
| durable-pipeline → Clamped source time is recorded | Sub-microsecond evidence | `correlia_server/test/db/schema_step_test.dart` | `sub_microsecond_evidence` | green |
| durable-pipeline → Clamped source time is recorded | Source time within the skew allowance | `correlia_server/test/db/pipeline_test.dart` | `source_time_within_the_skew_allowance` | green |
| integration-icinga2 → Icinga2 webhook document | Service problem notification | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `service_problem_notification` | green |
| integration-icinga2 → Icinga2 webhook document | Wrong type on a known field | `correlia_server/test/db/icinga2_ingest_test.dart` | `wrong_type_on_a_known_field` | green |
| integration-icinga2 → Icinga2 webhook document | Unknown field name is not reflected | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `unknown_field_name_is_not_reflected` | green |
| integration-icinga2 → Icinga2 webhook document | Dotted unknown field name | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `dotted_unknown_field_name` | green |
| integration-icinga2 → Icinga2 webhook document | Unsupported format version | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `unsupported_format_version` | green |
| integration-icinga2 → State change time is required only for state notifications | State notification without a state change time | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `state_notification_without_a_state_change_time` | green |
| integration-icinga2 → State change time is required only for state notifications | Non-state key without the state change time | `correlia_server/test/unit/ingest/icinga2_keys_test.dart` | `non_state_key_without_the_state_change_time` | green |
| integration-icinga2 → State change time is required only for state notifications | Non-state notification for an object with an unusable state change time | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `non_state_notification_for_an_object_with_an_unusable_state_change_time` | green |
| integration-icinga2 → State change time is required only for state notifications | Invalid state change time on a non-state delivery | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `invalid_state_change_time_on_a_non_state_delivery` | green |
| integration-icinga2 → State change time is required only for state notifications | Custom notification without a state change time | `correlia_server/test/db/icinga2_ingest_test.dart` | `custom_notification_without_a_state_change_time` | green |
| integration-icinga2 → Webhook text is storable | NUL in a host name | `correlia_server/test/db/icinga2_ingest_test.dart` | `nul_in_a_host_name` | green |
| integration-icinga2 → Webhook body nesting is bounded before parsing | Deeply nested body | `correlia_server/test/db/icinga2_ingest_test.dart` | `deeply_nested_body` | green |
| integration-icinga2 → Shipped notification command | Notification from a real Icinga 2 in both auth modes | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `notification_from_a_real_icinga_2_in_both_auth_modes` | green |
| integration-icinga2 → Shipped notification command | Rejected delivery | `correlia_server/test/e2e/icinga2_sender_e2e_test.dart` | `rejected_delivery` | green |
| integration-icinga2 → Shipped notification command | Long check output | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `long_check_output` | green |
| integration-icinga2 → Shipped notification command | Recovery output with dollar signs | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `recovery_output_with_dollar_signs` | green |
| integration-icinga2 → Shipped notification command | Oversized custom notification | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `oversized_custom_notification` | green |
| integration-icinga2 → Shipped notification command | Multibyte character across the cut | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `multibyte_character_across_the_cut` | green |
| integration-icinga2 → Shipped notification command | Invalid UTF-8 in check output | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `invalid_utf_8_in_check_output` | green |
| integration-icinga2 → Shipped notification command | Burst of verbose notifications | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `burst_of_verbose_notifications` | green |
| integration-icinga2 → Shipped notification command | Runtime options in Icinga's environment | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `runtime_options_in_icinga_s_environment` | green |
| integration-icinga2 → Shipped notification command | Command definition without env -i | `correlia_icinga2_notify/test/binary_test.dart` | `command_definition_without_env_i` | green |
| integration-icinga2 → Shipped notification command | Name with an embedded NUL is not delivered | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `name_with_an_embedded_nul_is_not_delivered` | green |
| integration-icinga2 → Shipped notification command | Oversized or invalid name is not delivered | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `oversized_or_invalid_name_is_not_delivered` | green |
| integration-icinga2 → Shipped notification command | Setting not deliverable exactly | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `setting_not_deliverable_exactly` | green |
| integration-icinga2 → Shipped notification command | NUL in a file path | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `nul_in_a_file_path` | green |
| integration-icinga2 → Shipped notification command | Base URL carrying a credential | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `base_url_carrying_a_credential` | green |
| integration-icinga2 → Shipped notification command | Multiline settings | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `multiline_settings` | green |
| integration-icinga2 → Shipped notification command | Source that is not a UUID | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `source_that_is_not_a_uuid` | green |
| integration-icinga2 → Shipped notification command | NUL in display text | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `nul_in_display_text` | green |
| integration-icinga2 → Shipped notification command | Inherited Correlia settings are ignored | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `inherited_correlia_settings_are_ignored` | green |
| integration-icinga2 → Webhook limits are documented | Documentation names the limits | `tool/test/icinga2_docs_test.dart` | `documentation_names_the_limits` | green |
| integration-icinga2 → State change time limits are documented | Documentation names the state change time limits | `tool/test/icinga2_docs_test.dart` | `documentation_names_the_state_change_time_limits` | green |
| integration-icinga2 → Downtime removal limits are documented | Documentation names the downtime limits | `tool/test/icinga2_docs_test.dart` | `documentation_names_the_downtime_limits` | green |
| integration-icinga2 → Notification text exposure is documented | Documentation names the text exposure | `tool/test/icinga2_docs_test.dart` | `documentation_names_the_text_exposure` | green |
| integration-icinga2 → Sender setup constraints are documented | Documentation names the setup constraints | `tool/test/icinga2_docs_test.dart` | `documentation_names_the_setup_constraints` | green |
| integration-icinga2 → Sender transport and diagnostics | Rejected delivery leaves no secret in Icinga 2 logs | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `rejected_delivery_leaves_no_secret_in_icinga_2_logs` | green |
| integration-icinga2 → Sender transport and diagnostics | Hostile inherited environment | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `hostile_inherited_environment` | green |
| integration-icinga2 → Sender transport and diagnostics | Configured CA is the only trust | `correlia_icinga2_notify/test/sender_test.dart` | `configured_ca_is_the_only_trust` | green |
| integration-icinga2 → Sender transport and diagnostics | URL without a scheme or with a loopback name | `correlia_icinga2_notify/test/sender_test.dart` | `url_without_a_scheme_or_with_a_loopback_name` | green |
| integration-icinga2 → Sender transport and diagnostics | Plain HTTP to a remote host | `correlia_icinga2_notify/test/sender_test.dart` | `plain_http_to_a_remote_host` | green |
| integration-icinga2 → Sender transport and diagnostics | Non-regular credential file | `correlia_icinga2_notify/test/sender_test.dart` | `non_regular_credential_file` | green |
| integration-icinga2 → Sender transport and diagnostics | Credential file larger than its check | `correlia_icinga2_notify/test/sender_test.dart` | `credential_file_larger_than_its_check` | green |
| integration-icinga2 → Sender transport and diagnostics | Blocking file after the check | `correlia_icinga2_notify/test/sender_test.dart` | `blocking_file_after_the_check` | green |
| integration-icinga2 → Sender transport and diagnostics | Credential file readable by others | `correlia_icinga2_notify/test/sender_test.dart` | `credential_file_readable_by_others` | green |
| integration-icinga2 → Sender transport and diagnostics | Peer never answers | `correlia_icinga2_notify/test/sender_test.dart` | `peer_never_answers` | green |
| integration-icinga2 → Sender transport and diagnostics | Only 202 counts as delivered | `correlia_icinga2_notify/test/sender_test.dart` | `only_202_counts_as_delivered` | green |
| integration-icinga2 → Sender transport and diagnostics | Redirect is not followed | `correlia_icinga2_notify/test/sender_test.dart` | `redirect_is_not_followed` | green |
| integration-icinga2 → Sender transport and diagnostics | Concurrent signed notifications beyond the cap | `correlia_server/test/e2e/icinga2_sender_e2e_test.dart` (the overlap), `correlia_server/test/unit/ingest/icinga2_versions_test.dart` (Icinga 2 logs the status) | `concurrent_signed_notifications_beyond_the_cap` | green |
| integration-icinga2 → Sender credential handling | Canonical unpadded key file | `correlia_server/test/e2e/icinga2_sender_e2e_test.dart` | `canonical_unpadded_key_file` | green |
| integration-icinga2 → Sender credential handling | HMAC vectors | `correlia_icinga2_notify/test/sender_test.dart` | `hmac_vectors` | green |
| integration-icinga2 → Webhook state change time precision | Two problems within one second | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `two_problems_within_one_second` | green |
| integration-icinga2 → Webhook state change time precision | Microsecond values survive the command | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `microsecond_values_survive_the_command` | green |
| integration-icinga2 → Webhook state change time precision | Production notification clock keeps microseconds | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `production_notification_clock_keeps_microseconds` | green |
| integration-icinga2 → State change time of a new object | First check result of a new host is DOWN | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `first_check_result_of_a_new_host_is_down` | green |
| integration-icinga2 → State change time of a new object | Earlier result with a negative execution end | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `earlier_result_with_a_negative_execution_end` | green |
| integration-icinga2 → State change time of a new object | Retained state across a restart | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `retained_state_across_a_restart` | green |
| integration-icinga2 → State change time of a new object | Initialized state change time of a runtime-created host | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `initialized_state_change_time_of_a_runtime_created_host` | green |
| integration-icinga2 → State change time of a new object | Volatile host with no state change yet | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `volatile_host_with_no_state_change_yet` | green |
| integration-icinga2 → State change time of a new object | Time outside the formatter's domain | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `time_outside_the_formatter_s_domain` | green |
| integration-icinga2 → Webhook state change time precision | Host command keeps sub-second precision | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `host_command_keeps_sub_second_precision` | green |
| integration-icinga2 → Webhook state is the object's state when the command runs | Recovery notification sent after a refire | `correlia_server/test/db/icinga2_ingest_test.dart` | `recovery_notification_sent_after_a_refire` | green |
| integration-icinga2 → Webhook state is the object's state when the command runs | Delayed recovery publishes the live check output | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `delayed_recovery_publishes_the_live_check_output` | green |
| integration-icinga2 → Webhook state is the object's state when the command runs | Delayed notifications in any order | `correlia_server/test/db/icinga2_ingest_test.dart` | `delayed_notifications_in_any_order` | green |
| integration-icinga2 → Webhook convergence contract | Lost recovery | `correlia_server/test/db/icinga2_ingest_test.dart` | `lost_recovery` | green |
| integration-icinga2 → Webhook convergence contract | Late reminder wins the event-ID insert | `correlia_server/test/db/icinga2_ingest_test.dart` | `late_reminder_wins_the_event_id_insert` | green |
| integration-icinga2 → Webhook convergence contract | Torn delivery arrives after the coherent one | `correlia_server/test/db/icinga2_ingest_test.dart` | `torn_delivery_arrives_after_the_coherent_one` | green |
| integration-icinga2 → Webhook convergence contract | Regressing execution end | `correlia_server/test/db/icinga2_ingest_test.dart` | `regressing_execution_end` | green |
| integration-icinga2 → Webhook convergence contract | First delivery of an old problem | `correlia_server/test/db/icinga2_ingest_test.dart` | `first_delivery_of_an_old_problem` | green |
| integration-icinga2 → Webhook convergence contract | Reversed receipt under the skew clamp | `correlia_server/test/db/icinga2_ingest_test.dart` | `reversed_receipt_under_the_skew_clamp` | green |
| integration-icinga2 → Webhook convergence contract | Equal state change times | `correlia_server/test/db/icinga2_ingest_test.dart` | `equal_state_change_times` | green |
| integration-icinga2 → Icinga2 alert identity | Host and service are distinct alerts | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `host_and_service_are_distinct_alerts` | green |
| integration-icinga2 → Icinga2 alert identity | Same names on another source | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `same_names_on_another_source` | green |
| integration-icinga2 → Icinga2 status and severity mapping | ID-7a WARNING to CRITICAL updates one alert | `correlia_server/test/db/icinga2_ingest_test.dart` | `id_7a_warning_to_critical_updates_one_alert` | green |
| integration-icinga2 → Icinga2 status and severity mapping | Informational delivery carrying a problem state | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `informational_delivery_carrying_a_problem_state` | green |
| integration-icinga2 → Icinga2 status and severity mapping | Unreachable host | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `unreachable_host` | green |
| integration-icinga2 → Icinga2 status and severity mapping | Unknown state name | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `unknown_state_name` | green |
| integration-icinga2 → Icinga2 alert projection | Same state with different check output | `correlia_server/test/db/icinga2_ingest_test.dart` | `same_state_with_different_check_output` | green |
| integration-icinga2 → Icinga2 alert projection | Missing check output | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `missing_check_output` | green |
| integration-icinga2 → SOFT states from the webhook are informational | Soft problem sampled by a delayed notification | `correlia_server/test/db/icinga2_ingest_test.dart` | `soft_problem_sampled_by_a_delayed_notification` | green |
| integration-icinga2 → SOFT states from the webhook are informational | Soft recovery resolves | `correlia_server/test/db/icinga2_ingest_test.dart` | `soft_recovery_resolves` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Out-of-range time | `correlia_server/test/db/icinga2_ingest_test.dart` | `out_of_range_time` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Time not in the fixed form | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `time_not_in_the_fixed_form` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Exact microseconds at the top of the range | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `exact_microseconds_at_the_top_of_the_range` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Fixed key vectors | `correlia_server/test/unit/ingest/icinga2_keys_test.dart` | `fixed_key_vectors` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Re-notification of an unchanged problem | `correlia_server/test/db/icinga2_ingest_test.dart` | `re_notification_of_an_unchanged_problem` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Soft to hard without a state value change | `correlia_server/test/db/icinga2_ingest_test.dart` | `soft_to_hard_without_a_state_value_change` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Zero state change time | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `zero_state_change_time` | green |
| integration-icinga2 → Icinga2 webhook observation evidence | Missing notification time | `correlia_server/test/unit/ingest/icinga2_webhook_test.dart` | `missing_notification_time` | green |
| integration-icinga2 → Acknowledgement, downtime and flapping events | Custom notification while the service is OK | `correlia_server/test/db/icinga2_ingest_test.dart` | `custom_notification_while_the_service_is_ok` | green |
| integration-icinga2 → Acknowledgement, downtime and flapping events | Acknowledgement is published without state change | `correlia_server/test/db/icinga2_ingest_test.dart` | `acknowledgement_is_published_without_state_change` | green |
| integration-icinga2 → Acknowledgement, downtime and flapping events | Two comments from one author | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `two_comments_from_one_author` | green |
| integration-icinga2 → Acknowledgement, downtime and flapping events | Same-microsecond executions coalesce | `correlia_server/test/db/icinga2_ingest_test.dart` | `same_microsecond_executions_coalesce` | green |
| integration-icinga2 → Acknowledgement, downtime and flapping events | Unsupported notification type | `correlia_server/test/db/icinga2_ingest_test.dart` | `unsupported_notification_type` | green |
| integration-icinga2 → Published author and comment | Published author and comment fields | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `published_author_and_comment_fields` | green |
| integration-icinga2 → Non-state key uses the delivered author | Authors equal in their first 1 KiB | `correlia_server/test/db/icinga2_ingest_test.dart` | `authors_equal_in_their_first_1_kib` | green |
| integration-icinga2 → Icinga2 display bounds | ID-3 maximum-length host and long check output | `correlia_server/test/db/icinga2_ingress_test.dart` | `id_3_maximum_length_host_and_long_check_output` | green |
| integration-icinga2 → Icinga2 display bounds | Oversize identity value | `correlia_server/test/unit/ingest/icinga2_mapper_test.dart` | `oversize_identity_value` | green |
| integration-icinga2 → Supported Icinga 2 releases | Each shipped architecture is run | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `each_shipped_architecture_is_run` | green |
| integration-icinga2 → Supported Icinga 2 releases | Listed release missing a capture | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `listed_release_missing_a_capture` | green |
| integration-icinga2 → Supported Icinga 2 releases | 202 recorded but event missing | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `202_recorded_but_event_missing` | green |
| integration-icinga2 → Supported Icinga 2 releases | Every capture decodes | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `every_capture_decodes` | green |
| integration-icinga2 → Supported Icinga 2 releases | Known timestamp mismatch | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `known_timestamp_mismatch` | green |
| integration-icinga2 → Supported Icinga 2 releases | Gate evidence present but failing | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `gate_evidence_present_but_failing` | green |
| integration-icinga2 → First problem of a new object qualifies a release | Five gates pass but the first problem is lost | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `five_gates_pass_but_the_first_problem_is_lost` | green |
| integration-icinga2 → First problem of a new object qualifies a release | Reminder of a first problem is a new observation | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `reminder_of_a_first_problem_is_a_new_observation` | green |
| integration-icinga2 → First problem of a new object qualifies a release | Reminder accepted without a committed duplicate outcome | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `reminder_accepted_without_a_committed_duplicate_outcome` | green |
| integration-icinga2 → First problem of a new object qualifies a release | Second HARD check emits a second event | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `second_hard_check_emits_a_second_event` | green |
| integration-icinga2 → First-problem gate evidence | Transport duplicate counted as a reminder outcome | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `transport_duplicate_counted_as_a_reminder_outcome` | green |
| integration-icinga2 → Supported Icinga 2 releases | Multiline recovery and custom notification without output | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `multiline_recovery_and_custom_notification_without_output` | green |
| integration-icinga2 → Supported Icinga 2 releases | Macro text in a setting is literal | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `macro_text_in_a_setting_is_literal` | green |
| integration-icinga2 → Supported Icinga 2 releases | Same-named custom variables are ignored | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `same_named_custom_variables_are_ignored` | green |
| integration-icinga2 → Supported Icinga 2 releases | Only one architecture qualifies | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `only_one_architecture_qualifies` | green |
| integration-icinga2 → Supported Icinga 2 releases | Captured downtime removal | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `captured_downtime_removal` | green |
| integration-icinga2 → Supported Icinga 2 releases | Captured transition sequence | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `captured_transition_sequence` | green |
| integration-icinga2 → Supported Icinga 2 releases | Captured host transitions | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `captured_host_transitions` | green |
| integration-icinga2 → Supported Icinga 2 releases | No release passes | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `no_release_passes` | green |
| integration-icinga2 → Supported Icinga 2 releases | A capture changes shape | `correlia_server/test/unit/ingest/icinga2_versions_test.dart` | `a_capture_changes_shape` | green |
| source-ingress → Source configuration format | Version 1 file still starts | `correlia_server/test/e2e/secret_store_e2e_test.dart` | `version_1_file_still_starts` (existing; re-run) | green |
| source-ingress → Source configuration format | Unsupported kind or field | `correlia_server/test/unit/ingest/source_config_test.dart` | `unsupported_kind_or_field` (existing; re-run) | green |
| source-ingress → Source configuration format | Supported kinds | `correlia_server/test/db/icinga2_ingress_test.dart` | `supported_kinds` | green |
| source-ingress → Credential rotation with overlap | Overlapping rotation | `correlia_server/test/db/ingress_credentials_test.dart` | `overlapping_rotation` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Expired and not yet valid credentials | `correlia_server/test/db/ingress_credentials_test.dart` | `expired_and_not_yet_valid_credentials` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Rotation during a body read | `correlia_server/test/db/ingress_credentials_test.dart` | `rotation_during_a_body_read` (existing; re-run) | green |
| source-ingress → Credential rotation with overlap | Activation without a usable credential | `correlia_server/test/unit/ingest/source_config_test.dart` | `activation_without_a_usable_credential` (existing; re-run) | green |
| source-ingress → A source's kind never changes | Kind change refused | `correlia_server/test/db/ingest_config_test.dart` | `kind_change_refused` | green |
| source-ingress → A source's kind never changes | Disabled source keeps its kind | `correlia_server/test/db/ingest_config_test.dart` | `disabled_source_keeps_its_kind` | green |
| source-ingress → A source's kind never changes | Admitted row decodes with its kind | `correlia_server/test/db/decoder_dispatch_test.dart` | `admitted_row_decodes_with_its_kind` | green |
| source-ingress → A source's kind never changes | Source disabled before the first claim | `correlia_server/test/db/decoder_dispatch_test.dart` | `source_disabled_before_the_first_claim` | green |
| source-ingress → Path tokens stay Alertmanager-only | Icinga2 source declares a path token | `correlia_server/test/unit/ingest/source_config_test.dart` | `icinga2_source_declares_a_path_token` | green |
| source-ingress → Path tokens stay Alertmanager-only | Path-token request on the Icinga2 route | `correlia_server/test/db/icinga2_ingress_test.dart` | `path_token_request_on_the_icinga2_route` | green |
| source-ingress → Identity label exclusion stays Alertmanager-only | Icinga2 source declares excluded identity labels | `correlia_server/test/unit/ingest/source_config_test.dart` | `icinga2_source_declares_excluded_identity_labels` | green |

The user-verified M2 exit criterion is not checked in this change. It needs the owner's real Icinga2 and
Alertmanager/Thanos feeding a dev instance for a day, and it needs Thanos and the enrichment changes, so the
proposal defers it to the M2 close. Group 8 documents the webhook setup the owner will use for it.

No new ADR (design.md, ADRs). Design's only open question is which releases make up the supported-release
list. Group 9's capture answers it, and the answer does not change what gets built.

## 1. Source configuration: the `icinga2` kind and immutable kinds

- [x] 1.1 Write failing tests for `icinga2_source_declares_a_path_token` and
  `icinga2_source_declares_excluded_identity_labels` (`source_config_test.dart`), `kind_change_refused` and
  `disabled_source_keeps_its_kind` (`ingest_config_test.dart`), and `supported_kinds` and
  `path_token_request_on_the_icinga2_route` (`icinga2_ingress_test.dart`). Verify each one fails for the
  missing kind or rule, not a setup error.
- [x] 1.2 Add a sealed `SourceKind` (`alertmanager`, `icinga2`) to the source model and the format version 2
  parser:
  - `path_token_enabled` and `excluded_identity_labels` are refused on non-Alertmanager kinds.
  - The `kind_changed` check runs against every source UUID ever published, disabled sources included.
  - Mount the `/hooks/icinga2/<source>` route behind the same admission as Alertmanager, so a credential in
    its path is refused.

  Verify that the 1.1 tests pass, and flip their rows green.
- [x] 1.3 Re-run the carried tests (`version_1_file_still_starts`, `unsupported_kind_or_field`,
  `overlapping_rotation`, `expired_and_not_yet_valid_credentials`, `rotation_during_a_body_read`,
  `activation_without_a_usable_credential`). Remove any kind-change case from `rotation_during_a_body_read`,
  because the modified requirement dropped it. Verify all six pass.
- [x] 1.4 Document the `icinga2` kind, `kind_changed`, and the Alertmanager-only options in the configuration
  section of `docs/ingest-pipeline.md`. Verify with `mise run check`.

## 2. Schema step 4 and the recorded clamp (ORD-4)

- [x] 2.1 Write failing tests:
  - `events_stored_before_the_upgrade` and `sub_microsecond_evidence` (`schema_step_test.dart`)
  - `ord_4_future_source_time_beyond_the_skew_limit` and `source_time_within_the_skew_allowance`
    (`pipeline_test.dart`)

  Verify that they fail on the missing column and counter.
- [x] 2.2 Add Correlia schema step 4: a nullable clamp column on `events`, catalog-only with no row rewrite,
  under the step `lock_timeout`, plus the read expression design D5 defines for older rows. Record the clamp
  on the stored event and count clamped observations on the raw outcome; the published `source_time` stays
  as reported. Verify that the 2.1 tests pass, and flip their rows green.
- [x] 2.3 Write `schema_step_4_under_lock_contention`, `schema_runner_waits_behind_another_starter` and
  `offline_upgrade_with_pending_work` (`icinga2_upgrade_e2e_test.dart`). Each starts a real child against its
  own e2e root. Fail first, implement the `lock_timeout` failure class exit, verify that they pass, and flip
  their rows green.
- [x] 2.4 Document step 4, the offline upgrade order and the clamp record in `docs/ingest-pipeline.md`.
  Verify with `mise run check`.

## 3. Decoder dispatch by the pinned source's kind

- [x] 3.1 Write failing tests in `decoder_dispatch_test.dart`:
  - `two_kinds_in_one_batch`
  - `existing_rows_after_the_upgrade`
  - `row_pinned_to_a_format_version_1_snapshot`
  - `missing_kind_in_a_version_2_snapshot`
  - `body_of_another_kind`
  - `admitted_row_decodes_with_its_kind`
  - `source_disabled_before_the_first_claim`

  Use a stub Icinga2 decoder that only reports that it ran, until group 4 lands.
- [x] 3.2 Replace the pipeline's fixed Alertmanager decode with an exhaustive switch on the pinned source's
  `SourceKind`:
  - A version 1 snapshot reads as Alertmanager.
  - A version 2 snapshot with no kind fails with `unsupported_kind`.
  - An unconfigured source fails with `source_not_configured` before any decoder runs.

  Verify that the 3.1 tests pass, and flip their rows green.

## 4. Icinga2 webhook parser, mapper and observation keys

- [x] 4.1 Write failing unit tests:
  - `icinga2_webhook_test.dart`: unknown and dotted field names, the format version, time form and range
    vectors, the zero time, the missing notification time, and an unknown state.
  - `icinga2_mapper_test.dart`: service problem, informational problem state, unreachable host, missing output,
    host versus service identity, ID-2, the oversize identity value, and the published author and comment.
  - `icinga2_keys_test.dart`: the fixed key vectors, with committed example deliveries and expected key
    strings, bytes and event ids.
- [x] 4.2 Implement `correlia_server/lib/src/ingest/icinga2/`:
  - The document v1 parser. It bounds nesting before parsing, rejects unknown keys with the structural `*`
    path, and rejects NUL in identity text with `invalid_text`.
  - Fixed-form string times, converted to microseconds by integer arithmetic.
  - The sealed `Icinga2Fact` types.
  - One mapper to `CanonicalEvent`, covering status, severity, `severity_original`, the projection from object
    and state, display bounds, and the description and author annotation of non-state events.
  - State and non-state observation keys, with the author cut to 1 KiB.

  Use sealed classes and exhaustive switches, with no `dynamic`. Verify that the 4.1 tests pass, and flip
  their rows green.
- [x] 4.3 Write failing db tests in `icinga2_ingest_test.dart` for every row mapped to it: decode failures
  without retry or commits, ID-7a, the projection, SOFT handling, duplicates and re-notifications, non-state
  events, the coalescing and author rules, and the convergence contract scenarios. Run them against the
  real pipeline, then fix whatever they expose. Verify that they pass, and flip their rows green.
- [x] 4.4 Write `id_3_maximum_length_host_and_long_check_output` (`icinga2_ingress_test.dart`) through HTTP
  ingress. Make it pass, and flip its row green.
- [x] 4.5 Document the webhook document v1 (fields, time form, error codes), the mapping table and the
  convergence contract in the Icinga2 section of `docs/ingest-pipeline.md`. Verify with `mise run check`.

## 5. Alert-state ordering scenarios (ORD-6, ORD-7)

- [x] 5.1 Write the named tests in `alert_state_test.dart`:
  - `ord_7a_two_observations_in_both_orders`
  - `ord_7b_late_and_new_observations_in_any_schedule` (each order, plus two concurrent transactions released
    by completers)
  - `duplicate_deliveries_carry_one_observation`
  - `same_observation_key_from_two_sources`
  - `late_duplicate_of_a_ready_observation`
  - `ord_7c_duplicate_of_a_late_observation`
  - `ord_6_late_firing_after_resolution_and_expiry` (event rows and keys deleted directly, per S5)
  - `late_firing_for_a_fingerprint_with_no_alert`

  Use Icinga2 events. Run each new test, and fix whatever fails. Verify that every row of this group is green.
- [x] 5.2 Re-run `ord_3_equal_source_times_ordered_deterministically` and
  `source_times_less_than_a_microsecond_apart`. Verify that both pass.

## 6. The compiled sender `correlia-icinga2-notify`

- [x] 6.1 Scaffold the package `correlia_icinga2_notify/`, with crypto as its only dependency. Add
  `mise run build:icinga2-notify` for linux-x64 and linux-arm64 builds, and add the package to the
  `analyze`, `format` and `check` tasks. Verify that `mise run build:icinga2-notify` produces both binaries
  and that `mise run check` passes.
- [x] 6.2 Write failing tests:
  - `sender_test.dart`, in process, with an injected deadline, injected file hooks and local HTTP/TLS
    listeners: CA-only trust, URL rules, plain HTTP to a remote host, the FIFO credential, a file that grows
    after the check, a blocking file, file modes, a peer that never answers, the 202-only rule, redirects, and
    the RFC 4231 HMAC vectors.
  - `binary_test.dart`: `command_definition_without_env_i` against the compiled binary.
- [x] 6.3 Implement the sender:
  - Empty-environment check (exit 2 `environment`).
  - Argument validation: exact names, UUID source, base URL pattern, control characters, NUL replacement in
    texts.
  - Asynchronous capped file reads, with the stat precheck and the `credential_mode`/`ca_mode` checks.
  - `setTrustedCertificatesBytes` as the only trust.
  - Bearer or HMAC (ADR 0029).
  - A 10 s deadline and no redirects.
  - Exit codes 0, 1, 2 and 3, with status-only logging.

  Verify that the 6.2 tests pass, and flip their rows green.
- [x] 6.4 Write `rejected_delivery`, `canonical_unpadded_key_file` and
  `concurrent_signed_notifications_beyond_the_cap` (`icinga2_sender_e2e_test.dart`). Each runs the built
  binary against a real Correlia child. Make them pass, and flip their rows green.

## 7. Shipped command definitions

- [x] 7.1 Write `contrib/icinga2/`:
  - The host and service `NotificationCommand`s. They launch through `/usr/bin/env -i`, use
    `timeout = 15`, and define argument functions that read only qualified macros, with the output read from
    the live object's `last_check_result`.
  - The `correlia_text` and `correlia_exact` helpers, and the D13 state change time helpers: per object type,
    `last_state_change` after a state value change (a nonzero `last_state_up`; a nonzero `last_state_ok`,
    `last_state_warning` or `last_state_critical`), else `last_hard_state_change` in HARD, never the
    initializer; the chosen time then checked against the formatter's `1 <= seconds < 2^32` domain, with no
    fall-through to the other timestamp; `--last-state-change` with a `set_if` on the notification type only
    (passed for `PROBLEM`/`RECOVERY`, never for other types) and a `value` that reads the timestamps once and
    renders JSON `""` when no usable time exists.
  - `correlia.conf` with the global constants, the base URL and source patterns, and `set_if` omission of
    absent texts.

  Verify that `icinga2 daemon -C` accepts the files inside an official image. The capture script runs this
  as its first step; record its output in 8.2's evidence.
- [x] 7.2 Write failing tests for D13's optional field: `state_notification_without_a_state_change_time`
  (`icinga2_webhook_test.dart`), `non_state_key_without_the_state_change_time` (`icinga2_keys_test.dart`),
  `invalid_state_change_time_on_a_non_state_delivery` (`icinga2_webhook_test.dart`),
  `custom_notification_without_a_state_change_time` (`icinga2_ingest_test.dart`),
  and sender tests in `sender_test.dart`: a `CUSTOM`, `ACKNOWLEDGEMENT`, `DOWNTIMESTART` and `FLAPPINGSTART`
  run without `--last-state-change` delivers a document without the field; a `PROBLEM` or `RECOVERY` run
  without it, or with the JSON empty string, exits 2 naming it before any connection. Confirm them red.
- [x] 7.3 Make `last_state_change` optional in the parser and required by the mapper for `PROBLEM` and
  `RECOVERY` only (`missing_field` on that path; `StateFact` keeps a non-null time, `notification_time` stays
  required for every type), and the sender's `--last-state-change` required for those two types only, the
  document omitting the field when the argument is absent. Update the field table of the webhook document in
  `docs/ingest-pipeline.md` (required only for `PROBLEM`/`RECOVERY`). Verify that 7.2's tests, the key vectors
  and the existing Icinga2 and sender tests pass unchanged, and flip the four test map rows green.

## 8. Icinga2 setup documentation

- [x] 8.1 Write failing `tool/test/icinga2_docs_test.dart` for the five documentation rows.
- [x] 8.2 Write the Icinga2 setup section of `docs/ingest-pipeline.md`, covering:
  - Installing the binary and the definitions.
  - The no-retry, SOFT and suppression limits.
  - Both downtime removal limits.
  - The places where text is exposed: the process list, the failure log and the Notice-level launch log.
  - The loader-variable rule, the argument budget, the directory rule and `invalid_name`.
  - The HMAC concurrency cap and the loss it causes.
  - The worker upgrade order.
  - The formatter's input domain, the time a new object's first problem carries, and the volatile-object limit
    (D13).

  Verify that the 8.1 test passes, and flip its rows green.
- [x] 8.3 [evidence] → evidence/icinga2-config-check.txt: Run the configuration check of the shipped
  definitions in an official image, and record the image tag and the `icinga2 daemon -C` output.

## 9. Captures, version matrix and supported releases

- [x] 9.1 Write `tool/icinga2_capture.sh`, modelled on `tool/alertmanager_capture.sh`. It works in its own
  temp directory with cleanup on exit, never touches another service, and does the following:
  - Runs each official Icinga 2 image from 2.13 onwards for linux-x64. linux-arm64 is not captured in this
    change (owner, 2026-11-20: no QEMU registration on the capture host), so it has no qualified pair and its
    artifact is built but not published ("Only one architecture qualifies").
  - Installs the built sender and the `contrib/icinga2/` definitions the way an operator would.
  - Drives every capture scenario mapped to `icinga2_versions_test.dart` against a real Correlia child and a
    recording receiver.
  - Records, independently of the webhook, the execution end of every result the driver submits.
  - Correlates each newly admitted request with its new raw row and records the row's terminal status and
    outcome JSON (a `duplicate_observation` count among them); records transport-deduplicated 202s (no new
    raw row), rejections and requests sent only to the recording receiver as separate kinds, and after each step the committed alert state (status, severity,
    version, fence) and the event counts of the object.
  - Writes requests, statuses, Icinga 2 log excerpts and the decoded canonical events under
    `correlia_server/test/unit/ingest/fixtures/icinga2/<release>/<arch>/`.

  Verify by running it against one release.
- [x] 9.2 Write failing `icinga2_versions_test.dart`. It holds one named test per mapped scenario, plus:
  - The six-gate evaluation per listed pair: same-second service and host times, the known timestamp
    decode, the clock sample, downtime removal, the first problem of a new object (both host origins'
    first-HARD times, one firing alert each, deduplicated reminders, the unchecked service's CUSTOM 202 and
    `comment` event), and the recorded 202 with its decoded event.
  - The failure-naming checks (missing capture, 202 without an event, a failing gate, a timestamp mismatch, an
    unknown field, no release passing, five gates passing with a lost first problem or a new-key reminder, a
    reminder with a 202 and no event but no committed `duplicate_observation` outcome, a second firing event
    with a reminder that duplicates it, a transport duplicate offered as a reminder outcome), run
    against synthetic broken evidence in a temp directory.

  Verify that it fails with no captures committed.
- [x] 9.3 Run the capture for every candidate release and architecture. Commit the captures. Write the
  supported-release statement, listing only pairs that pass all six gates with a recorded 202 and decoded
  event, into `docs/ingest-pipeline.md`. Verify that `icinga2_versions_test.dart` passes, and flip its rows
  green. If no pair qualifies, stop and return the change to the owner (design, Risks).
- [x] 9.4 [evidence] → evidence/icinga2-capture.md: Record the capture run (script version, image tags and
  digests, architectures, the gate results per pair, and the resulting statement).
- [x] 9.5 Make the release build publish an architecture's artifact only when it has a qualified pair. Verify
  `only_one_architecture_qualifies` and `no_release_passes` (synthetic evidence) in `icinga2_versions_test.dart`.

## 10. Integration

- [x] 10.1 Run `mise run check` and `mise run test:all`, plus the sender package's tests. Verify that everything
  passes and that every test map row is green.
- [x] 10.2 Run `mise exec -- openspec validate icinga2-ingest --strict`, and verify that it reports the change
  valid.

## Workflow follow-up

- Pre-ship review, PR with the `Linux verification` check and the Codex review, archive on the change branch,
  merge (`finish: pr`).
- `release.enabled` is false, so there is no version bump task.
