# Tasks

Planned 2026-11-12 after design review round 3 (codex): `VERDICT: APPROVE_WITH_CHANGES`, `CHANGES_APPLIED: yes`.

Rules for every implementer:
- Follow the "Dart and Flutter code" section of `AGENTS.md` and load the skills it names for the group:
  - server groups: `serverpod-overview`, `serverpod-models`, `serverpod-database`, `serverpod-migrations`,
    `serverpod-testing`, `serverpod-endpoints`, `serverpod-streams`;
  - the console group: `serverpod-flutter-frontend`, `flutter-apply-architecture-best-practices`,
    `flutter-add-widget-test`;
  - always: `dart-use-pattern-matching`, `dart-write-documentation`, `dart-run-static-analysis`.
- Run the toolchain only through mise.
- Concurrency tests use `rollbackDatabase: RollbackDatabase.disabled` with independent sessions and clean
  their own rows, as in `test/db/pipeline_test.dart`.
- Never sleep: use completers, injected clocks and short injected intervals.

## Test map

Paths are relative to `correlia_server/` unless they start with `correlia_flutter/`.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| alert-state → Authoritative alert state per fingerprint | First firing observation creates a firing alert | test/db/alert_state_test.dart | first_firing_observation_creates_firing_alert | green |
| alert-state → Authoritative alert state per fingerprint | First observation is a recovery | test/db/alert_state_test.dart | first_observation_is_a_recovery | green |
| alert-state → Authoritative alert state per fingerprint | Concurrent first observations of one fingerprint | test/db/alert_state_test.dart | concurrent_first_observations_of_one_fingerprint | green |
| alert-state → Ordering fence decides state changes | ORD-1 delayed recovery does not clear a newer problem | test/unit/state/transition_test.dart; test/db/alert_state_test.dart | ord_1_delayed_recovery_does_not_clear_newer_problem | green |
| alert-state → Ordering fence decides state changes | ORD-2 stale problem does not resurrect a resolved alert | test/unit/state/transition_test.dart; test/db/alert_state_test.dart | ord_2_stale_problem_does_not_resurrect_resolved_alert | green |
| alert-state → Ordering fence decides state changes | Source clock ahead within the future limit | test/unit/state/ordering_key_test.dart; test/db/alert_state_test.dart | source_clock_ahead_within_future_limit | green |
| alert-state → State converges in any processing order | ORD-3 equal source times are ordered deterministically | test/unit/state/transition_test.dart; test/db/alert_state_test.dart | ord_3_equal_source_times_ordered_deterministically | green |
| alert-state → State converges in any processing order | Source times less than a microsecond apart | test/db/alert_state_test.dart | source_times_less_than_a_microsecond_apart | green |
| alert-state → Applied observations update state in place | ID-7c severity changes in place | test/db/alert_state_test.dart | id_7c_severity_changes_in_place | green |
| alert-state → Applied observations update state in place | ID-7b severity-labelled alerts are separate | test/db/alert_state_test.dart | id_7b_severity_labelled_alerts_are_separate | green |
| alert-state → Applied observations update state in place | Newer repeat with no visible change | test/unit/state/transition_test.dart | newer_repeat_with_no_visible_change | green |
| alert-state → Last observed time advances monotonically | Stale observation with a later observed time | test/db/alert_state_test.dart | stale_observation_with_later_observed_time | green |
| alert-state → Last observed time advances monotonically | Older observed time never moves it backwards | test/db/alert_state_test.dart | older_observed_time_never_moves_it_backwards | green |
| alert-state → Last observed time advances monotonically | Late observation advances nothing | test/db/alert_state_test.dart | late_observation_advances_nothing | green |
| alert-state → Single writer for alert state | Effect counts per raw row | test/db/alert_state_test.dart | effect_counts_per_raw_row | green |
| alert-state → Single writer for alert state | Opposite fingerprint order in concurrent deliveries | test/db/alert_state_test.dart | opposite_fingerprint_order_in_concurrent_deliveries | green |
| alert-state → Single writer for alert state | Informational observation | test/unit/state/transition_test.dart; test/db/alert_state_test.dart | informational_observation; informational_duplicates_leave_existing_state_unchanged | green |
| change-feed → Append-only activity ledger | Firing then resolved writes two entries | test/db/activity_ledger_test.dart | firing_then_resolved_writes_two_entries | green |
| change-feed → Append-only activity ledger | Rolled-back change leaves no entry | test/db/activity_ledger_test.dart | rolled_back_change_leaves_no_entry | green |
| change-feed → Feed reads only below the watermark | UI-3a a late-committing transaction is never skipped | test/db/change_feed_test.dart | ui_3a_late_committing_transaction_never_skipped | green |
| change-feed → Feed reads only below the watermark | Page limit | test/db/change_feed_test.dart | page_limit | green |
| change-feed → Opaque feed cursors | Malformed cursor | test/unit/feed/feed_cursor_test.dart; test/db/change_feed_test.dart | malformed_cursor | green |
| change-feed → Opaque feed cursors | Snapshot cursor on an empty ledger | test/db/change_feed_test.dart | snapshot_cursor_on_empty_ledger | green |
| change-feed → Snapshot and feed handover | Change committed during the snapshot | test/db/change_feed_test.dart | change_committed_during_snapshot | green |
| change-feed → Snapshot and feed handover | Repeated change in snapshot and feed | test/db/change_feed_test.dart | repeated_change_in_snapshot_and_feed | green |
| change-feed → Wake-up stream liveness | UI-3b blocker without activity | test/db/feed_watermark_test.dart | ui_3b_blocker_without_activity | green |
| change-feed → Wake-up stream liveness | Stream dropped and resumed | test/e2e/live_feed_e2e_test.dart | stream_dropped_and_resumed | green |
| durable-pipeline → Atomic raw processing outcome | DUR-1 outbox failure rolls back event work | test/db/pipeline_test.dart | dur_1_outbox_failure_rolls_back_event_work | green |
| durable-pipeline → Atomic raw processing outcome | Invalid member after valid member | test/db/pipeline_test.dart | invalid_member_after_valid_member | green |
| durable-pipeline → Atomic raw processing outcome | Processing budget exhaustion | test/db/pipeline_test.dart | processing_budget_exhaustion | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5b rebatching and expired transport window | test/db/pipeline_test.dart | ord_5b_rebatching_and_expired_transport_window | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5c retry of firing after a recovery | test/db/alert_state_test.dart | ord_5c_retry_of_firing_after_recovery | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5d retry after the observation key expired | test/db/alert_state_test.dart | ord_5d_retry_after_observation_key_expired | green |
| durable-pipeline → Durable observation deduplication and quarantine | ORD-5f generic retry without a native id | test/db/alert_state_test.dart | ord_5f_retry_without_native_id | green |
| durable-pipeline → Durable observation deduplication and quarantine | Duplicate of a late observation | test/db/alert_state_test.dart | duplicate_of_late_observation | green |
| durable-pipeline → Durable observation deduplication and quarantine | Future quarantine does not poison dedup | test/db/pipeline_test.dart | future_quarantine_does_not_poison_dedup | green |
| durable-pipeline → Durable observation deduplication and quarantine | Late observation evidence | test/db/pipeline_test.dart | late_observation_evidence | green |
| operator-console → Live alert list | New alert appears live | correlia_flutter/test/alert_list_page_test.dart | new_alert_appears_live | green |
| operator-console → Live alert list | Resolved alert leaves the list | correlia_flutter/test/alert_list_page_test.dart | resolved_alert_leaves_the_list | green |
| operator-console → Live alert list | Wake-up stream silent | correlia_flutter/test/alert_feed_controller_test.dart | wake_up_stream_silent | green |
| operator-console → Responses applied in order by version | Older version arrives after a newer one | correlia_flutter/test/alert_feed_controller_test.dart | older_version_after_newer_one | green |
| operator-console → Responses applied in order by version | Delayed older response after a resolution | correlia_flutter/test/alert_feed_controller_test.dart | delayed_older_response_after_resolution | green |
| operator-console → Bounded partial snapshot | Snapshot bound exceeded | test/db/change_feed_test.dart; correlia_flutter/test/alert_list_page_test.dart; correlia_flutter/test/alert_feed_controller_test.dart | snapshot_bound_exceeded; unknown_firing_times_sort_last_without_using_freshness | green |
| operator-console → Bounded partial snapshot | Complete list grows past the limit | correlia_flutter/test/alert_feed_controller_test.dart; correlia_flutter/test/alert_list_page_test.dart | complete_list_grows_past_limit; growing_list_does_not_claim_zero_omitted_alerts | green |
| operator-console → Bounded partial snapshot | Partial list refills after a resolution | correlia_flutter/test/alert_feed_controller_test.dart | partial_list_refills_after_resolution | green |
| operator-console → Connection loss is visible and recovered | Server restart | correlia_flutter/test/alert_list_page_test.dart; test/db/feed_watermark_test.dart | server_restart_shows_disconnected_then_resumes; subscription_before_start_receives_readable_activity | green |
| operator-console → Connection loss is visible and recovered | Rejected cursor | correlia_flutter/test/alert_feed_controller_test.dart | rejected_cursor_takes_new_snapshot | green |
| operator-console → Development-only unauthenticated read access | Local development access | test/e2e/live_feed_e2e_test.dart | local_development_access | green |
| operator-console → Development-only unauthenticated read access | Production mode refuses | test/unit/console/console_access_policy_test.dart | production_mode_refuses | green |
| operator-console → Development-only unauthenticated read access | Non-loopback peer refuses | test/unit/console/console_access_policy_test.dart | non_loopback_peer_refuses | green |
| operator-console → Development-only unauthenticated read access | Worker role refuses | test/e2e/live_feed_e2e_test.dart | worker_role_refuses | green |
| operator-console → Console usability baseline | Filter narrows the list | correlia_flutter/test/alert_list_page_test.dart | filter_narrows_the_list | green |
| operator-console → Console usability baseline | Filter matches nothing | correlia_flutter/test/alert_list_page_test.dart | filter_matches_nothing | green |
| operator-console → Console usability baseline | Generator link and selectable text | correlia_flutter/test/alert_list_page_test.dart | generator_link_and_selectable_text | green |

