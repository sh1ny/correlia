# Review

## Metadata

- **Round:** 14
- **Prior round:** round 13 (omp) REVISE: 2 Critical (OPENSSL_CONF overrides private-CA trust; schemeless URL defaults to HTTP), 2 Moderate (E2BIG on long check output; standalone status table vs informational rule).
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design, all four spec deltas, and round 13; baseline source-ingress, durable-pipeline, alert-state, and canonical-event specs; project rules and listed skills; M2 roadmap and named acceptance scenarios; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028, and 0029; cited ingest, pipeline, state, identity, schema, runtime, alert model, and protobuf sources; archived Alertmanager D6 and capture script; upstream Icinga 2 launcher, macro resolver, and notification sources; Dart HTTP client API and implementation. Read-only; no tests or captures run. Event Streams excluded.

## Findings

### Critical (blocking)

1. **The new truncation function can prevent a recovery notification from launching.** D3 (`design.md:116–124`) returns check output through a function-valued custom variable. Icinga 2 v2.13.0 marks custom variables recursive, evaluates the function, then scans the returned string for macros ([`macroprocessor.cpp:93–105,222–280`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/macroprocessor.cpp#L222-L280)). An ordinary recovery message such as `OK: cost below $5` has an unmatched `$` and throws before `PluginUtility` starts the command. Paired dollar signs can instead expand macros, modifying the output and defeating the pre-launch bound. The 200 KiB scenario can pass with plain ASCII while ordinary check text still drops a recovery and leaves the alert firing. Make the function return literal data across the recursive expansion boundary. Capture a real recovery with an unmatched dollar, macro-looking text, and a truncation boundary; assert the delivered text and resolved alert.

2. **Inherited Correlia settings can shadow the destination and trust configured by the notification command.** D3 puts settings in `NotificationCommand.env` and reads `/proc/self/environ` without defining collision behavior. [Icinga 2 copies inherited entries first, then appends command entries without replacing duplicates](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/base/process.cpp#L104-L136). A first-match reader can pick an inherited `CORRELIA_URL` or `CORRELIA_CA_FILE` over the configured one. Even a last-match reader can pick an inherited CA or HMAC file when the command omits that optional setting. TLS then verifies against the wrong trust or destination without violating any BoringSSL rule; the wrong peer can receive the bearer token and notification. Define the command’s settings as authoritative, including explicit absence of optional settings, or reject ambiguity before opening credential files. Exercise collisions in a real Icinga launch; the existing hostile-environment scenario tests only unrelated variable names.

### Moderate

1. **Author and comment still cross the unbounded pre-launch boundary.** D3 bounds `output` and `long_output` but passes `notification_author` and `notification_comment` through macros. Icinga 2’s [`SendCustomNotification`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/apiactions.cpp#L151-L174) forwards both strings without a length check, and [`PluginNotificationTask`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp#L34-L43) exposes them directly. A sufficiently long comment still hits Linux’s single-entry limit before the sender starts; the promised informational event is lost. Bound both before launch. Preserve the author’s role in the observation key explicitly: silently keying on a truncated display prefix can make different authors collide. Qualify the boundary with a real oversized CUSTOM delivery.

2. **The 10-second limit does not cover the sender’s configuration reads.** D3 calls it a sender run-time bound but attaches it to `HttpClient`. Credential reads and CA loading happen before that client can enforce anything. A credential path accidentally pointing to a FIFO can hang before the request; an oversized file can consume memory before validation. Specify bounded regular-file inputs and an end-to-end command deadline that cancels outstanding I/O, with deterministic exit and sanitized diagnostics. Add a non-regular input case and a peer that accepts a connection but never returns response headers.

3. **Two state-mapping scenarios still omit the fields that select the rule being tested.** “Unreachable host” does not specify `HARD` or a `PROBLEM`/`RECOVERY` type; “Soft recovery resolves” does not specify the notification type. Both scenarios currently admit informational deliveries for which their expected alert effect is wrong under the revised normative mapping. Pin the notification type and state type in these vectors, so they distinguish an actual state observation from an informational delivery carrying the same state.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

1. Preserve literal check output through Icinga’s recursive macro processing and prove that a real recovery with dollar-bearing output starts the command and resolves the alert.
2. Make command configuration authoritative over inherited settings, including absent optional settings, or fail closed on ambiguity. Verify with duplicate settings in a real Icinga launch.
3. Bound author and comment before launch without silently truncating author identity. Verify oversized CUSTOM input through the shipped command.
4. Bound credential and CA inputs and enforce and test the sender’s end-to-end deadline.
5. Specify the notification type and state type in the state-mapping scenarios that assert firing or resolution.

CHANGES_APPLIED: n/a

## Rebuttals

- **Round 13 C1 — `OPENSSL_CONF`:** Resolved in design for that path. The compiled sender removes curl and OpenSSL configuration from TLS trust selection. Critical 2 is a separate configuration-precedence gap at launch.
- **Round 13 C2 — schemeless URL:** Resolved in design. D3 requires an explicit scheme before credentials are read and permits plain HTTP only for a literal loopback address.
- **Round 13 M1 — long check output:** The design now truncates before launch, but Critical 1 shows why the function’s return value is not yet a reliable bound. Moderate 1 covers the remaining unbounded notification text.
- **Round 13 M2 — informational status:** The normative mapping now scopes firing and resolution to state notifications and fixes informational severity at `info`. Moderate 3 concerns the remaining underspecified scenarios.