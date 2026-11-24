# Review

## Metadata

- **Round:** 2
- **Prior round:** REVISE — four Critical and eight Moderate findings; the author reported all twelve fixed.
- **Reviewer:** cross-model CLI (OMP)
- **Reviewed:** Proposal, FULL design, round-1 review and rebuttals, four spec deltas, the main Alertmanager, source-ingress, durable-pipeline and canonical-event specs, architecture, ADRs 0008/0016/0019/0024/0029, and the supplied project rules. Re-read the cited local ranges in `bootstrap.dart`, `source_config.dart`, `config_repository.dart`, `ingress.dart`, `pipeline.dart`, `source_decoder.dart`, `body_depth.dart`, `identity.dart`, `event_bounds.dart`, `icinga2/mapper.dart`, `canonical_event.dart`, `event.proto`, `ingest_source.spy.yaml`, `console_access_policy.dart`, `alert_console_endpoint.dart`, the four run-mode configs, the capture script and the v0.16.2 firing fixture. Followed the admission insert, publisher trigger, epoch parser and timestamp formatter where they affected findings.
- **Verification limits:** No referenced store or scenario-to-task map was declared. The read-only tool context did not expose `git ls-files`; Git index membership was not independently verified. Serverpod transport behavior and Thanos capture were not exercised.

## Findings

### Critical (blocking)

1. **The source-ingress delta still requires admission-time pinning.** Its “Generic source with a known mapping” scenario expects the delivery to be “admitted as a raw row pinned to the new snapshot.” The durable-pipeline delta correctly expects B if B activates between admission and first claim. These cannot both hold. Admission inserts no pin (`schema/ingest_records.dart:150–169`), and `pinOne` writes the active snapshot later (`pipeline.dart:287–319`), as ADR 0016 requires. Change the ingress scenario to assert admission and an unset pin; keep the before/after activation assertions in the pipeline scenarios. Also qualify the design’s “Mapping removed while rows are pending” statement: only already-pinned rows retain the old mapping; an unpinned row whose source was removed fails `source_not_configured`.

2. **A mixed-version rollout can turn accepted generic deliveries into terminal failures.** D9 preserves snapshot IDs for old files, but nothing prevents activating a new generic source while an old worker is still claiming rows. Existing ingress compares the stored kind string and can admit a valid delivery (`ingress.dart:294–321,392–413`); the old worker cannot resolve `generic` and records `unsupported_kind` (`pipeline.dart:409–414,856–869`). The existing publisher trigger requires version 1 on inserts; it does not gate worker claims (`schema/0005_secret_reuse.sql:33–47`). Specify and test the cutover: upgrade all workers before enabling generic sources, and define rollback while generic work is pending or pinned. Do not rely on operator replay, which S5 defers.

3. **Preview can say `wouldFail: false` for a row production deterministically rejects.** D8 defines `wouldFail` as the production row outcome, but D10 derives it from decoder results. The worker also enforces a 16 MiB aggregate event-plus-output budget after decoding (`pipeline.dart:32,661–670`), with up to eight configured outputs (`source_config.dart:502–508`). A sample can fit the preview’s 1 MiB and 100-alert limits, yield individually valid events, and still fail `batch_bound` with no effects committed. State exactly what the flag predicts. Either limit and name it as a mapping-validation result, or specify which production checks preview reproduces and what it cannot predict without durable state. Add a case where all alerts map successfully but production rejects the row on the aggregate bound.

4. **The 1,000-alert limit allows large allocations before the worker checks the aggregate bound.** D7 permits any number of configured label fields to copy the same pointer, up to 128 labels. Copying one 900-byte string into 128 labels on each of 1,000 alerts can produce over 100 MiB of serialized label values from a sub-1 MiB raw body. `CanonicalEvent` retains its serialized bytes at construction (`canonical_event.dart:546–559`), and the worker materializes the decoded batch before testing its deadline or aggregate write budget (`pipeline.dart:426–455,661–670`). The resource table’s processing deadline is not a pre-allocation bound. Bound cumulative decoded bytes or equivalent expansion work while decoding, before retaining the full batch. Exercise repeated-pointer expansion and verify atomic rejection.

### Moderate

1. **Exact epoch evidence still has no input or precision contract.** D19 resolves the missing-time blocker, and RFC 3339 evidence now reaches the canonical constructors. But D14 promises an exact epoch rendering without specifying whether fractional or exponent-form numbers are accepted, or how precision loss is handled. Distinct nanosecond values near current epoch seconds can already be equal after a binary floating-point parse, collapsing fallback event IDs. The cited Icinga2 mapper only renders an already-exact timestamp; its parser converts decimal text with integer arithmetic (`icinga2/webhook_parser.dart:209–220`). Specify accepted epoch forms, precision and range, and reject values that cannot be represented exactly. Test negative epochs and the accepted precision boundary.

2. **The diagnostic path contract still disagrees across layers.** D12 distinguishes sender pointers from canonical paths, but the durable requirement demands a mapping-filtered RFC 6901 path on every failure. Existing failures can have no path, and both validation catches receive the same untagged `EventValidationError.path` (`pipeline.dart:457–465,733–743`; `event/validation.dart:4–18`). A canonical rejection such as `event_too_large` has no sender pointer. Also, cutting a rendered pointer at byte 256 can split a UTF-8 character or `~0`/`~1` escape. Define how sender paths, canonical fields and pathless failures are represented; use structural path information for redaction and truncate only at valid boundaries. Put the key-redaction guarantee in C3’s destination and cover both worker catches.

