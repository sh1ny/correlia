# Review

## Metadata

- **Round:** 12
- **Prior round:** round 11 (omp) REVISE: 1 Critical (private CA does not replace curl's default CA directory), 4 Moderate (production clock gate; D3 exit rule; timestamp range; trigger on a Serverpod-managed table).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, four spec deltas and round 11; baseline source-ingress, durable-pipeline, alert-state and canonical-event specs; project rules, M2 roadmap, named acceptance scenarios, architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert model and protobuf sources; legacy pinned-snapshot test; archived Alertmanager D6 and capture script; relevant upstream curl, coreutils and Icinga 2 source. Read-only review. No tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **Private-CA mode still trusts certificates outside `CORRELIA_CA_FILE` on a permitted curl build.** D3 (`design.md:110,129–134`) permits curl 7.55+ without restricting the TLS backend. The empty `--capath` fixes the OpenSSL directory case, but curl 7.55.0 with NSS [initializes a certificate database from `SSL_DIR` or `/etc/pki/nssdb`](https://github.com/curl/curl/blob/curl-7_55_0/lib/vtls/nss.c#L1252-L1320) and [verifies peers against that database](https://github.com/curl/curl/blob/curl-7_55_0/lib/vtls/nss.c#L705-L744). Setting `--cacert` and `--capath` [suppresses the separate built-in trust module and loads the supplied PEM material](https://github.com/curl/curl/blob/curl-7_55_0/lib/vtls/nss.c#L1530-L1571); it does not remove trust from the initialized database. D3 does not clear `SSL_DIR` either. On that build, an endpoint trusted only by the NSS database can receive a bearer token in private-CA mode. Restrict the sender to verified TLS backends and fail closed on others, or isolate all trust inputs on every supported backend. Exercise the rejection path before any credential is sent.

### Moderate

1. **The HMAC key-file format is not pinned to Correlia’s existing credential format.** D3 (`design.md:138–143`) says `basenc` reads the key file, but `bootstrap.dart:486–502` accepts exactly 43 canonical **unpadded** base64url characters for a 32-byte credential. The [coreutils 8.31 URL-safe decoder delegates to the base64 decoder and rejects an incomplete final quantum](https://github.com/coreutils/coreutils/blob/v8.31/src/basenc.c#L323-L356). Directly decoding an operator’s existing key file fails; allowing only a padded file makes the sender and bootstrap use different representations. Specify the file format, supply padding only to the decoder, and require successful decoding of exactly 32 bytes before signing. Exercise the unpadded file with the real decoder and ingress; a shim or a padded fixture does not establish compatibility.
2. **A name accepted by the webhook can produce an alert summary PostgreSQL cannot store.** The webhook document accepts string names, and D8 (`design.md:270–275`) projects them into the summary. The existing `normalizeDisplayText` validates Unicode and truncates but does not remove U+0000 (`canonical_event.dart:694–709`). `AlertStateService` binds that summary directly to `alerts.summary` (`alert_state_service.dart:98–114`), and [PostgreSQL cannot store U+0000 in text](https://www.postgresql.org/docs/current/datatype-character.html). A short name containing an escaped NUL can therefore pass decoding and fail in the transaction, consuming the internal retry budget instead of yielding a bounded field failure. Reject it at the name field or define a storage-safe display projection that preserves the full identity input. Assert the persisted result through the pipeline.
3. **The mapping requirements give informational notifications contradictory status rules.** “Webhook state is the object's state when the command runs” applies state-driven status to every delivery (`integration-icinga2/spec.md:145–149`), and the SOFT requirement says any OK or UP state resolves (`:242–246`). The non-state requirement instead makes CUSTOM, acknowledgement, downtime and flapping events `info` and forbids alert effects (`:283–289`). A CUSTOM notification sampled while a service is OK can therefore be interpreted as a recovery under one requirement and as a comment under another. Scope the state/status, projection and SOFT rules to PROBLEM and RECOVERY, and assert that a CUSTOM delivery carrying OK leaves an existing firing alert and its fence unchanged.
4. **An explicit zero timestamp still has two required error codes.** D2 (`design.md:96–99`) assigns `out_of_range` to values outside `0 < value < 253402300800`, while “Missing state change time” supplies an explicit `0` and requires `invalid_time` (`integration-icinga2/spec.md:279–281`). Following D2 fails the scenario and changes the machine-readable diagnostic. Distinguish missing, wrong-type and numeric range failures, and make the design and both timestamp-field scenarios agree.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Enforce exclusive private-CA trust for all supported curl backends, or reject unverified backends before sending credentials.
2. Define and verify the HMAC sender’s handling of Correlia’s canonical unpadded key files using the real decoder and ingress.
3. Make host and service names safe at the PostgreSQL summary boundary and cover the behavior through the pipeline.
4. Make state-bearing and informational notification mapping requirements disjoint; verify that an OK-bearing CUSTOM notification has no alert effect.
5. Align timestamp validation codes and distinguish missing fields from explicit numeric zero.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 11 C1 — private CA:** The empty directory addresses the cited OpenSSL default `CApath`, and the new scenario checks key-log suppression after a successful handshake. Exclusive trust remains open for the allowed NSS backend.
- **Round 11 M1 — production clock:** Resolved in design. Both commands drive known microsecond inputs through the unchanged formatter and serialization path; the production clock check now rejects 10 µs quantization.
- **Round 11 M2 — exit rule:** Resolved. D3 and the spec agree that only 202 exits successfully.
- **Round 11 M3 — timestamp domain:** The finite range and pre-multiplication check close the numeric overflow path. Explicit zero still has contradictory diagnostics.
- **Round 11 M4 — schema ownership:** Resolved. The trigger is removed; the offline cutover covers old publishers in every process role.