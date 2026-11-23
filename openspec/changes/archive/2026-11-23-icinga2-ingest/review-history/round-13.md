# Review

## Metadata

- **Round:** 13
- **Prior round:** round 12 (omp) REVISE: 1 Critical (NSS-backed curl trusts its NSS database in private-CA mode), 4 Moderate (unpadded key file vs basenc; NUL in names; info notifications vs state rules; zero-time error code).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, all four spec deltas and round 12; baseline source-ingress, durable-pipeline, alert-state and canonical-event specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; cited ingest, pipeline, state, identity, schema, startup, runtime, alert model and protobuf sources; archived Alertmanager D6 and capture script; upstream Icinga 2, curl, OpenSSL and Linux execution references. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **An allowed OpenSSL-backed curl can still replace private-CA trust through `OPENSSL_CONF`.** D3 (`design.md:129–138`) clears curl-specific trust variables but leaves `OPENSSL_CONF` intact. [curl 7.88.1 loads OpenSSL configuration by default](https://github.com/curl/curl/blob/curl-7_88_1/lib/vtls/openssl.c#L1697-L1707). OpenSSL applies `system_default` when it creates the TLS context, and [`VerifyCAFile` sets a separate verification store](https://github.com/openssl/openssl/blob/OpenSSL_1_1_1w/ssl/ssl_conf.c#L467-L505). [Peer verification prefers that store](https://github.com/openssl/openssl/blob/OpenSSL_1_1_1w/ssl/ssl_cert.c#L365-L386) over the context store that curl populates from `--cacert` and `--capath`. Thus an inherited config can make an endpoint trusted by a different CA receive the bearer token or signed payload despite `CORRELIA_CA_FILE`. Private-CA mode must prevent OpenSSL configuration from supplying another verification store, including through the default config if `OPENSSL_CONF` is unset. Extend the TLS test to exercise this path on a permitted OpenSSL build.

2. **A URL without a scheme can send credentials over remote plaintext HTTP.** D3 (`design.md:126–129`) rejects non-loopback `http://` URLs but does not require an explicit scheme; `--proto =http,https` still permits HTTP. [curl 7.55.0 defaults schemeless URLs to HTTP](https://github.com/curl/curl/blob/curl-7_55_0/lib/url.c#L4493-L4539). An operator who omits `https://` can therefore send a bearer token and check output in plaintext. Require an explicit scheme before reading credentials, allow HTTP only for a validated literal loopback address, and restrict curl to the selected protocol for that invocation. Test that a schemeless remote address causes no request.

### Moderate

1. **Long check output can prevent the notification command from starting.** D3 (`design.md:110–124`) passes check text as Icinga macro environment values; the design only bounds display text after ingress. Icinga 2's [passive-result API stores `plugin_output` directly](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/apiactions.cpp#L93-L99), its [service macro returns that string](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/service.cpp#L253-L260), and its [launcher passes the macro values to `execvpe`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L124-L183). Linux caps each argument or environment entry at [32 pages](https://man7.org/linux/man-pages/man2/execve.2.html#DESCRIPTION), 128 KiB on a 4 KiB-page host. A passive check with 200 KiB of output is below Correlia's body limit but can fail with `E2BIG` before the script runs, losing the state notification. Bound non-identity text before Icinga starts the command, preserving a visible truncation marker. The HTTP-only ID-3 scenario does not exercise this boundary; add a real-command capture that does.

2. **The standalone status mapping still contradicts the informational rule.** `specs/integration-icinga2/spec.md:227–231` says without qualification that service OK maps to `resolved` and CRITICAL maps to `firing`. The revised requirements at `:175–179` and `:306–316` say a CUSTOM delivery carrying either state must be `info`. An implementation following the standalone table can still turn the new OK-bearing CUSTOM fixture into a recovery. Scope the table and its scenarios explicitly to `PROBLEM` and `RECOVERY`, and specify the canonical severity for informational events so output consumers see a consistent mapping.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Enforce exclusive private-CA trust at the OpenSSL configuration boundary and verify that a CA supplied through that path cannot receive a request.
2. Require explicit URL schemes and enforce the selected protocol in curl; verify that a schemeless remote URL sends nothing.
3. Bound sender display text before the Icinga process launch and prove that oversized check output does not prevent delivery of the state transition.
4. Make all status and severity requirements consistent with the distinction between state-bearing and informational notifications.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 12 C1 — NSS trust:** Resolved for NSS: D3 requires active OpenSSL and rejects another backend before reading credentials. Critical 1 is a separate trust path within the allowed backend.
- **Round 12 M1 — unpadded HMAC key:** Resolved in design. D3 pins Correlia's canonical unpadded input, adds padding for the decoder only, and requires a real-ingress acceptance scenario.
- **Round 12 M2 — NUL in names:** Resolved in design. NUL and name controls now produce a bounded `invalid_text` outcome before database mutation.
- **Round 12 M3 — informational status:** Partially resolved. D8 and the new CUSTOM scenario agree; the standalone mapping table remains open in Moderate 2.
- **Round 12 M4 — zero-time error:** Resolved. D2 and the delta distinguish explicit zero (`out_of_range`) from an absent field (`missing_field`).