# Invocation

`ce-plan output:md .planning/prompts/phase-09-ce-plan.md`

Plan the remaining Phase 9 work; do not implement it. Produce the normal implementation-ready Compound Engineering markdown artifact under `docs/plans/`, using the current `ce-plan` destination convention if that convention has changed. Preserve the skill's normal interactive scoping, review, and handoff checkpoints.

# Prerequisite gate

Phase 9 depends on Phase 5, which `.planning/ROADMAP.md` and `.planning/STATE.md` record as complete. Treat the current Phase 5 security and HTTP controls as required foundations, not Phase 9 scope. If fresh source and test research finds a missing or regressed Phase 5 behavior that directly prevents satisfying a Phase 9 contract, stop and report the exact blocker and evidence; do not fold unrelated Phase 5 repair into this plan.

# Planning objective

Create an implementation-ready convergence plan for **Phase 9: Plugin and Notification Boundaries**.

**Goal**: Output plugin execution remains isolated behind Correlia's bounded notification contract while preserving non-blocking ingress behavior.

This is gap closure against an existing implementation, not greenfield plugin architecture. Research the current source and tests first. Preserve behavior that already satisfies the product contract, identify discrepancies between legacy planning text and the current tree, and plan only the remaining work. Omit a proposed change or test when fresh repository research proves the corresponding contract is already covered; cite that evidence in the plan.

# Source hierarchy

Use these sources in this order:

1. `.planning/PROJECT.md` defines durable product decisions, `.planning/REQUIREMENTS.md` defines in-scope contracts, and `.planning/ROADMAP.md` defines phase sequencing, dependencies, and success criteria.
2. Current application source and tests are authoritative for implemented behavior and remaining gaps.
3. `.planning/STATE.md` and completed phase summaries or verifications are continuity evidence only. They may explain prior decisions but are not authoritative for current behavior.

If these product sources conflict with one another, surface the discrepancy for clarification rather than silently choosing one. If legacy planning intent conflicts with current code or tests, preserve the requirements and roadmap as product intent, describe the discrepancy, and plan only the implementation or proof still needed to make the tree converge.

# Required coverage

Carry these requirements into the plan without weakening or broadening them:

- **PLG-01**: Maintainers can load output plugins only from Correlia's allowlisted output plugin namespace with strict plugin configuration validation.
- **PLG-02**: Output plugins receive bounded `NotificationEnvelope` data instead of mutable incident ORM objects or raw configuration dictionaries.
- **PLG-03**: Notification dispatch converts plugin exceptions into structured `NotificationResult` records instead of relying on logs alone.
- **PLG-04**: Correlia preserves non-blocking task submission so notification delivery does not block the ingress request path.

The plan is complete only when it demonstrates all of these roadmap success criteria:

1. Maintainers can load output plugins only from Correlia's allowlisted output plugin namespace with strict plugin config validation.
2. Output plugins receive bounded `NotificationEnvelope` data instead of mutable incident ORM objects or raw configuration dictionaries.
3. Operators can inspect structured `NotificationResult` records for plugin exceptions and delivery outcomes rather than relying on logs alone.
4. Ingress requests are not blocked by notification delivery work after dispatch is submitted.

# Current implementation anchors to inspect and preserve

Start research from these existing boundaries, then follow definitions and references into their tests and call sites:

- `app/config/plugins.py` — strict registry configuration.
- `app/plugins/loader.py` — allowlisted output-plugin loading and plugin construction.
- `app/plugins/interfaces.py` — `NotificationEnvelope`, `NotificationResult`, and `OutputPlugin` contracts.
- `app/processing/notification_dispatcher.py` — structured notification dispatch and result creation.
- `app/processing/ingress.py` — post-commit notification submission from the ingress flow.
- `app/processing/task_runner.py` — `AsyncIOTaskRunner` fire-and-forget scheduling behavior.
- `app/main.py` — application lifespan construction and wiring.

Locate and inspect existing tests for each boundary before proposing new test files or duplicate scenarios. Use repository conventions for any additional test path.

# Required gap analysis

Research these confirmed weak spots explicitly. They are questions to settle from the current tree, not assumptions that each needs new production code:

- Proof that notification envelopes are bounded, immutable value data and cannot expose mutable incident ORM objects or raw configuration mappings to output plugins.
- A direct behavioral proof that ingress submission remains non-blocking when an output handler is deliberately slow.
- Eager plugin-construction and partial-load failure semantics: determine whether startup can enter a partially loaded or partially running state when one configured plugin fails construction or validation, and plan fail-closed behavior if needed.
- The contract boundary between immediate task-submission results and eventual plugin-delivery results. Make the ownership, observability, and test expectations for both explicit; do not conflate acceptance for execution with completed delivery.

For each gap, record what current code and tests already prove, what remains unproven or incorrect, the exact files likely to change, and focused happy-path, boundary, failure-path, and integration scenarios where applicable. Prefer strengthening an existing test at the correct seam over adding a duplicate.

# Scope boundaries

Keep this phase restricted to the existing output-only namespace and in-process task-runner boundary. The following future requirements remain deferred and must not be pulled into the Phase 9 plan:

- **FUT-01**: Maintainers can switch task execution to a durable broker-backed queue with retry/outbox semantics.
- **FUT-02**: Maintainers can load input, enrichment, decision/processor, and task-runner plugin adapters from strict allowlisted namespaces.
- **FUT-03**: Operators can enable LLM enrichment or decision-assist plugins explicitly with bounded timeouts, API-key environment references, and static-rule validation.
- **FUT-04**: Operators can use API-managed suppressions, silences, maintenance windows, config dry-run, and config reload workflows.
- **FUT-05**: Operators can dispatch to Slack, generic webhook, PagerDuty Events API, or Grafana OnCall output plugins.

Also exclude deployment/container work, durable queues, broker/outbox semantics, task-runner replacement, non-output plugin namespaces, LLM processing, and additional notification transports. Do not create compatibility facades or unrelated extensibility abstractions.

# Plan and verification expectations

The generated plan must:

- Use repository-relative paths and name concrete implementation units, dependencies, existing patterns, and focused test files.
- Trace each remaining unit to the requirement and success criterion it closes, without scheduling already-satisfied work.
- Separate production defects from missing behavioral proof; test-only convergence is valid when the implementation already satisfies the contract.
- Include an integration scenario through the real ingress, post-commit submission, task runner, dispatcher, and output-plugin boundary where practical, without mocking away the interaction being proved.
- Include failure scenarios for invalid plugin configuration, disallowed namespaces, plugin construction failure, plugin exceptions, and partial startup/load behavior where the current architecture exposes those risks.
- Define verification outcomes and reference the repository's focused-test and quality-gate conventions discovered from the tree; do not include exact shell command recipes in the plan.
- Leave implementation-time unknowns explicit when only execution can resolve them; do not pre-write implementation code.

Write only the CE-native plan artifact. Do not create or continue `.planning/phases/09-*` legacy `CONTEXT`, `RESEARCH`, `PLAN`, `SUMMARY`, or `VERIFICATION` artifacts. Do not run any `gsd-` command, update `.planning/STATE.md`, modify `.planning/ROADMAP.md`, or mark legacy requirement checkboxes. Those tracking changes occur only after the Compound Engineering implementation is complete and verified.
