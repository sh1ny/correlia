## Metadata

- **Change** `icinga2-event-streams`, working-tree D32 amendment at base commit `793d649`.
- **Scope** Proposal, design, seven delta specs, task map, corresponding baseline specs, architecture index, ADRs 0016, 0017, 0024, 0028 and 0029, and the tracked admission, pipeline, schema, ordering and alert-state implementation. The Event Streams capability has no baseline spec.
- **Method** Read-only design review. Implementation citations refer to tracked files. No files were written and no tests were run. The round 8 owner override is historical.

## Findings

### Critical (blocking)

1. **Reclamation can make an eligible observation lose its state effect.** D32 adds a concurrent delete to an alert acquisition protocol that assumes a conflicting row survives until it is locked. `AlertStateService.apply` does `INSERT … ON CONFLICT DO NOTHING`, then separately selects `FOR UPDATE`. If that select finds nothing, the service skips the fingerprint. The pipeline can still store and route a ready event without a state outcome.  
   **Counterexample:** Admit a fresh CRITICAL whose receipt and source time are comfortably beyond the reclamation bounds. Pause its worker after the insert finds an expired silent tombstone. Let the sweep delete the tombstone and commit. Resume the worker. The tracked path can commit the firing event and outbox intent, mark the raw row done, and leave no alert. The pending-receipt guard permits this sweep because the fresh item cannot lose to the old fence.  
   **Basis:** Design D32 and D2, alert-state “Single writer for alert state,” `alert_state_service.dart:92–135,163–166`, `pipeline.dart:500–505,525–540,572–615`.

2. **D31’s replacement misses passwords that JSON decoding reconstructs.** D31 scans for literal password bytes and base64 variants before parsing. The secret-store delta forbids the password in derived events, and D11 uses acknowledgement comments as event descriptions.  
   **Counterexample:** Use a valid password containing `"` and have an authenticated subscription return a well-formed acknowledgement whose comment echoes it through standard JSON escaping. The wire comment contains a backslash before the quote, so the literal-byte scan misses it. The parser reconstructs the password and the event description can persist it. The raw row also retains the reversible echo.  
   **Basis:** Design D11 and D31, Event Streams “An echoed password is redacted before admission,” secret-store “Secret bytes never leave their consumer,” and the tracked description-to-storage path in `pipeline.dart:525–540`.

### Moderate

1. **The sweep has a deletion limit and no end-to-end execution bound.** D32 caps deletions at 500 and skips on lock timeout. A lock timeout limits a lock wait. It leaves candidate searches, evidence checks and the total transaction duration open while the sweep owns the cutoff exclusively. The tracked schema has an event payload rather than an indexed fingerprint on `events`, an activity index on `(txid, id)`, and an observation-key uniqueness index on event ID. The design supplies only the pending-receipt index.  
   **Counterexample:** Run a sweep with a large retained history and a candidate for which evidence absence requires a long scan. A fresh consumer insert can hit its two-second limit in the trigger, and a webhook can hit its five-second limit and return 503. If shutdown starts during that scan, D13’s close procedure covers the consumer connection but assigns no cancellation or drain behavior to the sweep. Also specify that a multi-alert sweep locks candidates in ascending fingerprint order. A sweep that locks B before A can deadlock with the existing worker that holds A and waits for B.  
   **Basis:** Design D5, D13 and D32, task 11.2, baseline process-roles “Graceful shutdown,” `admission.dart:58–66`, `alert_state_service.dart:75–77`, `schema/0001_ingest.sql`, `schema/0002_activity.sql`, and the alert-state migration’s `observation_keys` definition.

2. **The merged alert-state contract leaves the effect of reclamation on alert identity and lifecycle ambiguous.** The modified “Resolved alert fences late evidence after its events expire” still requires a resolved row to keep its fence after its events and keys are gone. D32 authorizes deleting a subset of those rows. The convergence requirement also leaves the existence of an expired resolved row and its lifecycle effects unspecified.  
   **Counterexample:** Take an expired, evidence-free silent tombstone and process a fresh eligible CRITICAL. If processing wins, the existing row refires in place and its version increments. If the sweep wins and state acquisition is corrected, the observation creates a new row at version 1 with `created` activity. Both can reach the same firing state and fence, with different alert IDs, versions and activity. A late item also leaves a resolved row in the first case and no row after reclamation.  
   **Basis:** Design D32, delta alert-state “Resolved alert fences late evidence after its events expire,” “Applied observations update state in place” and “Tombstones are reclaimed after the lateness horizon,” baseline alert-state “Authoritative alert state per fingerprint,” `transition.dart:103–145`, and `alert_state_service.dart:98–102`.

