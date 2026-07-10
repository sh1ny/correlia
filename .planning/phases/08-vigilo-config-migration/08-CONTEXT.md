# Phase 8: Vigilo Config Migration - Context

**Gathered:** 2026-06-18
**Status:** Ready for planning

<domain>
## Phase Boundary

Phase 8 delivers a standalone CLI migration script (`scripts/migrate_vigilo_config.py`) that translates supported Vigilo/VDE YAML configuration into strict Correlia YAML (`rules.yaml`, `topology.yaml`, `plugins.yaml`). The script fails clearly and exits non-zero whenever Vigilo semantics cannot be preserved, including unsupported fields, unsupported plugin types, and plaintext SMTP credentials. Generated files must validate through Correlia's existing strict config loaders before success is reported.

Phase 8 does not extend runtime behavior beyond what is required to express migrated config in Correlia's schemas. It does not implement new output plugin types, deployment packaging, audit or metrics features, or Vigilo API/webhook compatibility.

</domain>

<decisions>
## Implementation Decisions

### Migration Input Contract
- **D-01:** Each input flag (`--rules`, `--topology`, `--plugins`) accepts exactly one path to an existing YAML file (`.yaml` or `.yml`). Directories, globs, missing files, and non-YAML files are rejected with clear errors.
- **D-02:** The script mirrors Correlia's existing single-file loader contract (`load_rules_config`, `load_topology_config`, `load_plugin_registry_config`) and the `CORRELIA_RULES_PATH` / `CORRELIA_TOPOLOGY_PATH` / `CORRELIA_PLUGINS_PATH` settings shape.
- **D-03:** Multi-file or directory-based Vigilo sources are out of scope for Phase 8; they may be supported later with explicit additional flags and documented merge semantics.

### SMTP Credential Handling
- **D-04:** The migration script is **fail-closed** on plaintext SMTP credentials (`smtp_username`, `smtp_password`). When found, the script reports a clear unsupported-field error and exits non-zero; no output files are written.
- **D-05:** The migration script must **not** emit `${...}` or `{env: ...}` placeholders in generated `plugins.yaml`. Correlia's plugin loader does not expand such placeholders today, and emitting them would create config that appears valid but is treated as literal credentials or rejected by `_validate_option_value`.
- **D-06:** Operators are expected to configure SMTP credentials outside the migration artifact (e.g., environment variables supplied at runtime, a secret store, or an unauthenticated relay). The plugin skeleton in `plugins.yaml` is generated only when the migration succeeds; plaintext credentials must be removed or excluded from the Vigilo source before the migration can produce output.

### Topology Regex Capture-Group Substitution
- **D-07:** Correlia's `HostnameTopologyRule` schema is extended with a new `tag_capture_groups` field: a mapping from tag key (starting with `topology.`) to a 1-indexed regex capture-group number (e.g., `topology.datacenter: 1`).
- **D-08:** Literal `tags` and derived `tag_capture_groups` coexist in the same rule. Derived tags are resolved at enrichment time from the hostname regex match and merged after literal tags.
- **D-09:** Validation at config-load time ensures every group index is `>= 1` and `<= pattern.groups`. At enrichment time, groups that match `None` or empty strings are skipped; substituted values are bounded by existing `TagValue` length constraints before being applied.
- **D-10:** The migration detects Vigilo hostname patterns that contain parenthesized capture groups and a `target_tag`, and emits `tag_capture_groups: {topology.<target_tag>: 1}`. Topology entries without capture groups continue to emit literal `tags`.
- **D-11:** Subnet topology rules are unchanged and always use literal tags.

### Unsupported-Field Failure Mode
- **D-12:** The migration performs an explicit preflight scan of raw Vigilo input to detect unsupported semantics before transformation. Unsupported fields include `min_hosts`, `is_dc_level`, empty actions, non-output plugin sections, LLM config, unsupported plugin types, and plaintext SMTP credentials.
- **D-13:** Errors are **aggregated** across all input files and domains into a structured report, then the script exits non-zero. This supports the primary one-time batch-port use case.
- **D-14:** Generated files are staged in a temporary directory, validated through Correlia's existing loaders (`load_rules_config`, `load_topology_config`, `load_plugin_registry_config`), and only atomically moved into `--out-dir` on full success. On any failure, temp files are discarded and `--out-dir` is left untouched.
- **D-15:** The migration must not write partial or corrupted output files, even when the user may want to inspect intermediate results. Diagnostics are available in the unsupported-fields report.

### Claude's Discretion
- Choose a clear CLI error format and structured report format (e.g., JSON or YAML to `--report-path`, human-readable to stderr) during planning.
- Choose whether `tag_capture_groups` is added to `TopologyConfig` with a default empty dict or as an optional field, consistent with strict Pydantic discipline.
- Decide the exact set of unsupported Vigilo fields and plugin types to reject based on the research files and sample configs, without expanding Phase 8 scope.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase Scope and Locked Requirements
- `.planning/ROADMAP.md` — Phase 8 goal, success criteria, and dependencies.
- `.planning/REQUIREMENTS.md` — CFG-01 through CFG-07.
- `.planning/PROJECT.md` — project architecture, API-first boundary, strict validation posture, and v1.1 compatibility goal.
- `.planning/STATE.md` — current milestone position and prior phase decisions.
- `.planning/phases/05-security-and-http-controls/05-CONTEXT.md` — locked route protection and token separation decisions.
- `.planning/phases/06-canonical-incident-api-operation-parity/06-CONTEXT.md` — canonical incident API decisions.
- `.planning/phases/07-incident-event-audit-trail/07-CONTEXT.md` — audit write and strict Pydantic schema discipline.

