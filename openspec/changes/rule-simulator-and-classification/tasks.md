# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| durable-pipeline → The earliest same-ID member of a batch is the candidate | First input member is the candidate | `correlia_server/test/db/duplicate_order_test.dart` | `first_input_member_is_the_candidate` | green |
| durable-pipeline → The earliest same-ID member of a batch is the candidate | Reversed input order | `correlia_server/test/db/duplicate_order_test.dart` | `reversed_input_order` | green |
| durable-pipeline → The earliest same-ID member of a batch is the candidate | Stream copies straddle the future limit | `correlia_server/test/db/duplicate_order_test.dart` | `stream_copies_straddle_the_future_limit` | green |
| durable-pipeline → Rows decode by their source's kind | Two kinds in one batch | `correlia_server/test/db/decoder_dispatch_test.dart` | `two_kinds_in_one_batch` | green |
| durable-pipeline → Rows decode by their source's kind | Existing rows after the upgrade | `correlia_server/test/db/decoder_dispatch_test.dart` | `existing_rows_after_the_upgrade` | green |
| durable-pipeline → Rows decode by their source's kind | Row pinned to a format version 1 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `row_pinned_to_a_format_version_1_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Schema step 4 under lock contention | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_step_4_under_lock_contention` | green |
| durable-pipeline → Rows decode by their source's kind | Schema runner waits behind another starter | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `schema_runner_waits_behind_another_starter` | green |
| durable-pipeline → Rows decode by their source's kind | Missing kind in a version 2 snapshot | `correlia_server/test/db/decoder_dispatch_test.dart` | `missing_kind_in_a_version_2_snapshot` | green |
| durable-pipeline → Rows decode by their source's kind | Offline upgrade with pending work | `correlia_server/test/e2e/icinga2_upgrade_e2e_test.dart` | `offline_upgrade_with_pending_work` | green |
| durable-pipeline → Rows decode by their source's kind | Body of another kind | `correlia_server/test/db/decoder_dispatch_test.dart` | `body_of_another_kind` | green |
| durable-pipeline → Rows decode by their source's kind | Stream row of a stream source | `correlia_server/test/db/decoder_dispatch_test.dart` | `stream_row_of_a_stream_source` | green |
| durable-pipeline → Rows decode by their source's kind | Unknown stream format | `correlia_server/test/db/decoder_dispatch_test.dart` | `unknown_stream_format` | green |
| durable-pipeline → Rows decode by their source's kind | Generic mapping changes before the first claim | `correlia_server/test/db/decoder_dispatch_test.dart` | `generic_mapping_changes_before_the_first_claim` | green |
| durable-pipeline → Rows decode by their source's kind | Generic mapping changes after the first claim | `correlia_server/test/db/decoder_dispatch_test.dart` | `generic_mapping_changes_after_the_first_claim` | green |
| durable-pipeline → Rows decode by their source's kind | Generic row pinned to a snapshot without its mapping | `correlia_server/test/db/decoder_dispatch_test.dart` | `generic_row_pinned_to_a_snapshot_without_its_mapping` | green |
| event-classification → Decoder-owned event kind | Alertmanager-protocol and generic kinds | `correlia_server/test/unit/ingest/event_kind_test.dart` | `alertmanager_protocol_and_generic_kinds` | green |
| event-classification → Decoder-owned event kind | Icinga2 webhook kinds | `correlia_server/test/unit/ingest/event_kind_test.dart` | `icinga2_webhook_kinds` | green |
| event-classification → Decoder-owned event kind | Icinga2 Event Streams kinds under each state policy | `correlia_server/test/unit/ingest/event_kind_test.dart` | `icinga2_event_streams_kinds_under_each_state_policy` | green |
| event-classification → Decoder-owned event kind | A label named kind does not change kind | `correlia_server/test/unit/ingest/event_kind_test.dart` | `a_label_named_kind_does_not_change_kind` | green |
| event-classification → Noise class hints | Classify a watchdog alert | `correlia_server/test/unit/matcher/classify_test.dart` | `classify_a_watchdog_alert` | green |
| event-classification → Noise class hints | Later classify wins | `correlia_server/test/unit/matcher/classify_test.dart` | `later_classify_wins` | green |
| event-classification → Noise class hints | Value outside the vocabulary | `correlia_server/test/unit/matcher/classify_test.dart` | `value_outside_the_vocabulary` | green |
| event-classification → Noise class hints | Other actions cannot write the reserved key | `correlia_server/test/db/matcher_reserved_label_test.dart` | `other_actions_cannot_write_the_reserved_key` | green |
| event-classification → Noise class hints | A snapshot pinned before the change keeps running | `correlia_server/test/db/matcher_reserved_label_test.dart` | `a_snapshot_pinned_before_the_change_keeps_running` | green |
| event-classification → Noise class hints | Source label with the reserved key | `correlia_server/test/unit/matcher/classify_test.dart` | `source_label_with_the_reserved_key` | green |
| matcher-rules → Classify action | Existing documents stay valid | `correlia_server/test/unit/matcher/classify_test.dart` | `existing_documents_stay_valid` | green |
| matcher-rules → Classify action | New actions in one rule | `correlia_server/test/unit/matcher/classify_test.dart` | `new_actions_in_one_rule` | green |
| matcher-rules → Classify action | A failing action discards the hint | `correlia_server/test/unit/matcher/classify_test.dart` | `a_failing_action_discards_the_hint` | green |
| matcher-rules → Classify action | Upgrade with a file that writes the reserved key | `correlia_server/test/db/matcher_reserved_label_test.dart` | `upgrade_with_a_file_that_writes_the_reserved_key` | green |
| matcher-rules → Classify action | Exact restart with a pre-change file that writes the reserved key | `correlia_server/test/db/matcher_reserved_label_test.dart` | `exact_restart_with_a_pre_change_file_that_writes_the_reserved_key` | green |
| matcher-rules → Classify action | Rollback to pre-change content that writes the reserved key | `correlia_server/test/db/matcher_reserved_label_test.dart` | `rollback_to_pre_change_content_that_writes_the_reserved_key` | green |
| matcher-rules → Classify action | Pinned pre-change snapshot keeps running | `correlia_server/test/db/matcher_reserved_label_test.dart` | `pinned_pre_change_snapshot_keeps_running` | green |
| matcher-rules → Classify action | Malformed classify action | `correlia_server/test/unit/matcher/classify_test.dart` | `malformed_classify_action` | green |
| matcher-rules → Short-circuit evaluation is preserved | A decisive any skips a slow regex | `correlia_server/test/unit/matcher/explain_test.dart` | `a_decisive_any_skips_a_slow_regex` | green |
| matcher-rules → Short-circuit evaluation is preserved | A decisive all skips a slow regex | `correlia_server/test/unit/matcher/explain_test.dart` | `a_decisive_all_skips_a_slow_regex` | green |
| rule-simulator → Simulate one event against active or draft rules | Simulate a pasted event against the active rules | `correlia_server/test/db/rule_simulator_test.dart` | `simulate_a_pasted_event_against_the_active_rules` | green |
| rule-simulator → Simulate one event against active or draft rules | Simulate a stored event against a draft | `correlia_server/test/db/rule_simulator_test.dart` | `simulate_a_stored_event_against_a_draft` | green |
| rule-simulator → Simulate one event against active or draft rules | Future-dated row and its later ready row | `correlia_server/test/db/rule_simulator_test.dart` | `future_dated_row_and_its_later_ready_row` | green |
| rule-simulator → Simulate one event against active or draft rules | Several rows at one key | `correlia_server/test/db/rule_simulator_test.dart` | `several_rows_at_one_key` | green |
| rule-simulator → Simulate one event against active or draft rules | Same-identity alerts in one raw batch | `correlia_server/test/db/rule_simulator_test.dart` | `same_identity_alerts_in_one_raw_batch` | green |
| rule-simulator → Simulate one event against active or draft rules | Stored duplicate from before this change | `correlia_server/test/db/rule_simulator_test.dart` | `stored_duplicate_from_before_this_change` | green |
| rule-simulator → Simulate one event against active or draft rules | Unknown stored event | `correlia_server/test/db/rule_simulator_test.dart` | `unknown_stored_event` | green |
| rule-simulator → Simulate one event against active or draft rules | Raw row no longer retained | `correlia_server/test/db/rule_simulator_test.dart` | `raw_row_no_longer_retained` | green |
| rule-simulator → Simulate one event against active or draft rules | Both or neither input given | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `both_or_neither_input_given` | green |
| rule-simulator → Simulate one event against active or draft rules | Partial or orphaned key fields | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `partial_or_orphaned_key_fields` | green |
| rule-simulator → Simulate one event against active or draft rules | Invalid pasted event | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `invalid_pasted_event` | green |
| rule-simulator → Simulate one event against active or draft rules | Invalid draft | `correlia_server/test/db/rule_simulator_test.dart` | `invalid_draft` | green |
| rule-simulator → Simulate one event against active or draft rules | A draft equal to earlier content is still new | `correlia_server/test/db/rule_simulator_test.dart` | `a_draft_equal_to_earlier_content_is_still_new` | green |
| rule-simulator → Simulate one event against active or draft rules | No active matcher configuration | `correlia_server/test/db/rule_simulator_test.dart` | `no_active_matcher_configuration` | green |
| rule-simulator → Simulate one event against active or draft rules | Refused outside the local console policy | `correlia_server/test/db/rule_simulator_rpc_test.dart` | `refused_outside_the_local_console_policy` | green |
| rule-simulator → Stored event keys and members | Invalid stored key | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `invalid_stored_key` | green |
| rule-simulator → Stored event keys and members | Malformed observed_at | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `malformed_observed_at` | green |
| rule-simulator → Stored event keys and members | Kept member cannot be identified | `correlia_server/test/db/rule_simulator_test.dart` | `kept_member_cannot_be_identified` | green |
| rule-simulator → Stored event keys and members | Members differ only in an excluded label | `correlia_server/test/db/rule_simulator_test.dart` | `members_differ_only_in_an_excluded_label` | green |
| rule-simulator → Explain every rule and condition decision | RUL-2 missing field is visible | `correlia_server/test/unit/matcher/explain_test.dart` | `rul_2_missing_field_is_visible` | green |
| rule-simulator → Explain every rule and condition decision | Missing field under not | `correlia_server/test/unit/matcher/explain_test.dart` | `missing_field_under_not` | green |
| rule-simulator → Explain every rule and condition decision | Explicit null in a pasted event | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `explicit_null_in_a_pasted_event` | green |
| rule-simulator → Explain every rule and condition decision | Short-circuited leaves are not evaluated | `correlia_server/test/unit/matcher/explain_test.dart` | `short_circuited_leaves_are_not_evaluated` | green |
| rule-simulator → Explain every rule and condition decision | Regex leaf times out | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `regex_leaf_times_out` | green |
| rule-simulator → Explain every rule and condition decision | Simulation reaches the optional cutoff | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `simulation_reaches_the_optional_cutoff` | green |
| rule-simulator → Simulation results match the pipeline | RUL-1 documented examples produce the documented decisions | `correlia_server/test/unit/simulator/rul1_docs_test.dart` | `rul_1_documented_examples_produce_the_documented_decisions` | green |
| rule-simulator → Simulation results match the pipeline | Later rule wins a shared key | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `later_rule_wins_a_shared_key` | green |
| rule-simulator → Simulation results match the pipeline | A failing action discards only its rule's patch | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `a_failing_action_discards_only_its_rule_s_patch` | green |
| rule-simulator → Simulation results match the pipeline | Pipeline and simulator agree for a deliverable event | `correlia_server/test/db/rule_simulator_test.dart` | `pipeline_and_simulator_agree_for_a_deliverable_event` | green |
| rule-simulator → Simulation results match the pipeline | The pipeline's cutoff left rules unattempted | `correlia_server/test/db/rule_simulator_test.dart` | `the_pipeline_s_cutoff_left_rules_unattempted` | green |
| rule-simulator → Simulation results match the pipeline | Stored event processed under other rules | `correlia_server/test/db/rule_simulator_test.dart` | `stored_event_processed_under_other_rules` | green |
| rule-simulator → Simulation results match the pipeline | The pipeline's regex budget ran out | `correlia_server/test/db/rule_simulator_test.dart` | `the_pipeline_s_regex_budget_ran_out` | green |
| rule-simulator → Simulation results match the pipeline | The pipeline's regex call overran its budget | `correlia_server/test/db/rule_simulator_test.dart` | `the_pipeline_s_regex_call_overran_its_budget` | green |
| rule-simulator → Simulation results match the pipeline | Routes for an ineligible event are hypothetical | `correlia_server/test/db/rule_simulator_test.dart` | `routes_for_an_ineligible_event_are_hypothetical` | green |
| rule-simulator → Simulated fanout bound | Simulated effect beyond the fanout bound | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `simulated_effect_beyond_the_fanout_bound` | green |
| rule-simulator → Simulated fanout bound | Baseline already over the fanout bound | `correlia_server/test/unit/simulator/rule_simulation_test.dart` | `baseline_already_over_the_fanout_bound` | green |
| rule-simulator → Hints come only from simulated classify | Stored label is not a hint | `correlia_server/test/db/rule_simulator_test.dart` | `stored_label_is_not_a_hint` | green |
| rule-simulator → Route baseline comes from the active snapshot | A route moved from source configuration to a rule | `correlia_server/test/db/rule_simulator_test.dart` | `a_route_moved_from_source_configuration_to_a_rule` | green |
| rule-simulator → Route baseline comes from the active snapshot | Source absent from the active snapshot | `correlia_server/test/db/rule_simulator_test.dart` | `source_absent_from_the_active_snapshot` | green |
| rule-simulator → Simulation has no side effects | Failing rule in simulation is not counted | `correlia_server/test/db/rule_simulator_test.dart` | `failing_rule_in_simulation_is_not_counted` | green |
| rule-simulator → Simulation has no side effects | The endpoint writes no session log | `correlia_server/test/db/rule_simulator_rpc_test.dart` | `the_endpoint_writes_no_session_log` | green |
| rule-simulator → Simulation has no side effects | Simulation leaves stored state unchanged | `correlia_server/test/db/rule_simulator_rpc_test.dart` | `simulation_leaves_stored_state_unchanged` | green |
| workspace-tooling → Simulator command line | Trace a stored event | `correlia_server/test/db/simulate_cli_test.dart` | `trace_a_stored_event` | green |
| workspace-tooling → Simulator command line | Malformed timestamp | `correlia_server/test/unit/tool/simulate_cli_test.dart` | `malformed_timestamp` | green |
| workspace-tooling → Simulator command line | Simulator error | `correlia_server/test/unit/tool/simulate_cli_test.dart` | `simulator_error` | green |

