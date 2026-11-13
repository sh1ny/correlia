# Design review: plugin-health-timeout-classification (re-check of the five required changes)

This replaces the earlier `review.md`. I limited it to the five Required changes from the previous review and checked them against the current `design.md`, `tasks.md`, `proposal.md` and `specs/plugin-output-protocol/spec.md`. It is read-only: I didn't build, run or edit anything. I didn't open `bounded_channel.dart`, because the corrections can be checked from the planning text alone. The D4 implementation and its tests are meant to wait for this design gate, so I haven't asked for implementation evidence. Points about grpc-dart and http2 behaviour that were marked unverified before are still unverified.

## Summary

All five required corrections are now in the plan, and the four planning files agree with each other:
- D4 (`design.md:89-103`) and task 3.2 (`tasks.md:52-59`) now say what the earlier review asked for.
- The test map (`tasks.md:12-13`) separates the red-to-green proof from the guard tests that start green.
- `proposal.md` (Impact, S3) and the spec's "Request write races transport closure" scenario (`spec.md:28-30`) still match D4's scope.

No new required changes.

## Accepted corrections

1. **M1: invalid frames never reach the delegate. Accepted.**
   - `design.md:93` says the guard's `FormatException` branch "sets `_failed`, invokes `_fail` and returns before the delegate write". `tasks.md:56` says the same.
   - The invalid-frame guard cases must check that the delegate received no write: `design.md:97` ("Invalid-frame guard cases assert no delegate write") and `tasks.md:57` ("never reach the delegate").

2. **M2: where `_fail` runs, and that its failures propagate. Accepted.**
   - `design.md:93`: "`_fail` runs in the catch body, outside the protected `try`; exceptions from `_fail` or `terminate()` propagate, and the catch is never widened to absorb them."
   - `tasks.md:56` repeats this.

3. **M3: red/green states and where the evidence goes. Accepted.**
   - The test map now has two rows:
     - `closed_delegate_write_fails_rpc` is red (`tasks.md:12`);
     - `non_state_error_propagates` and `invalid_frames_still_fail` are green guard tests (`tasks.md:13`).
   - Task 3.2 says "This closed-sink test is the red-to-green proof. Guard tests start green". `design.md:97` agrees: "Only the closed-sink regression starts red; both guard tests start green."
   - The red result and the 2/2 unfixed SIGKILL failures are recorded in `evidence/protocol-load-runs.md` (`tasks.md:57`, `design.md:97`).

4. **M4: the narrowness test checks that nothing changed state. Accepted.**
   - Task 3.2 checks that a non-`StateError` delegate failure:
     - propagates;
     - causes no incoming error or close;
     - causes no termination;
     - still lets a later write reach the delegate;
     - leaves `frameFailure` null.
   - `design.md:97` lists the same checks.

5. **Minor items. Accepted.**
   - **`_fail` wording:** `design.md:93` now says "The callback is `_Stream._fail`, which `_Stream` passes into `_GuardedSink`."
   - **Visibility reasoning:** in D4 (`design.md:95`), covering both orders: incoming status first, or write failure first. In each order the call fails visibly.
   - **Why `on StateError` is narrow enough:** in D4 (`design.md:94`). The delegate is a controller sink, and a concurrent delegate `addStream` can't happen because our `addStream` sends each message through `add`. No message matching is needed.
   - **Test fakes:** they live in the fast-tier `test/unit/plugin/bounded_channel_test.dart`. They follow the pattern in `plugin_transport_test.dart` but don't import that `plugin`-tagged file. The tests listen to `incomingMessages` before writing (`design.md:97`, `tasks.md:57`).
   - **Open Question:** it now points at `evidence/health-status-capture.md` and gives the captured result in one line: 50/50 `deadlineExceeded`, nothing else, and the line-385 path not reached (`design.md:219`). Task 1.1's note was updated to match (`tasks.md:29`).

## Remaining minor notes (optional, not blocking)

- `design.md:92` still has the old phrase "invoking the callback already passed from `_Stream._fail`". The next line states it correctly, so this is only a leftover in the wording. You could delete the old phrase.
- The test-map row "Existing transport guards" (`tasks.md:13`) names a scenario that isn't in the spec delta. That's fine for guard tests that protect behaviour that already exists. Another option is to label the row as a guard row, not a spec scenario.

## Decision rationale

The earlier review's reasoning still holds:
- **The catch can't hide real failures.** It is limited by type (`StateError` only) and by structure (only the delegate write is inside the `try`). Failures from `_fail` and `terminate()` propagate.
- **It routes the failure to the right place.** The failure goes through `_Stream._fail` and arrives as an incoming `GrpcError.unavailable`. D1/D2 then classify it, and `frameFailure` stays null.

With M1–M4 and the minor items now in the plan, D4 is specific enough to implement. The plan names one deterministic red-to-green proof and two guard tests that stay green, and says where the evidence is recorded.

VERDICT: APPROVE_WITH_CHANGES
CHANGES_APPLIED: yes