## 1. Alert table, activity ledger and schema step

- [x] 1.1 Add `lib/src/models/alert.spy.yaml` (`serverOnly`, table `alerts`) with D1's columns:
  - the fence as seconds plus nanos;
  - `generatorUrl`;
  - a unique index on (`tenant`, `fingerprint`).

  Run `mise run generate` and create the managed migration with the Serverpod tooling, never by hand.
  Verify that `mise run check`'s generated-code step passes and that the migration registry lists it.
- [x] 1.2 Extend `test/db/schema_step_test.dart` first, so that it fails. It must assert:
  - `activity`'s columns, including `txid xid8` with default `pg_current_xact_id()`;
  - the `(txid, id)` index;
  - `events.state_outcome` and its CHECK;
  - that these hold on both the fresh path and the populated version-1 upgrade path;
  - that the generated `definition*.json` files do not contain `activity`.

  Then add `schema/0002_activity.sql` and register `SchemaStep(2, …)` in `lib/src/schema/schema_steps.dart`.
  Verify that the test passes.
- [x] 1.3 Update `openspec/architecture.md`, Database:
  - `activity` is created by schema step 0002, no longer future work;
  - `events.state_outcome` is noted;
  - `alerts` is a managed table.

  Update `docs/ingest-pipeline.md`'s repair-migration list to include `activity`. Verify that
  `mise exec -- openspec validate --all --strict` passes.