Every `db` test names its tier with `testGroupTagsOverride`; fast tests carry no tag.

## 1. ADR and architecture

- [x] 1.1 Write `docs/adr/0034-rule-simulator-and-event-classification.md` (status accepted): the read-only simulator over re-decoded stored events (D8-D10), decoder-owned kind (S4), the reserved `correlia.noise_class` label checked against new content only (D13), the `matcher_content_digest` and `matcher_content_digest_fill` SQL-owned tables, and the stable duplicate order (D14). Verify: the file exists and names each decision with its rejected alternative.
- [x] 1.2 Add ADR 0034 to the in-force index in `openspec/architecture.md`, and list `matcher_content_digest` and `matcher_content_digest_fill` among the SQL-owned tables outside Serverpod's managed models and repairs. Verify: `mise exec -- openspec validate --strict` passes and both table names appear in the SQL-owned list.

## 2. Shared row decode (D12)

- [x] 2.1 Verify A1: for each source path (Alertmanager, Thanos via the Alertmanager protocol, Icinga2 webhook, Icinga2 Event Streams under each state policy, generic), decode one stored raw row twice through the current pipeline decode and compare the events apart from `processedAt` and the observation generation. Write it as `correlia_server/test/db/row_decode_test.dart` `decode_is_deterministic_per_source`. Verify: the test passes for every source, or the difference is reported as design drift before task 2.3.
- [x] 2.2 Write failing tests in `correlia_server/test/db/row_decode_test.dart`: `readDecodeInputs` returns the pin's source settings and a stream row's admission metadata, `decodeRow` is pure over those inputs, and an admission snapshot that differs from the processing pin decodes as the pipeline decodes it. Verify: they fail because `row_decode.dart` does not exist.
- [x] 2.3 Implement `correlia_server/lib/src/pipeline/row_decode.dart` (`readDecodeInputs`, `decodeRow`) and switch the pipeline to it inside its transaction. Write C3 as the doc comment of `readDecodeInputs`. Verify: the 2.2 tests pass, `mise run test -- --tags db` passes, and the doc comment states C3.
- [x] 2.4 Re-run the existing tests of the MODIFIED requirement "Rows decode by their source's kind" (`test/db/decoder_dispatch_test.dart`, `test/db/schema_step_test.dart`, `test/e2e/icinga2_upgrade_e2e_test.dart`, and the tests for the generic-mapping, schema-runner and offline-upgrade scenarios, located by searching for their behaviour and named in the test map). Verify: all pass and the test map names each one.

