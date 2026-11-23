# Review

## Metadata

- **Round:** 10
- **Prior round:** round 9 (omp) REVISE: 2 Critical (old API publishers during cutover; curl proxy/config inheritance), 3 Moderate (step-4 lock wait; microsecond preservation and three-gate no-release scenario; late duplicate freshness).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, all four spec deltas, and round 9; baseline source-ingress, durable-pipeline, alert-state, and canonical-event specs; project rules, M2 roadmap, named acceptance scenarios, architecture, and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert model, and protobuf sources; historical snapshot test; archived Alertmanager D6 and capture script; upstream Icinga 2 source and curl, OpenSSL, and Linux documentation. Read-only review; no tests or captures run.

## Findings

### Critical (blocking)

1. **The sender still inherits TLS settings that can expose credentials.** D3 (`design.md:117–125`) disables `.curlrc` and bypasses proxies on loopback, but those flags do not control curl’s TLS environment. Curl’s [environment documentation](https://curl.se/docs/manpage.html#ENVIRONMENT) says `CURL_CA_BUNDLE`, `SSL_CERT_FILE`, and `SSL_CERT_DIR` can change which certificates are trusted, and `SSLKEYLOGFILE` writes TLS session secrets on supported backends, including OpenSSL. The proposed test can pass while the deployed sender trusts an unintended CA or writes keys that make a bearer-authenticated request decryptable. Give the sender an explicit trust policy—system roots or `CORRELIA_CA_FILE`—and suppress inherited TLS key logging. Test both with inherited settings.
2. **The file-based credential design leaves child-process arguments unprotected.** D3 (`design.md:107–125`) specifies shell, curl, and OpenSSL but safeguards only script output. OpenSSL 3.0’s documented HMAC key options take the key as an argument; curl also accepts an expanded bearer header as an argument. An implementation using those paths passes the proposed log test while putting reusable credentials in [Linux process command lines](https://man7.org/linux/man-pages/man5/proc_pid_cmdline.5.html) and potentially process-execution audit logs. Require both auth modes to keep reusable secrets out of child arguments and exported environment. Choose a signing path that reads the key from a file or descriptor, and verify the boundary with synthetic credentials.

### Moderate

1. **The sender treats a response that does not acknowledge admission as success.** D3 (`design.md:123–126`) fails on non-2xx, but source ingress defines **202** as the durable acknowledgment (`openspec/specs/source-ingress/spec.md`, “Bounded durable admission”; `docs/ingest-pipeline.md:140–152`). A misrouted webhook answered by a reverse proxy with a 200 page exits successfully even though Correlia has no raw row. Icinga 2 then neither logs a command failure nor retries. Require exactly 202 and add a 200-with-no-admission scenario.
2. **The release matrix can still qualify a millisecond-only production notification clock.** The exact-value scenario replaces the notification-time function (`integration-icinga2/spec.md:109–111`), while release qualification requires only three same-second captures (`:290–294`, `:312–314`). A production function truncated to milliseconds can pass the two-comment gate with distinct millisecond values, and the replacement function can pass the exact-value scenario. It will still collapse two same-author executions in a millisecond even when they occurred at distinct microseconds. Qualify both shipped commands against exact microsecond evidence without replacing the production time conversion, and make that proof an explicit release gate.
3. **Step 4 bounds the DDL wait, not entry into the schema runner, and the current error path erases the failure class.** `schema_steps.dart:39–54,60–83` takes a blocking advisory lock before reading or executing the SQL file, then converts every failure to an exception that names only the step (`:18–27`). `SET LOCAL lock_timeout` in step 4 cannot bound an upgraded starter waiting behind a stalled schema transaction, and by itself cannot produce the promised lock-wait diagnostic. Bound acquisition before both advisory-lock calls and preserve a sanitized lock-timeout class in startup output. Test the advisory-lock wait separately from the existing `events`-lock rollback and restart scenario.
4. **The Icinga2 capacity model omits an admission limit that can drop an ordinary signed burst.** The resource table describes 429 at the configured source rate, but `ingress.dart:179–187` returns 503 when a third HMAC request for one UUID overlaps the first two, before checking that rate budget. Icinga 2 runs notifications independently and the sender intentionally does not retry. Three simultaneous host or service changes can therefore lose a recovery even with ample rate budget and a healthy database. Document the concurrent-request cap and the permanent loss behavior in the Icinga2 setup; prove the 503 is visible as a command failure. This does not require raising the cap or adding retries.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Prevent inherited TLS trust overrides and session-key logging; verify the sender with those environment settings present.
2. Specify and verify a bearer and HMAC execution path that keeps reusable credentials out of child arguments and exported environment.
3. Treat only HTTP 202 as accepted delivery; assert that an unrelated 200 produces a command failure.
4. Make exact microsecond preservation on the production timestamp paths a per-release qualification criterion and align the no-release case with it.
5. Bound schema advisory-lock acquisition and preserve a sanitized lock-timeout diagnostic; verify failure and restart for advisory and table lock contention.
6. Document and exercise the HMAC concurrency rejection in the no-retry sender setup.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 9 C1 — old API publishers:** Resolved in design. D6 stops all old roles and adds a database fence against an old publisher’s kind-changing upsert. The fence is not mixed-version worker support, and D6 explicitly forbids restarting old workers.
- **Round 9 C2 — curl proxy/config inheritance:** Resolved for the reported proxy, `.curlrc`, and redirect paths. Inherited TLS trust and key logging remain open in Critical 1.
- **Round 9 M1 — step-4 lock wait:** The `events` DDL wait, rollback, and restart now have a scenario. Advisory-lock acquisition and the promised failure classification remain open in Moderate 3.
- **Round 9 M2 — timestamp precision:** “No release passes” now names all three same-second gates, and the passive-result test checks exact values. The production notification-time path still has the gap in Moderate 2.
- **Round 9 M3 — late duplicate freshness:** Resolved in design. The duplicate itself must be ready as well as its original; the late-duplicate and prompt-first reminder scenarios assert unchanged `last_observed_at`.