## 2. Pure ordering and transition logic

- [x] 2.1 Write failing unit tests in `test/unit/state/ordering_key_test.dart` and
  `test/unit/state/transition_test.dart` for these rows:
  - ORD-1, ORD-2 and ORD-3, in both processing orders;
  - source_clock_ahead_within_future_limit;
  - newer_repeat_with_no_visible_change;
  - informational_observation.

  Also cover:
  - comparison at nanosecond precision;
  - the effective-time clamp with the 5-minute skew;
  - each `TransitionResult` case and its activity kind (`created`, `resolved`, `refired`,
    `severity_changed`, `display_changed`).

  Verify that they fail because the library is missing.
- [x] 2.2 Implement `lib/src/state/ordering_key.dart` and `lib/src/state/transition.dart`, D4's sealed
  pure types and the injectable skew constant (D5). Verify that the 2.1 tests pass under `mise run test`,
  then flip their rows green (the db halves of ORD-1/2/3 stay red until group 3).

## 3. State mutation in the pipeline transaction

- [x] 3.1 Restructure `PipelineRepository.processOne` into D3's three phases (keys, state placeholder,
  effects) with no state writes yet. Verify that every existing test in `test/db/pipeline_test.dart`,
  `test/db/pipeline_routing_test.dart`, `test/db/transport_dedup_test.dart` and the pipeline e2e tests
  still passes unchanged (`mise run test -- --tags db`, then `-- --tags e2e`).