## 3. Deterministic duplicate order (D14)

- [x] 3.1 Write failing tests in `correlia_server/test/db/duplicate_order_test.dart` for `first_input_member_is_the_candidate` (a batch of more than 32 members, large enough that the previous unstable sort reorders equal IDs; show the fixture fails against the old sort), `reversed_input_order` (a fresh database) and `stream_copies_straddle_the_future_limit`. Verify: the first two fail for the right reason; the stream case passes already and stays as a regression.
- [x] 3.2 Order prepared events by event ID then input position in `pipeline.dart`, leaving the per-item stream gates before the same-ID check. C11 is checked at its spec destination in task 8.1. Verify: the 3.1 tests pass and flip their rows green; `mise run test -- --tags db` passes.

## 4. Classify action and the reserved label (S3, S4, D13)

- [x] 4.1 Write failing fast tests in `correlia_server/test/unit/matcher/classify_test.dart` for the classify and noise-hint scenarios in the test map, and in `correlia_server/test/unit/ingest/event_kind_test.dart` for each source's kind table. Verify: classify tests fail because the action does not exist; kind tests pass or fail only where a decoder disagrees with the table.
- [x] 4.2 Add the `classify` action to `matcher_document.dart` and `matcher_evaluation.dart` with the closed vocabulary and origin `matcher`; fix any kind-table disagreement. Verify: 4.1 tests pass and flip green; existing matcher tests pass.
- [x] 4.3 Write failing `db` tests in `correlia_server/test/db/matcher_reserved_label_test.dart` for the reserved-label publication scenarios, plus: a guarded restore and a rejection against a long history of distinct matcher contents with `EXPLAIN` on the real lookup under default planner settings asserting a primary-key index scan; an upgrade from a database holding an inactive snapshot with U+0000 in a plugin configuration and one with an encoded NUL matcher operand, processing such a pinned row through the worker; a fill spanning several keyset pages; a fill interrupted after some inserts, then a restart and a restore of a snapshot it had not reached; a concurrent starter that waits on the lock and finds the completion row; a starter that times out with `lock_timeout`. Verify: they fail because step `0015` does not exist.
- [x] 4.4 Add schema step `correlia_server/schema/0015_matcher_content_digest.sql` (both tables) and register it in `schema_steps.dart`; insert the digest in the publication transaction; add the startup fill (keyset pages of 100, one transaction, advisory lock with a 60 s timeout, completion row last) right after the schema steps; reject a non-`classify` write to `correlia.noise_class` only in content whose digest is absent. Verify: 4.3 tests pass and flip green; `mise run test -- --tags db` passes.
- [x] 4.5 Update `docs/ingest-pipeline.md`: the `classify` action and vocabulary, the reserved-key rule and its field error, the upgrade sequence (ADR 0033 drain, step `0015`, the fill, no return to a binary that cannot read `classify`), and both new tables and their primary keys in "Repair migrations". Verify: the doc sections exist and the existing docs test passes.

