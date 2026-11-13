# Final gate runs

2026-11-13, branch `feat/plugin-health-timeout-classification`. Both runs use the final implementation, including the owner-approved closed-transport write fix. No code changes occurred between these runs and the group commits.

## mise run check

Exit 0. Spec validation: 15 passed, 0 failed. Dart and Flutter analysis: no issues. Formatting: 259 files, 0 changed. Generated-code verification passed.

| Test set | Passed | Failed |
|---|---:|---:|
| Server fast | 208 | 0 |
| Tool | 72 | 0 |
| Flutter widget | 19 | 0 |
| Total | 299 | 0 |

Result lines:

```text
[check] Totals: 15 passed, 0 failed (15 items)
[check] No issues found!
[check] No issues found! (ran in 2.1s)
[check] Formatted 259 files (0 changed) in 0.77 seconds.
[check] 00:05 +208: All tests passed!
[check] 02:13 +72: All tests passed!
[check] 00:01 +19: All tests passed!
[check] Finished in 254.77s
Finished in 255.70s
```

## mise run test:all — final gate without concurrent stress

Exit 0: **449 passed, 0 failed** (every server tier except load).

```text
08:57 +449: All tests passed!
Finished in 541.19s
```

The earlier all-tier run concurrent with the ten protocol repetitions and `check` failed 448/449 on the unrelated `ingress_e2e_test.dart: conflicting_credentials` 30-second timeout. That failure is retained in `protocol-load-runs.md`, not erased by the passing gate. The owner explicitly selected a normal-load final gate without modifying that test. Its failure cause remains unestablished; no unrelated test or timeout was changed, no automatic retry was added.

The protocol repetitions themselves passed 130/130. See `protocol-load-runs.md` for per-test counts and the deterministic transport red/green proof.