- [x] 3.2 Write failing db tests in `test/db/alert_state_test.dart` and
  `test/db/activity_ledger_test.dart` for every `alert_state_test` and `activity_ledger_test` row of the
  test map. Drive them through `processOne` with Alertmanager fixtures and injected clocks.
  - **ORD-5d** deletes the observation key, as the M2 retention job will.
  - **The concurrent rows** use two independent sessions coordinated by completers.

  Extend these existing tests in `test/db/pipeline_test.dart` to assert alert state and activity:
  - dur_1_outbox_failure_rolls_back_event_work;
  - invalid_member_after_valid_member;
  - future_quarantine_does_not_poison_dedup;
  - late_observation_evidence.

  Verify that the new assertions fail.
- [x] 3.3 Implement `lib/src/state/alert_state_service.dart`:
  - D3's phase 2: locks in fingerprint order, ensuring each row with `INSERT … ON CONFLICT DO NOTHING`
    and then `SELECT … FOR UPDATE`;
  - `decideTransition`;
  - the alert update with `GREATEST(lastObservedAt)`;
  - activity inserts (actor `pipeline`, with the cause event and raw ids);
  - the duplicate-of-ready advance, reading the original key's disposition.

  Wire it into phase 2. Write `events.state_outcome` in phase 3 and add `applied` and `stale` to
  `outcome_json` (D10). Verify that every group-3 row and the existing pipeline tests pass, then flip
  those rows green.
- [x] 3.4 Document the alert state model in `docs/ingest-pipeline.md`:
  - fence, stale, `last_observed_at`;
  - the outcome counts;
  - the lock order.

  Verify by review against design D3 and D10.

## 4. Change feed, endpoint, guard and wake-ups

- [x] 4.1 Write failing unit tests:
  - `test/unit/feed/feed_cursor_test.dart`: the codec, round trip, malformed inputs and 64-bit values;
  - `test/unit/console/console_access_policy_test.dart`: production_mode_refuses and
    non_loopback_peer_refuses, using real Relic `Request`s with `ConnectionInfo`. Also cover:
    - a forged `X-Forwarded-For: 127.0.0.1` from a non-loopback peer;
    - a non-loopback `Host`;
    - a foreign `Origin`;
    - the worker role;
    - a `null` request;
    - the allowed development, test and loopback case.

  Verify that they fail.
- [x] 4.2 Implement `lib/src/feed/feed_cursor.dart` and `lib/src/console/console_access_policy.dart`
  (D6, D8). Verify that the 4.1 tests pass, then flip production_mode_refuses and non_loopback_peer_refuses
  green.