3. **Preview’s diagnostic cap has no deterministic selection rule or overflow assertion.** D8 now has a collecting mode, a count limit, a byte limit and an overflow count. The proposal still promises every diagnostic, and the spec neither requires the overflow count nor defines which diagnostics survive the cap. The new several-errors scenario stays below both limits. Specify ordering, how an individually oversized pointer is handled, and what the count includes. Test several errors within one alert and a long escaped ancestor repeated across enough diagnostics to hit the byte cap before the entry cap.

4. **The mapping grammar still permits incompatible implementations.** D7 gives `severity` only a `{pointer, values, default}` shape, while the spec permits a constant. D13 invokes “wrong JSON type” without defining the accepted types for table inputs and native observation IDs. D15 requires summary to be declared but does not require activation to reject an empty summary constant, which can never satisfy the canonical minimum (`event.proto:232–236`). Define the allowed forms and types, distinguish a missing selector from an unlisted table value, and reject statically invalid constants and table outputs at activation. Document that a native observation ID must identify an immutable observation, not the alert object; otherwise a resolve reusing the firing ID is deduplicated.

5. **The file cap is fixed, but it is not a bound on the serialized snapshot or admission transfer.** D15 correctly applies the existing 64 KiB cap to file-backed activation. D16 and the resource table then use it as a bound on normalized `publicJson`, a different representation assembled by `bootstrap.dart:163–168` with normalized source fields. The admission query can return that snapshot once per credential row, including for a lookup with no matching source (`ingress.dart:294–312`). State the file, serialized snapshot and per-lookup limits separately. Keep the no-cache choice if the resulting hot-path cost is acceptable; test rejection through file-backed activation and assert that the prior snapshot remains active.

6. **The Thanos tests still do not prove two of the documented behaviors.** D18 now has a transition and lossless capture plan, but in the dropped-label run the missing label cannot prove both Rulers sent; Alertmanager can merge the two notifications. The HA scenarios only assert Correlia-side exclusion and the kept-label case. Require independent send evidence for both Rulers in the drop run, then assert label absence in the captured notifications and a matching fingerprint with Correlia exclusions off. Separately, the tenant-header scenario posts the same body twice to one source: normal transport dedup creates only one raw row. Use distinct transport keys or wait via an injected clock, then assert that both rows reach observation processing and the header changes neither routing nor identity.

7. **C7’s destination does not carry its replay deferral.** The target requirement and scenario preserve the original pin on automatic retry, but do not state that decoding under a repaired mapping is operator replay and is deferred. Add that boundary to the named destination. Also name one durable destination for D16’s explicit no-cache decision: the mechanism ledger records it, but the carried constraints do not.

8. **Some corrected citations still do not establish their claims.** `pipeline.dart:1005–1018` establishes a five-attempt budget for non-transient internal errors, not for all retries. `alert_console_endpoint.dart:10–16` shows the policy helper, not the calls at the start of each endpoint method (`:18–34`). `tool/alertmanager_capture.sh:36–61` defines the receiver; the launch follows that range. More importantly, the design still says the global dev/test RPC cap increase applies only where console policy restricts callers to loopback. The policy runs inside console methods, not before the global RPC body limit; remove that assurance and state the impact on other dev/test RPCs.

### Suggestions

None.

## Verdict

VERDICT: REVISE

Second consecutive REVISE. Escalate to the owner before another full review. No finding requires reversing the owner’s choice of first-claim pinning, required source time, string-only identity fields, or the Thanos-through-Alertmanager integration.

## Required Changes

CHANGES_APPLIED: n/a

## Rebuttals

Round-1 re-check:

- **Critical 1 — still open.** Generic and durable deltas were corrected; the source-ingress delta still contradicts them.
- **Critical 2 — original blocker fixed.** D19 requires source time; the RFC 3339 representation is accepted by canonical construction. Exact epoch input handling remains open.
- **Critical 3 — wire arithmetic fixed.** The revised cap covers the stated valid-text budget, and D17 names a generated-client boundary test. The global-limit assurance remains incorrect.
- **Critical 4 — original blocker fixed.** The aggregate file limit is now explicit. The file-backed rejection scenario and the separate serialized-size claim remain open.
- **Moderate 1 — partial.** Collecting preview, partial successful events and byte/count bounds are present. Overflow behavior and the scope of `wouldFail` remain open.
- **Moderate 2 — partial.** Structural matching, actual array indexes and removal of the log promise are present. Path origin, RFC 6901 rendering and coverage of both catches remain open.
- **Moderate 3 — partial.** Required declarations, the 16-link cap and HTTP(S) link validation are present. Grammar consistency and activation-time validation of constants remain open.
- **Moderate 4 — fixed.** D20 and the numeric identity rejection scenario prevent number/string identity collapse.
- **Moderate 5 — original cache issue resolved.** D16 drops the cache and acknowledges the transfer remains. The serialized-transfer bound still needs correction.
- **Moderate 6 — partial.** D18 adds reload-driven transition, sequence captures and manifest fields. The dropped-label run still lacks independent proof of both sends.
- **Moderate 7 — partial.** C6 has one ADR destination; C7’s named destination carries pinning but omits replay deferral.
- **Moderate 8 — partial.** The actual worker loader, fingerprint tuple, Docker launch and run-mode size settings are now cited. The remaining mismatches are listed above.