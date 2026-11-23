# Review

## Metadata

- **Round:** 11
- **Prior round:** round 10 (omp) REVISE: 2 Critical (inherited TLS trust/key logging; credentials in child argv), 4 Moderate (202-only success; production notification clock gate; advisory-lock bound and failure class; HMAC concurrency 503).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas, and round 10; baseline source-ingress, durable-pipeline, alert-state, and canonical-event specs; project rules, M2 roadmap, named acceptance scenarios, architecture, and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert model, and event protobuf sources; archived Alertmanager D6 and capture script; upstream Icinga 2 macro resolution and curl 7.55.0 TLS source. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **A configured private CA does not replace curl’s default CA directory.** D3 (`design.md:119–125`) and “Sender transport and diagnostics” promise system roots **or** `CORRELIA_CA_FILE`. At the supported curl floor, [libcurl initializes `CApath` from the build’s `CURL_CA_PATH`](https://github.com/curl/curl/blob/curl-7_55_0/lib/url.c#L598-L605), [`--cacert` sets `CAINFO` without clearing `CApath`](https://github.com/curl/curl/blob/curl-7_55_0/src/tool_operate.c#L1097-L1102), and [the OpenSSL backend loads both](https://github.com/curl/curl/blob/curl-7_55_0/lib/vtls/openssl.c#L2132-L2141). On such a build, an endpoint trusted only by the default directory can still receive credentials in private-CA mode. The inherited-settings scenario never exercises that mode. Specify how the sender excludes default trust when a CA file is configured, and test both a system-only certificate being rejected and a configured-CA certificate being accepted. On the successful connection, also assert that an inherited `SSLKEYLOGFILE` produces no file; a rejected connection alone does not prove that.

### Moderate

1. **The production clock gate still does not establish microsecond preservation.** “Production notification clock keeps microseconds” (`integration-icinga2/spec.md:133–136`) passes a clock rounded to 10 or 100 µs: such values can be nonmultiples of 1000, and decoding them exactly only proves preservation *after* the loss. The exact-value scenario replaces the function that could introduce the loss. A release can pass all four gates and still merge same-author executions that occurred at distinct microseconds. Qualify both commands against independently known microsecond inputs through the unchanged production conversion and serialization path.
2. **D3 still gives contradictory exit rules for non-202 success statuses.** `design.md:134–140` first says only 202 is delivered, then specifies exit 1 only for a non-2xx response. Following the latter leaves a 200 or 204 delivery with curl’s successful exit code, so Icinga 2 reports no failure for work Correlia never accepted. The spec and its 200 scenario are correct; make D3 say exit 1 for **every** HTTP status other than 202 when curl itself succeeded.
3. **Timestamp conversion has no defined finite or representable range.** D2 (`design.md:83–86`) rounds numeric Unix seconds to integer microseconds, and the evidence requirement rejects missing and non-positive times. A positive JSON number such as `1e300` passes that check, but multiplying it by one million produces infinity before rounding. The pipeline’s decode handler catches `EventValidationError`, not a numeric conversion exception (`pipeline.dart:328–355`), so a direct implementation sends authenticated malformed input through internal retries instead of recording a field failure. Validate the range before conversion, reject values that round to zero or fall outside the canonical timestamp domain, and assert that invalid values in either timestamp field fail without a retry or committed effects.
4. **Step 4 crosses the documented schema ownership boundary.** D6 (`design.md:240–242`) installs a trigger on `ingest_source`, which is Serverpod-managed (`ingest_source.spy.yaml`; the source-secrets managed migration adds `kind`). `openspec/architecture.md:162–174` restricts Correlia schema steps to listed exception tables; `ingest_source` is not one. The design leaves the guard outside the managed table’s lifecycle: a future table replacement can remove it while the recorded step prevents reinstallation. Keep the offline cutover and remove the redundant trigger, or explicitly assign ownership of the guard and prove it survives the supported fresh-install, upgrade, and migration paths.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Enforce the documented TLS trust modes and verify suppressed key logging on a successful handshake.
2. Qualify production notification-time precision against independent microsecond evidence without replacing the production conversion.
3. Align D3’s exit rule with the spec: only 202 exits successfully.
4. Define timestamp bounds and test sanitized, non-retryable failures for out-of-range input.
5. Resolve ownership of the `ingest_source.kind` guard or omit it under the offline upgrade contract.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 10 C1 — inherited TLS trust and key logging:** The named environment overrides are now cleared. Exclusive custom-CA trust and the successful-handshake key-log check remain open in Critical 1.
- **Round 10 C2 — credentials in child argv/environment:** Resolved in design. Bearer headers use stdin, HMAC key material is not passed as an OpenSSL option, and the spec requires the token, key, and signature to stay out of child argv, environment, and output. The real-ingress and process-boundary scenarios exercise distinct parts of that contract.
- **Round 10 M1 — 202-only success:** The normative spec and negative test are fixed; D3’s exit rule remains contradictory.
- **Round 10 M2 — production clock gate:** Both commands now have a named per-release gate, but the assertion does not distinguish microsecond preservation from 10 or 100 µs quantization.
- **Round 10 M3 — advisory-lock bound and failure class:** Resolved in design. The timeout precedes both lock acquisitions, SQLSTATE `55P03` has a sanitized class, and advisory-lock and table-lock failure/restart have separate scenarios.
- **Round 10 M4 — HMAC concurrency loss:** Resolved in design. The caps and no-retry loss are explicit, and the signed-burst scenario asserts that Icinga 2 records the 503 as a command failure.