### Compatibility Target
- `VIGILO_COMPATIBILITY.md` §3 (lines 73-92) — original migration command target and constraints (single `--rules`/`--topology`/`--plugins` inputs, plaintext credential prohibition, fail on unsupported fields).

### Implementation Context
- `app/config/rules.py` — strict rule schema, `RuleConfig`, `CompiledRuleConfig`, `load_rules_config`.
- `app/config/topology.py` — strict topology schema, `HostnameTopologyRule`, `SubnetTopologyRule`, `load_topology_config`.
- `app/config/plugins.py` — strict plugin registry schema, `PluginRegistryEntry`, `_validate_option_value`, `load_plugin_registry_config`, `config_hash` computation.
- `app/config/settings.py` — settings pattern with `CORRELIA_` env prefix and existing `SecretStr` usage.
- `app/plugins/outputs/email.py` — `SmtpOutputOptions` and current email plugin contract.
- `app/processing/enrichment.py` — `StaticTopologyEnricher._apply_rule` pattern for applying hostname/subnet topology tags.
- `CONFIGURATION.md` — project configuration documentation, including sample topology rules and migration command notes.
- `.planning/research/CONFIG.md` — VDE source layout research, including sample CLI and backreference requirement notes.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `app.config.rules.load_rules_config` — validates `rules.yaml` through strict Pydantic models; use to validate generated rules.
- `app.config.topology.load_topology_config` — validates `topology.yaml`; will need extension for `tag_capture_groups`.
- `app.config.plugins.load_plugin_registry_config` — validates `plugins.yaml` and computes `config_hash`; must remain credential-free in hash input.
- `app.processing.enrichment.StaticTopologyEnricher` — natural place to resolve `tag_capture_groups` against matched hostnames.
- `app.processing.logging.safe_log_extra` — use for safe structured logging during migration without leaking source payloads or credentials.

### Established Patterns
- Strict Pydantic v2 models with `ConfigDict(strict=True, extra="forbid")` for all config surfaces.
- Config loaders take a single `pathlib.Path` and return a compiled/config-hash tuple.
- Plugin options are bounded scalar values, lists, or `None`; arbitrary nested dicts are rejected by `_validate_option_value`.
- Testcontainers-backed pytest for database behavior; CLI migration tests can run without a database.

### Integration Points
- New script `scripts/migrate_vigilo_config.py` is the primary deliverable; it should be discoverable and runnable via `python scripts/migrate_vigilo_config.py` or `uv run`.
- Generated files are consumed by `app.config.settings.Settings` paths (`rules_path`, `topology_path`, `plugins_path`) and loaded at startup.
- Topology enrichment in `app/processing/enrichment.py` must apply `tag_capture_groups` after literal `tags`.
- Phase 9 (Plugin and Notification Boundaries) will build on the generated `plugins.yaml` shape; keep output plugins strictly within the existing allowlist.

</code_context>

<specifics>
## Specific Ideas

- Reject plaintext SMTP credentials with a clear error referencing CFG-04/CFG-05; do not suggest placeholder syntax that does not yet exist in the loader.
- Detect Vigilo hostname capture-group substitution by inspecting `regex.groups > 0` and the presence of `target_tag`, not by scanning tag values for `\N` backreferences.
- Use atomic temp-directory staging (`tempfile.mkdtemp`, validate staged YAML, `os.replace`) so failed migrations never corrupt `--out-dir`.
- Maintain the existing `TopologyConfig` strict schema while adding `tag_capture_groups`; avoid overloading `tags` with template syntax to prevent literal-vs-substitution ambiguity.

</specifics>

<deferred>
## Deferred Ideas

- **First-class secret references in plugin options:** A future phase may introduce a structured `{env: VAR}` reference type (or similar) so generated `plugins.yaml` can reference credentials without containing them. This is not in Phase 8 scope because it requires schema changes to `PluginRegistryEntry`, `SmtpOutputOptions`, and plugin instantiation, plus careful `config_hash` ordering to avoid hashing resolved secrets.
- **Multi-file/directory input flags:** If real Vigilo deployments use split config files, a future enhancement could add `--rules-dir`, `--topology-dir`, `--plugins-dir` flags with explicit merge and duplicate-detection semantics.
- **Topology tag template syntax (`\1` in tag values):** Rejected in favor of explicit `tag_capture_groups`. If needed later, template expansion would require defining an escape grammar and is more ambiguous than the explicit mapping.

</deferred>

---

*Phase: 8-Vigilo Config Migration*
*Context gathered: 2026-06-18*