3. **The committed-webhook retry promise needs the existing transport window.** The source-ingress delta says already committed deliveries return their existing result without inserting. Its batch scenario qualifies the corresponding promise by receipt retention. The tracked webhook path returns duplicate only while `expiresAt` exceeds the request receipt. Once the window expires, it updates the reservation and attempts a new raw insert.  
   **Counterexample:** Commit a webhook, lose its response, and retry the same key and body with a receipt captured more than ten minutes after the original. Delay this retry until the cutoff passes its receipt. The reservation update and raw insert roll back and the caller receives 503. The requirement as written promises the prior committed result.  
   **Basis:** Design D32, delta source-ingress “New raw admissions honor the reclamation cutoff,” `admission.dart:28,100–150`, and `ingress.dart:204–219`.

### Suggestions

- Make task 6.3 exercise precise receipt boundaries with independent database connections and barriers. Include cutoff equality, a fence exactly seven days before the limiting receipt, a mixed-receipt consumer batch, and a claimed row whose failure reschedules it. For example, using flush time as the raw receipt can let a batch through even when one item predates the cutoff. Assert the committed bounds, raw status, alert state and outbox after each schedule.  
  **Basis:** D5, D32, tasks 6.3 and 7.3, `pipeline.dart:32–44,305–315,750–803`.

## Verdict

VERDICT: REVISE

## Required Changes

CHANGES_APPLIED: n/a

- Specify an alert acquisition protocol that handles deletion between conflict detection and row locking. Add the fresh-observation race to the DB task map and assert that a completed raw row has the corresponding state, activity and output effects.
- Extend D31 to handle JSON-escaped echoes before any durable or diagnostic representation can carry them. Add successful stream and sync cases that inspect raw storage and decoded event fields.
- Give reclamation an explicit transaction budget and shutdown behavior, require ascending fingerprint lock order, and specify how candidate and evidence checks stay bounded. Test lock contention and stop during an active pass.
- Amend the alert-state requirements to define post-reclamation row identity, version, activity and late-item behavior. Qualify webhook retry idempotence by the existing transport window and cover both retained and expired reservations.

## Rebuttals

- The core receipt-time bound is sound. If a tombstone’s effective fence is strictly earlier than the earliest possible receipt minus seven days, an observation at or below that fence is already late. The forward skew clamp cannot make otherwise eligible evidence late. Processing time can advance while a row waits or retries without changing that result. The global minimum correctly covers shared namespaces, unpinned work and delayed retries. Claimed rows remain visible as pending to other transactions until their outcome commits. `pipeline.dart:32–44,261–315,385–407,632–652,750–803`; `ordering_key.dart:18–39`.
- The admission/sweep handshake works with the specified Read Committed sequencing. The statement trigger must check every inserted row against the cutoff value returned by the locking read, after any wait. The sweep must take its pending snapshot in a separate statement after acquiring the exclusive cutoff lock. If admission holds the shared lock first, the sweep sees its commit. If a raw insert has executed but its trigger has yet to acquire the lock, the sweep may go first and the trigger must use the advanced cutoff. A cutoff read cached before locking or a pending scan using the lock-acquisition statement’s snapshot would invalidate that proof. Design D32; `ingest_records.dart:149–166`; `schema/0001_ingest.sql:1–15`.
- The marker and retained-evidence veto correctly protect ordinary resolved alerts and keyed evidence. The tracked webhook path can route a stale event while leaving the alert resolved, so the shared-namespace test should assert state separately from webhook routing. The batch receipt lookup remains ahead of gates on new inserts. Rejecting an old uncommitted batch as a unit, recording a gap and syncing on reconnect is consistent with the selected policy. Terminal failures have no requeue path in this release. Design D5, D25, D27 and D32; `pipeline.dart:458–495,572–615,704–803`.