- [x] 4.3 Write failing db tests in `test/db/change_feed_test.dart` for the change_feed rows of the test
  map, calling the feed service directly with two independent sessions:
  - ui_3a;
  - page_limit;
  - malformed_cursor;
  - snapshot_cursor_on_empty_ledger;
  - change_committed_during_snapshot;
  - repeated_change_in_snapshot_and_feed;
  - the server half of snapshot_bound_exceeded: 501 firing gives 500 plus `omittedCount` 1, in severity
    order.

  Write a failing test in `test/db/feed_watermark_test.dart` for ui_3b_blocker_without_activity, with an
  injected short poll interval. Verify that they fail.
- [x] 4.4 Implement:
  - `lib/src/feed/feed_reader.dart`: a snapshot in REPEATABLE READ and feed pages below
    `pg_snapshot_xmin`, with `heldBack`, `more` and current `AlertView` rows;
  - client-visible models `AlertView`, `AlertSnapshot`, `FeedEntry`, `FeedPage`, `FeedWakeUp`;
  - serializable exceptions `InvalidCursorException` and `ConsoleAccessDeniedException`;
  - `lib/src/endpoints/alert_console_endpoint.dart` with `snapshot`, `feed` and the `wakeUps` stream,
    each guarded;
  - `FeedWatermarkSubsystem` (roles api and all), registered so that it stops before the database
    closes, with the held-back log warning after 30 s.

  Run `mise run generate`. Verify that the 4.3 tests pass, then flip their rows green.
- [x] 4.5 Write `test/e2e/live_feed_e2e_test.dart` against a `ChildServer` in run mode `test`, using the
  generated Dart client over real HTTP and WebSocket:
  - local_development_access: POST an Alertmanager webhook, receive a wake-up, and find the alert in the
    feed;
  - stream_dropped_and_resumed;
  - worker_role_refuses.

  Verify that it passes under `mise run test -- --tags e2e`, then flip these rows green.
- [x] 4.6 Document the feed contract and the development-only console exposure in
  `docs/console-feed.md`:
  - cursor, watermark, `heldBack`, wake-ups;
  - the guard's rules, and that it is not for production until M4.

  Verify by review against D6-D8.

## 5. Flutter console alert list

- [x] 5.1 Add `url_launcher` to `correlia_flutter/pubspec.yaml` through mise (`mise exec -- flutter pub
  add url_launcher`). Verify that `mise run analyze` passes.
- [x] 5.2 Write failing tests:
  - `correlia_flutter/test/alert_feed_controller_test.dart`: every `alert_feed_controller_test` row,
    with a fake `ConsoleApi`, fake wake-up stream controllers, an injected clock and a fake timer
    factory;
  - `correlia_flutter/test/alert_list_page_test.dart`: every `alert_list_page_test` row, including the
    partial indicator for snapshot_bound_exceeded, and server_restart driving the fake API down and up
    while asserting the disconnected banner, kept rows and resume.

  Remove `placeholder_page_test.dart` together with the placeholder. Verify that they fail.
- [x] 5.3 Implement:
  - `correlia_flutter/lib/src/console_api.dart`: the interface and the generated-client adapter;
  - `alert_feed_controller.dart`: D9's single flight, generations, tombstones (10,000 cap), partial
    reconciliation including from a complete start, and backoff of 1, 2, 4, then a 10 s cap;
  - `alert_list_page.dart`: `SelectionArea`, row `Semantics`, the filter, generator `Link`, the
    partial and disconnected indicators, and the "no alerts match" state.

  `main.dart` calls `initializeClient()` and shows the page. Verify that the 5.2 tests pass under
  `mise run test` and the widget-test task, then flip their rows green.

## 6. Integration

- [x] 6.1 Run `mise run check` and `mise run test:all`. Both must pass from a clean state. Then run
  `mise run build:web` and confirm that the api role serves the built console.
- [x] 6.2 [evidence] Capture the command lines and summarized results of 6.1 (test counts per tier, and the check gate's steps) → evidence/test-run.md