## 5. Explaining evaluator (D7)

- [x] 5.1 Write failing tests in `correlia_server/test/unit/matcher/explain_test.dart` for the short-circuit, missing-field and `not` scenarios, including that a skipped regex child is never called. Verify: they fail because no explaining variant exists.
- [x] 5.2 Implement the explaining evaluation in `matcher_condition.dart` with the same short-circuit flow as `_Many`; the pipeline builds no trace. Verify: 5.1 tests pass and flip green; `matcher_pipeline_test.dart` passes unchanged.

## 6. Rule simulator (D8-D10)

- [x] 6.1 Add the Serverpod models `RuleSimulationResult`, `RuleTrace` (rule outcome separate from condition outcome), `ConditionTrace`, `ActionTrace` and `SimulationError`; run generation. Verify: `mise run check` generated-code step passes.
- [x] 6.2 Write failing fast tests in `correlia_server/test/unit/simulator/rule_simulation_test.dart` for the input-validation, `observedAt`, trace-state (`regex_timeout`, `regex_budget`, `matcher_cutoff`, `not attempted`), patch and fanout scenarios in the test map. Verify: they fail because the simulator does not exist.
- [x] 6.3 Implement the simulation core over `applyMatcherRule` with fresh budgets, the whole 16 MiB fanout limit with baseline routes, the active-snapshot route baseline, and hints only from simulated `classify`. Verify: 6.2 tests pass and flip green.
- [x] 6.4 Write failing `db` tests in `correlia_server/test/db/rule_simulator_test.dart` and `rule_simulator_rpc_test.dart` for the stored-event, member-selection, parity, stored-diagnostic, route-baseline, draft and no-side-effect scenarios, including the session-log check through the real RPC endpoint. Verify: they fail because the endpoint does not exist.
- [x] 6.5 Implement `RuleSimulatorEndpoint.simulate` (`logSessions => false`, console access policy, one read-only transaction, D9 lookup and member choice, D12 decode). Verify: 6.4 tests pass and flip green; `mise run test -- --tags db` passes.
- [x] 6.6 Add executable rule-priority, label and topology examples and sections on the simulator and classification to `docs/ingest-pipeline.md`; write `correlia_server/test/unit/simulator/rul1_docs_test.dart` that parses the documented examples and checks each simulated decision against the documented one. Verify: the test fails before the examples exist, then passes and flips RUL-1 green.

