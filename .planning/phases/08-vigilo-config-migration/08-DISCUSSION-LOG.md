# Phase 8: Vigilo Config Migration - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in `08-CONTEXT.md` — this log preserves the alternatives considered.

**Date:** 2026-06-18
**Phase:** 8-Vigilo Config Migration
**Areas discussed:** Input path shape, SMTP credential handling, Topology regex capture-group substitution, Unsupported-field failure mode

---

## Input path shape

| Option | Description | Selected |
|--------|-------------|----------|
| Single YAML file per flag | Each `--rules`, `--topology`, `--plugins` flag accepts one existing YAML file; directories/globs rejected with clear errors. | ✓ |
| Directory per flag | Each flag accepts a folder of YAML files merged in lexical order. | |
| Auto-detect file or directory | Script inspects path type and behaves accordingly. | |

**User's choice:** Single YAML file per flag.
**Notes:** Aligns with Correlia's existing single-file config loaders and the documented VDE source layout. Multi-file support deferred to a future enhancement.

---

## SMTP credential handling

| Option | Description | Selected |
|--------|-------------|----------|
| Fail-closed: exit with error, operator configures separately | Migration rejects plaintext `smtp_username`/`smtp_password`, reports unsupported-field error, and writes no outputs. | ✓ |
| Ship SecretRef support in Phase 8 and emit `{env: VAR}` refs | Add first-class secret-reference support to plugin options so generated YAML can reference credentials. Deferred — out of Phase 8 scope. | |
| Emit raw `${VAR}` placeholders and add loader expansion | Familiar shell-like syntax, but ambiguous with literal values and creates config-hash ordering risks. | |

**User's choice:** Fail-closed: exit with error, operator configures separately.
**Notes:** Correlia's current plugin loader does not expand `${...}` placeholders and would reject `{env: ...}` dicts, so emitting placeholders would produce misleading or invalid config. First-class `SecretRef` support is a deferred future idea.

---

## Topology regex capture-group substitution

| Option | Description | Selected |
|--------|-------------|----------|
| Extend Correlia with `tag_capture_groups` field and migrate to it | Add explicit `tag_capture_groups` mapping to `HostnameTopologyRule`, resolved at enrichment time. | ✓ |
| Use a single `capture_group` int per rule | Simpler schema supporting only one derived tag per rule. | |
| Fail clearly when capture groups are required | Reject hostname patterns with capture groups; honest but fails on all sample VDE patterns. | |

**User's choice:** Extend Correlia with `tag_capture_groups` field and migrate to it.
**Notes:** Per-tag group assignment is explicit, future-proof for multi-group patterns, and avoids ambiguity between literal and derived tags.

---

## Unsupported-field failure mode

| Option | Description | Selected |
|--------|-------------|----------|
| Aggregate report + atomic replace: list all issues, write nothing until clean | Collect all unsupported fields into a structured report; stage outputs in temp dir; validate through Correlia loaders; atomically replace `--out-dir` only on full success. | ✓ |
| Fail-fast + atomic replace: stop at first issue, write nothing until clean | Stop at first unsupported field; still atomic replace on success. | |
| Aggregate report but write partial outputs for inspection | List all issues but still write partial YAML files for manual review. | |

**User's choice:** Aggregate report + atomic replace: list all issues, write nothing until clean.
**Notes:** Aggregate reporting fits the one-time batch migration use case; atomic replace prevents partial or stale outputs.

---

## Claude's Discretion

None — user made an explicit selection for every gray area.

## Deferred Ideas

- First-class `{env: VAR}` SecretRef support in plugin options (future phase).
- Directory/glob input flags for multi-file Vigilo deployments (future enhancement).
- Topology tag template syntax (`\1` in tag values) — rejected in favor of explicit `tag_capture_groups`.

---

*Phase: 8-Vigilo Config Migration*
*Discussion date: 2026-06-18*
