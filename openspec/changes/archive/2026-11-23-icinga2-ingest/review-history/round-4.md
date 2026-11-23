# Review

## Metadata

- **Round:** 4
- **Prior round:** round 3 (omp) REVISE: 7 Critical (ordering cycle in the current-state rule; reconnect sync deduplicated; webhook macros read from the live object; host query asks for host_name; bad stream line fails its batch; repeated short pauses grow Icinga's queue; password digest via signing keys), 4 Moderate. Owner split the change; consumer scope moved to icinga2-event-streams.
- **Reviewer:** cross-model CLI (omp)
- **Reviewed:** `icinga2-ingest` proposal, design and all four spec deltas; baseline `source-ingress`, `durable-pipeline`, `alert-state` and `canonical-event` specs; project rules, M2 roadmap, ORD-4/6/7 and ID-2/3/7; architecture and ADRs 0016, 0017, 0020, 0021, 0024, 0028 and 0029; cited ingest, pipeline, state, identity, schema and runtime sources; `event.proto`; archived Alertmanager D6 and capture script; relevant Icinga 2 v2.13.0 source. Read-only; no runtime tests or captures run.

## Findings

### Critical (blocking)

1. **A torn macro read can win the fence after the correct refire has already applied.** D4 assumes the consistent notification is always observed later. The older callback can read `OK`, then read the refire's `last_state_change=t3`, and reach Correlia *after* the consistent `CRITICAL@t3` webhook. The two observations have distinct D2 keys. At equal source time, `ordering_key.dart:46–51` lets the later receipt win, resolving the alert while Icinga is still CRITICAL. A subsequent consistent reminder is a duplicate and cannot fix the fence (`pipeline.dart:389–421`; `alert_state_service.dart:168–195`). Require coherent state evidence or explicitly narrow the convergence contract. Exercise a torn delivery that arrives after the consistent delivery, then a reminder. The current permutation test only rearranges already-coherent deliveries.

2. **Even a coherent `last_state_change` can regress or repeat.** Icinga's [`ApiActions::ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/apiactions.cpp) accepts independent `execution_start` and `execution_end` values. [`Checkable::ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/checkable-check.cpp) compares starts to reject old checks but writes the end into `last_state_change`. With increasing starts, a HARD CRITICAL ending at 10:04 followed by an OK ending at 10:03 can produce two coherent, successfully delivered webhooks; Correlia leaves the alert firing. If CRITICAL later recurs with end 10:04, it can reuse the first event ID. This is a webhook defect independently of Event Streams. Define the supported ordering guarantee for repeated and regressing ends before freezing D2; capture both cases or explicitly document that they do not converge.

3. **The shipped `NotificationCommand` does not provide a SOFT transition feed.** In Icinga 2 v2.13.0, [`Checkable::ProcessCheckResult`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/checkable-check.cpp) emits ordinary Problem/Recovery notifications for hard changes, with a separate volatile-HARD path; it explicitly excludes recovery from a SOFT problem. A delayed prior notification can incidentally sample SOFT CRITICAL and fire under `soft_and_hard`, then a SOFT-to-OK transition can generate no recovery command at all. Downtime, acknowledgement, dependencies and flapping can also suppress state notifications without an HTTP failure. The required real SOFT→HARD capture cannot rely on normal notifications to sample SOFT. Separate decoder support for SOFT input from what the shipped sender guarantees; document upstream suppression, and make the real-capture scenario use an explicitly supported way of obtaining SOFT evidence or stop requiring it from this sender.

4. **Changing kind in place can strand deliveries Correlia already acknowledged.** `admission.dart:66–80,140–149` verifies the route kind but stores only the source UUID with the raw row. `config_repository.dart:211–220` updates kind for that same UUID. If an Alertmanager POST commits with 202 before the change and `pinOne` runs after it, D6 picks the Icinga2 decoder and permanently fails the valid Alertmanager body (`pipeline.dart:209–236,285–301`). The same problem applies to replay against a later snapshot. Either make kind immutable for a source UUID or retain the admitted decoder identity independently of the first-claim config pin. Test the admission–publication–claim sequence; a body-read race tests a different boundary.

5. **Changing SOFT policy makes the durable result depend on which pinned row wins dedup.** Admit two copies of one SOFT CRITICAL observation, pin A under `hard_only` and B under `soft_and_hard`, and commit them in either order. D2 gives both the same event ID. If A wins, an `info` event is stored and B cannot create an alert; if B wins, the alert fires. The unique-key insert runs before either effect (`pipeline.dart:389–431`), and `info` is ignored by `transition.dart:93–100`. This violates the alert-state delta's processing-order guarantee; the policy-revision scenario only proves decoding. Specify which policy owns an observation across revisions and test both processing orders, including the committed event and alert state.

### Moderate

1. **D3's direct runtime-function environment binding has no working evidence for the intended floor.** Icinga 2 v2.13.0 [`PluginUtility::ExecuteCommand`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/pluginutility.cpp) converts each `env` value to `String` before passing it to `ResolveMacros`; that is not the direct function-evaluation path in [`MacroProcessor`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/macroprocessor.cpp). Specify and prove the actual binding, such as a string macro resolving to a function-valued variable. Require a working capture on at least one release before freezing the contract; otherwise the matrix can pass with an empty supported-release list.

2. **The non-state key has no defined source for `notification_time`.** [`Notification::BeginExecuteNotification`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/icinga/notification.cpp) updates `last_notification` on the notification object before queuing one callback per user; the callback does not capture that timestamp. A runtime function reading `last_notification` can stamp two queued CUSTOM notifications from the same author with the same later time, dropping one comment. Sampling the clock per command instead assigns different IDs to multiple recipients of one action. Specify whether the event represents an upstream action or a command execution, what timestamp is stable at that boundary, and what recipient configuration is supported. Capture two distinct same-author actions and the supported fan-out case.

3. **The shipped command's HMAC and diagnostic boundaries are not acceptance-tested.** The integration spec permits both auth modes, but its successful real-release case does not require HMAC. ADR 0029 requires HMAC over the exact transmitted body with the decoded 32-byte key and the prescribed header format. Also, Icinga's [`PluginNotificationTask::ProcessFinishedHandler`](https://github.com/Icinga/icinga2/blob/v2.13.0/lib/methods/pluginnotificationtask.cpp) logs failed command output, so forwarding the HTTP response body can put receiver-controlled text into Icinga logs. Specify credential-file encodings, verified HTTPS for production, and bounded diagnostics that exclude secrets and response bodies. Exercise the shipped command against real ingress using both modes, including rejected delivery with captured Icinga logs.

4. **The versioned sender contract still permits incompatible implementations.** The webhook-document requirement lists check output among the document fields and treats missing required fields as failures, while “Missing check output” requires success. It also leaves the relationship between `output` and `long_output` unspecified. Separately, D2 says to put a length-prefixed tuple into `ObservationKey.native`, but `identity.dart:318–329,389–428` accepts a UTF-8 string, not arbitrary tuple bytes. Specify field presence and composition, the canonical destination for notification type, and the exact inner tuple representation passed to `native`. Publish fixed byte and UUID vectors; a capture that checks only three distinct IDs cannot pin those choices.

### Suggestions

None.

## Verdict

VERDICT: REVISE

## Required Changes

Resolve Critical 1–5 in the design and corresponding specs before implementation. Keep Event Streams out of this change. Gate the webhook contract on a nonempty real-release capture, and pin the sender authentication and identity formats before publication.

CHANGES_APPLIED: n/a

## Rebuttals

None.