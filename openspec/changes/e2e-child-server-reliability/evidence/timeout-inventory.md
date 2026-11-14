# Existing child-server test timeout inventory

D1 budgets one 30-second shutdown per sequential child plus 60 seconds for test work: `60s + Σ(readiness + 30s)`. Children started together count as one stage. All times below are seconds; old and new are the per-test timeouts, not individual future deadlines. `implicit` means no per-test timeout was declared. The default child readiness deadline is 60s, including children expected to fail before readiness. This inventory covers existing tests, not the group 3 harness tests.

The child counts include starts via `startOutputChild` in `output_process.dart`, `NatsProcessFixture.startChild` in `nats_process.dart`, and `interrupted_harness.dart`. They do not count NATS, plugin, subscriber, or harness processes as child servers. For interrupted runs the harness separately waits up to 90s for its child line; the child itself still has the default 60s readiness deadline. In root handoff the middle child has a custom 1s readiness/root-lock deadline, although the test separately allows 60s for its exit.

| File under `correlia_server/test/` | Test | Sequential child stages | Readiness per stage (s) | Budget (s) | Old (s) | New (s) |
|---|---|---:|---|---:|---:|---:|
| db/kill_recovery_test.dart | after SIGKILL the next run in the same root passes and leaves no postmaster | 2 | 60, 60 | 240 | 240 | 240 |
| e2e/cluster_roots_e2e_test.dart | each cluster has its own stable root, deleted after its server stopped | 1 (2 together) | 60 | 150 | 240 | 240 |
| e2e/health_e2e_test.dart | livez readyz startupz answer 200 in each role | 1 (3 together) | 60 | 150 | 240 | 240 |
| e2e/health_e2e_test.dart | readyz 503 and livez 200 when the database stops | 1 | 60 | 150 | 240 | 240 |
| e2e/ingest_bootstrap_e2e_test.dart | malformed_secret_or_credential_bearing_input_is_not_echoed | 4 (loop) | 60 × 4 | 420 | 180 | 420 |
| e2e/ingress_e2e_test.dart | authenticated_source_delivery | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | sec_1_another_source_token | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | sec_5_path_token_redaction | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | conflicting_credentials | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | accepted_body_above_endpoint_default | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | chunked_oversized_delivery | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | concurrent_http_retries_and_conflict | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | remote_publication_rekeys_ingress | 1 | 60 | 150 | implicit | 180 |
| e2e/ingress_e2e_test.dart | unconfigured_ingress_still_protects_token_paths | 1 | 60 | 150 | implicit | 180 |
| e2e/interrupted_run_e2e_test.dart | killing only the harness twice leaves no child, no cluster process, no extra root, and leaves an outside decoy untouched | 3 (2 hold, 1 complete) | 60 × 3 | 330 | 360 | 360 |
| e2e/live_feed_e2e_test.dart | local_development_access | 1 | 60 | 150 | 180 | 180 |
| e2e/live_feed_e2e_test.dart | stream_dropped_and_resumed | 1 | 60 | 150 | 180 | 180 |
| e2e/live_feed_e2e_test.dart | worker_role_refuses | 1 | 60 | 150 | 180 | 180 |
| e2e/nats_burst_e2e_test.dart | Kill -9 during a 1,000-alert burst | 3 | 60 × 3 | 330 | 300 | 360 |
| e2e/nats_burst_e2e_test.dart | worker_killed_before_any_delivery | 3 | 60 × 3 | 330 | 180 | 360 |
| e2e/nats_burst_e2e_test.dart | worker_killed_status_goes_stale | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/nats_burst_e2e_test.dart | nats_plugin_exits_after_host_sigkill | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/nats_demo_e2e_test.dart | Alertmanager fixture reaches the feed and natsdev subscriber | 1 | 60 | 150 | 180 | 180 |
| e2e/nats_dur3_e2e_test.dart | DUR-3 redelivery after the acknowledgement was lost | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/nats_dur8_e2e_test.dart | DUR-8 plugin crashes mid-stream | 1 | 60 | 150 | 240 | 240 |
| e2e/nats_dur8_e2e_test.dart | DUR-8 crash budget exceeded | 2 | 60, 60 | 240 | 300 | 300 |
| e2e/nats_pinning_e2e_test.dart | nats_server_changed_with_work_pending | 3 | 60 × 3 | 330 | 240 | 360 |
| e2e/nats_shutdown_e2e_test.dart | graceful_worker_stop | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/output_delivery_e2e_test.dart | receiver_verifies_signed_event | 1 | 60 | 150 | 180 | 180 |
| e2e/output_delivery_e2e_test.dart | redirect_timeout_and_rejection | 1 | 60 | 150 | 180 | 180 |
| e2e/output_delivery_e2e_test.dart | one_output_fails_while_another_succeeds | 1 | 60 | 150 | 240 | 240 |
| e2e/output_delivery_e2e_test.dart | loaded_historical_signing_reference | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/output_recovery_e2e_test.dart | dur_2_restart_after_processing_commit | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/output_recovery_e2e_test.dart | dur_3_acknowledgement_lost_before_local_commit | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/pipeline_lifecycle_e2e_test.dart | split_roles_and_restart | 3 | 60 × 3 | 330 | 180 | 360 |
| e2e/pipeline_lifecycle_e2e_test.dart | missing_config_with_durable_work | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/pipeline_lifecycle_e2e_test.dart | missing_worker_config_after_drained_queue | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/pipeline_lifecycle_e2e_test.dart | shutdown_during_processing | 1 | 60 | 150 | 180 | 180 |
| e2e/pipeline_recovery_e2e_test.dart | pin_survives_crash_and_activation | 2 | 60, 60 | 240 | 180 | 240 |
| e2e/roles_e2e_test.dart | worker role is logged as worker | 1 | 60 | 150 | 180 | 180 |
| e2e/roles_e2e_test.dart | no role runs as all and logs all | 1 | 60 | 150 | 180 | 180 |
| e2e/roles_e2e_test.dart | unknown role exits non-zero before any listener or cluster | 1 | 60 | 150 | 180 | 180 |
| e2e/roles_e2e_test.dart | unrecognised option exits non-zero naming it | 1 | 60 | 150 | 180 | 180 |
| e2e/roles_e2e_test.dart | api role serves the console | 1 | 60 | 150 | 180 | 180 |
| e2e/roles_e2e_test.dart | worker role answers 404 for the console | 1 | 60 | 150 | 180 | 180 |
| e2e/root_handoff_e2e_test.dart | a replacement waits for the root lock, then starts; at its deadline fails naming the root | 3 | 60, 1, 60 | 271 | 300 | 300 |
| e2e/shutdown_e2e_test.dart | SIGTERM stops subsystems before the pool closes and exits 0 | 1 | 60 | 150 | 180 | 180 |

The e2e-tagged `output_delivery_e2e_test.dart` test `bounded_response_and_total_deadline` does not start a child, but also lacked a direct timeout. It now declares 180s for the D1 presence check; it is not a child-budget row.

## Verification

- Arithmetic check: all 47 rows have new timeout ≥ budget.
- `mise run analyze`: no issues in the Dart workspace or Flutter console.
- `mise exec -- dart test` in `tool/`: all 83 tests passed, including the timeout guard.
- `mise run test -- --tags e2e` selecting the ten raised files: all 29 tests passed, 428.27s wall time.
- No database-tier timeout needed raising; `kill_recovery_test.dart` already budgets 240s for two children.