## 7. Simulator command line (D11)

- [x] 7.1 Write failing tests: `correlia_server/test/unit/tool/simulate_cli_test.dart` for output, timestamp passthrough and error exit codes, and `correlia_server/test/db/simulate_cli_test.dart` for tracing a stored event against a running test server. Verify: they fail because the tool does not exist.
- [x] 7.2 Implement `correlia_server/tool/simulate.dart` (readable and `--json` output, non-zero exit on errors) and document its use in `docs/ingest-pipeline.md`. Verify: 7.1 tests pass and flip green.

## 8. Carried constraints

- [x] 8.1 Check that each spec-destination constraint is stated at its destination: C4 (event-classification → Noise class hints), C4b (rule-simulator → Simulate one event against active or draft rules), C4c (rule-simulator → Hints come only from simulated classify), C5 (event-classification → Decoder-owned event kind), C8 (rule-simulator → Simulation results match the pipeline), C8b (rule-simulator → Simulated fanout bound), C9 (matcher-rules → Short-circuit evaluation is preserved), C11 (durable-pipeline → The earliest same-ID member of a batch is the candidate). Verify: each requirement's text carries its fact; fix any gap in the delta and rerun `mise exec -- openspec validate rule-simulator-and-classification --strict`.

## 9. Integration

- [ ] 9.1 Run `mise run check` and `mise run test:all`. Verify: both pass and every test-map row is green.
