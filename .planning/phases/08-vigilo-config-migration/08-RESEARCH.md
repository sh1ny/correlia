# Phase 8: Vigilo Config Migration - Research

**Researched:** 2026-06-18
**Domain:** Python CLI / YAML config translation and strict Pydantic schema extension
**Confidence:** HIGH (findings are grounded in the current codebase and user-locked Phase 8 context)

## Summary

Phase 8 delivers a single standalone CLI script, `scripts/migrate_vigilo_config.py`, that converts a Vigilo/VDE YAML configuration into the strict Correlia YAML schemas already enforced by `app.config.rules`, `app.config.topology`, and `app.config.plugins`. The script must be fail-closed: it detects unsupported Vigilo semantics in a preflight pass, aggregates structured errors, and only writes (and atomically promotes) generated files when every generated file also passes the same loaders Correlia runs at startup.

The largest technical gap is Vigilo's hostname-derived topology tags. Vigilo uses a regex capture group plus a bare `target_tag` to derive a tag value at runtime, while Correlia's `HostnameTopologyRule` and `StaticTopologyEnricher` only support literal `tags` today. Satisfying CFG-04 therefore requires a coordinated schema, compiler, and enricher extension (`tag_capture_groups`), not just a migration-time rewrite. The other significant trap is rule priority semantics: Vigilo documentation says higher numeric priority runs first, but Correlia's `RuleEngine` sorts ascending (lower first). The migration must either invert priorities or the planner must explicitly accept a behavior change.

This research validates all locked decisions D-01 through D-15 against the current code, flags D-07–D-09 as requiring new implementation, surfaces the priority-inversion issue as a planner decision, and maps every CFG requirement to the concrete code surfaces that must change or be reused.

## User Constraints (from 08-CONTEXT.md)

### Locked Decisions

- **D-01:** Each input flag (`--rules`, `--topology`, `--plugins`) accepts exactly one path to an existing YAML file (`.yaml` or `.yml`). Directories, globs, missing files, and non-YAML files are rejected with clear errors.
- **D-02:** The script mirrors Correlia's existing single-file loader contract (`load_rules_config`, `load_topology_config`, `load_plugin_registry_config`) and the `CORRELIA_RULES_PATH` / `CORRELIA_TOPOLOGY_PATH` / `CORRELIA_PLUGINS_PATH` settings shape.
- **D-03:** Multi-file or directory-based Vigilo sources are out of scope for Phase 8.
- **D-04:** The migration script is **fail-closed** on plaintext SMTP credentials (`smtp_username`, `smtp_password`). When found, the script reports a clear unsupported-field error and exits non-zero; no output files are written.
- **D-05:** The migration script must **not** emit `${...}` or `{env: ...}` placeholders in generated `plugins.yaml`. Correlia's plugin loader does not expand such placeholders today, and emitting them would create config that appears valid but is treated as literal credentials or rejected by `_validate_option_value`.
- **D-06:** Operators are expected to configure SMTP credentials outside the migration artifact. The plugin skeleton in `plugins.yaml` is generated only when the migration succeeds; plaintext credentials must be removed or excluded from the Vigilo source before migration can produce output.
- **D-07:** Correlia's `HostnameTopologyRule` schema is extended with a new `tag_capture_groups` field: a mapping from tag key (starting with `topology.`) to a 1-indexed regex capture-group number.
- **D-08:** Literal `tags` and derived `tag_capture_groups` coexist in the same rule. Derived tags are resolved at enrichment time from the hostname regex match and merged after literal tags.
- **D-09:** Validation at config-load time ensures every group index is `>= 1` and `<= pattern.groups`. At enrichment time, groups that match `None` or empty strings are skipped; substituted values are bounded by existing `TagValue` length constraints before being applied.
- **D-10:** The migration detects Vigilo hostname patterns that contain parenthesized capture groups and a `target_tag`, and emits `tag_capture_groups: {topology.<target_tag>: 1}`. Topology entries without capture groups continue to emit literal `tags`.
- **D-11:** Subnet topology rules are unchanged and always use literal tags.
- **D-12:** The migration performs an explicit preflight scan of raw Vigilo input to detect unsupported semantics before transformation.
- **D-13:** Errors are **aggregated** across all input files and domains into a structured report, then the script exits non-zero.
- **D-14:** Generated files are staged in a temporary directory, validated through Correlia's existing loaders, and only atomically moved into `--out-dir` on full success. On any failure, temp files are discarded and `--out-dir` is left untouched.
- **D-15:** The migration must not write partial or corrupted output files, even when the user may want to inspect intermediate results.

### Claude's Discretion

- Choose a clear CLI error format and structured report format (e.g., JSON or YAML to `--report-path`, human-readable to stderr) during planning.
- Choose whether `tag_capture_groups` is added to `TopologyConfig` with a default empty dict or as an optional field, consistent with strict Pydantic discipline.
- Decide the exact set of unsupported Vigilo fields and plugin types to reject based on the research files and sample configs, without expanding Phase 8 scope.

### Deferred Ideas (OUT OF SCOPE)

- First-class secret references in plugin options (e.g., `{env: VAR}`).
- Multi-file/directory input flags.
- Topology tag template syntax (`\1` in tag values).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| **CFG-01** | Standalone CLI `scripts/migrate_vigilo_config.py` with `--rules`, `--topology`, `--plugins`, `--out-dir` producing `rules.yaml`, `topology.yaml`, and `plugins.yaml`. | No script exists yet; use `argparse`, `pathlib.Path`, and `yaml.safe_load`. The script can be invoked with `python scripts/migrate_vigilo_config.py` or `uv run scripts/migrate_vigilo_config.py` [CITED: 08-CONTEXT.md]. |
| **CFG-02** | Rewrite supported Vigilo rule fields into strict Correlia rule schema: severities, host/service patterns, topology tag keys, summary placeholders, action objects. | `app/config/rules.py` defines strict loaders; `load_rules_config` validates action names against `known_actions` (default `{create_incident}`) and plugins against `known_plugins` [CITED: app/config/rules.py:161-190]. VDE `actions: ["email-ops"]` must become `{name: create_incident, plugin: email-ops}` unless `known_actions` is widened. |
| **CFG-03** | Rewrite supported Vigilo topology fields into strict Correlia hostname/subnet schemas. | `app/config/topology.py` defines `HostnameTopologyRule`, `SubnetTopologyRule`, and `load_topology_config` [CITED: app/config/topology.py:12-138]. Tag keys must start with `topology.`. |
| **CFG-04** | Preserve Vigilo hostname-derived topology tags via regex capture groups, or fail clearly. | Current `HostnameTopologyRule`/`CompiledHostnameRule` only carry literal `tags`; `StaticTopologyEnricher._apply_rule` never sees regex match groups [CITED: app/config/topology.py:12-80, app/processing/enrichment.py:52-83]. Requires schema + compiler + enricher extension (`tag_capture_groups`) per D-07–D-09. |
| **CFG-05** | Rewrite supported Vigilo email output config into Correlia plugin schema without copying plaintext SMTP credentials. | `app/config/plugins.py` only accepts `outputs` with `plugin_type="email"` and `class_path` under `app.plugins.outputs.` [CITED: app/config/plugins.py:16-32]. `SmtpOutputOptions` validates TLS/credential rules [CITED: app/plugins/outputs/email.py:15-50]. D-04–D-06 require fail-closed on `smtp_username`/`smtp_password`. |
| **CFG-06** | Exit non-zero with clear unsupported-field errors for `min_hosts`, `is_dc_level`, empty actions, non-output plugin sections, LLM config, unsupported plugin types. | Preflight scan over raw parsed dicts is required; Correlia loaders would reject some of these too late or with messages tied to generated files. Sample VDE config contains all of these unsupported constructs [CITED: ../vde-event-aggregation/config/rules.yaml:39-69, ../vde-event-aggregation/config/plugins.yaml:4-56]. |
| **CFG-07** | Validate generated files with existing Correlia loaders before reporting success. | Reuse `load_plugin_registry_config`, `load_rules_config(known_plugins=...)` and `load_topology_config` on staged files [CITED: 08-CONTEXT.md, app/config/rules.py:158-207, app/config/topology.py:97-138, app/config/plugins.py:65-77]. |

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|--------------|----------------|-----------|
| Vigilo YAML parsing & unsupported-field preflight | CLI / build-time script | — | The migration is a maintainer-run, one-time/port tool, not a runtime API. |
| Rule/topology/plugin transformation logic | CLI / build-time script | — | Encoded in `scripts/migrate_vigilo_config.py`; must remain independent of the running server. |
| Strict config schema enforcement | Backend / config loaders | CLI (calls loaders) | `app.config.*` owns canonical validation; the CLI reuses it for CFG-07. |
| Topology regex capture-group substitution | Backend enrichment | Config compiler | `StaticTopologyEnricher` resolves derived tags at event-processing time; `load_topology_config` compiles patterns and validates group indices. |
| Aggregated unsupported-field reporting | CLI / build-time script | — | The script collects errors across all three input files before exiting non-zero. |
| Atomic output staging & promotion | CLI / filesystem | — | `tempfile.mkdtemp` + `os.replace` ensures `--out-dir` is never left partial. |

## Standard Stack

Phase 8 introduces **no new external dependencies**. All required functionality is already present in the project.

### Core

| Library | Version in project | Purpose | Why Standard |
|---------|-------------------|---------|--------------|
| Python | 3.14.4 (via `uv run`) | CLI runtime | Project requires `>=3.14` [CITED: pyproject.toml:6]. |
| Pydantic | 2.13.4 | Strict schema validation | Already used by every config loader (`ConfigDict(strict=True, extra="forbid")`) [CITED: app/config/rules.py:16, app/config/topology.py:13, app/config/plugins.py:17]. |
| PyYAML | 6.0.3 | YAML parse/emit | Used by all loaders; `yaml.safe_load` and `yaml.safe_dump` are the established pattern [CITED: app/config/rules.py:164,199-200]. |
| `re` / `fnmatch` (stdlib) | — | Regex compilation and fnmatch translation | `re` is used by `load_rules_config` and `load_topology_config`; `fnmatch.translate()` safely converts VDE shell wildcards to anchored regex [CITED: app/config/rules.py:112-129, app/config/topology.py:105-111]. |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `pathlib` (stdlib) | — | Path validation and file I/O | For `--out-dir`, input path checks, and atomic output staging. |
| `tempfile` / `os` (stdlib) | — | Atomic staging | Stage generated YAML in a temp dir, validate, then `os.replace` into `--out-dir` per D-14. |
| `logging` + `app.processing.logging.safe_log_extra` | — | Safe structured CLI logs | Avoid leaking source payloads or credentials in log output [CITED: app/processing/logging.py:61-70]. |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `argparse` (stdlib) | `click` or `typer` | Adding a new dependency is unnecessary for four flags and one optional `--report-path`. `argparse` keeps the deliverable self-contained. |
| `yaml.safe_dump` | `ruamel.yaml` with comments | Comment preservation is not a Phase 8 requirement and would add a dependency. |
| `fnmatch.translate()` | Hand-rolled `* -> .*` replacement | Hand-rolling misses character classes, escaping, and anchoring; `fnmatch.translate()` is safer and well-tested. |

## Package Legitimacy Audit

No external packages are installed or recommended for Phase 8. The deliverable relies exclusively on the project's existing dependencies and the Python standard library.

## Architecture Patterns

### System Architecture Diagram

```text
Vigilo source files              Migration CLI
   rules.yaml  ──────┐
 topology.yaml ──────┼──► [preflight scan] ──► unsupported-field report
 plugins.yaml  ──────┘          │
                                ▼
                       [transform per domain]
                                │
                ┌───────────────┼───────────────┐
                ▼               ▼               ▼
          rules.yaml     topology.yaml     plugins.yaml
                │               │               │
                └───────────────┼───────────────┘
                                ▼
                       [validate with Correlia loaders]
                                │
                success ────────┴──────► atomic move to --out-dir
                failure ───────────────► discard temp files, exit non-zero
```

**Notes:**
- Data flows from raw Vigilo YAML through a preflight scan, then transformation, then loader validation, then atomic filesystem promotion.
- The preflight scan operates on raw `dict` data so it can detect unsupported fields before they are transformed or dropped.
- Loader validation reuses the same functions Correlia calls at startup (`load_plugin_registry_config`, `load_rules_config`, `load_topology_config`).

### Recommended Project Structure

```
scripts/
└── migrate_vigilo_config.py       # standalone CLI entrypoint
app/
├── config/
│   ├── rules.py                   # existing strict rule loader
│   ├── topology.py                # extended with tag_capture_groups
│   └── plugins.py                 # existing strict plugin loader
├── processing/
│   └── enrichment.py              # StaticTopologyEnricher extended for capture groups
└── plugins/
    └── outputs/
        └── email.py               # SmtpOutputOptions (unchanged)
tests/
├── test_vigilo_config_migration.py
└── fixtures/
    ├── vigilo/
    │   ├── rules_valid.yaml
    │   ├── rules_min_hosts.yaml
    │   ├── rules_is_dc_level.yaml
    │   ├── rules_empty_actions.yaml
    │   ├── topology_valid.yaml
    │   └── plugins_valid.yaml
    │   └── plugins_with_credentials.yaml
    └── vigilo_sample/             # optional: mirror of VDE sample configs
        ├── rules.yaml
        ├── topology.yaml
        └── plugins.yaml
```

### Pattern 1: Fail-Closed Preflight Scan

**What:** Parse each input YAML into plain `dict`s and walk known keys. Any unsupported key, unsupported plugin section, or plaintext credential is recorded in an error list. The script transforms nothing until the preflight list is empty.

**When to use:** Required for D-12/D-13 and CFG-06.

**Example:**

```python
# Conceptual shape; source: 08-CONTEXT.md + CONFIGURATION.md
_UNSUPPORTED_RULE_FIELDS = {"min_hosts", "is_dc_level"}

def scan_rules(raw: dict[str, object]) -> list[str]:
    errors: list[str] = []
    for idx, rule in enumerate(raw.get("rules", [])):
        if not isinstance(rule, dict):
            continue
        for field in _UNSUPPORTED_RULE_FIELDS:
            if field in rule:
                errors.append(f"rules[{idx}]: unsupported field '{field}'")
        if rule.get("actions") == []:
            errors.append(f"rules[{idx}]: empty actions are not supported")
    return errors
```

### Pattern 2: Transform with Loader Round-Trip

**What:** Convert Vigilo structures into Python dicts that match the Correlia YAML shape, write them to a temp directory, and call the existing loaders. Do not construct Pydantic models manually and then dump them; the loaders are the source of truth.

**When to use:** Required for CFG-07 and D-14.

**Example:**

```python
# Source: 08-CONTEXT.md + app/config/plugins.py
import tempfile
from pathlib import Path
from app.config.plugins import load_plugin_registry_config
from app.config.rules import load_rules_config
from app.config.topology import load_topology_config

def validate_staged(staging: Path) -> None:
    registry = load_plugin_registry_config(staging / "plugins.yaml")
    load_rules_config(
        staging / "rules.yaml",
        known_plugins=frozenset(entry.name for entry in registry.outputs),
    )
    load_topology_config(staging / "topology.yaml")
```

### Pattern 3: Regex Capture-Group Topology Substitution

**What:** Add an optional `tag_capture_groups: dict[str, int]` field to `HostnameTopologyRule`, carry it through `CompiledHostnameRule`, and have `StaticTopologyEnricher` apply the matched regex groups after literal `tags`.

**When to use:** Required for CFG-04 and D-07–D-11.

**Example (schema extension):**

```python
# Source: app/config/topology.py + 08-CONTEXT.md D-07/D-09
from pydantic import BaseModel, ConfigDict, Field, field_validator

class HostnameTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: str
    name: str
    hostname_pattern: str
    tags: dict[str, str] = Field(default_factory=dict)
    tag_capture_groups: dict[str, int] = Field(default_factory=dict)

    @field_validator("tag_capture_groups")
    @classmethod
    def _groups_must_be_positive(cls, value: dict[str, int]) -> dict[str, int]:
        for key, group in value.items():
            if group < 1:
                raise ValueError(f"capture group index for '{key}' must be >= 1")
        return value
```

**Example (enricher extension):**

```python
# Source: app/processing/enrichment.py + 08-CONTEXT.md D-08/D-09
import re
from app.domain.events import TagValue

def _apply_hostname_rule(
    self,
    event: NormalizedEvent,
    rule: CompiledHostnameRule,
    match: re.Match[str],
) -> EnrichmentResult:
    new_tags = dict(event.tags)
    # literal tags first
    for key, value in rule.tags.items():
        new_tags[key] = value
    # derived capture-group tags override / fill in after literal tags
    for key, group_index in rule.tag_capture_groups.items():
        captured = match.group(group_index)
        if captured:  # skip None or empty
            if len(captured) > 256:
                raise ValueError(f"derived tag '{key}' exceeds 256 characters")
            new_tags[key] = captured
    # ... build diagnostic and return EnrichmentResult ...
```

### Anti-Patterns to Avoid

- **Hand-rolling `* -> .*` replacement for VDE host/service wildcards.** VDE uses `fnmatch` whole-string semantics; Correlia uses `re.match`. Use `fnmatch.translate()` or an explicitly anchored regex to avoid broadening patterns (e.g., `web` matching `web01`).
- **Emitting environment-variable placeholders in `plugins.yaml`.** D-05 forbids `${...}`/`{env:...}` because the plugin loader treats them as literal strings. The older `CONFIGURATION.md` recommendation to emit `.env.example` placeholders is superseded by D-04–D-06; credentials must be omitted and configured outside the migration artifact.
- **Validating only with the plugin registry loader.** `load_plugin_registry_config` accepts arbitrary scalar option keys; it does not instantiate `SmtpOutputPlugin`. Tests must also instantiate the registry or validate `SmtpOutputOptions` to catch startup-time failures.
- **Writing generated files directly to `--out-dir` before validation.** Violates D-14/D-15. Always stage, validate, then atomically promote.
- **Translating VDE priorities one-to-one.** Correlia's `RuleEngine` sorts ascending (`sorted(rules, key=lambda r: r.definition.priority)`) [CITED: app/processing/rule_engine.py:12], while Vigilo says higher numbers run first. Either invert/rebase priorities or explicitly document the behavior change.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| YAML parsing | Custom parser or regex | `yaml.safe_load` / `yaml.safe_dump` | Standard, safe, already used by every loader [CITED: app/config/rules.py:164]. |
| Wildcard-to-regex translation | `str.replace("*", ".*")` | `fnmatch.translate()` | Handles `?`, character classes, escaping, and produces an anchored regex matching VDE whole-string semantics. |
| Strict model validation | Ad-hoc `dict` checks | Pydantic v2 `BaseModel` with `ConfigDict(strict=True, extra="forbid")` | Existing loaders already enforce this pattern; duplicating it introduces drift [CITED: app/config/rules.py:15-16]. |
| Config hash | Custom rolling hash | `hashlib.sha256(yaml.safe_dump(..., sort_keys=True).encode())` | Used by existing loaders for deterministic, sort-stable hashes [CITED: app/config/rules.py:199-202, app/config/plugins.py:70-76]. |
| Atomic file output | Write-in-place with rollback | `tempfile.mkdtemp` + write + validate + `os.replace` | Filesystem-level atomic promotion; no partial outputs on failure (D-14). |
| Plugin option bounds | Per-option ad-hoc checks | Reuse `SmtpOutputOptions` model and `_validate_option_value` | The plugin loader accepts scalars/lists, but `SmtpOutputPlugin.__init__` validates TLS/credential rules at instantiation [CITED: app/plugins/outputs/email.py:38-50]. |

**Key insight:** The migration's value is translation and fail-closed reporting, not reimplementing validation. Reuse Correlia's loaders as the final gate; any validation the migration does before that is only to produce clearer, Vigilo-contextualized errors.

## Runtime State Inventory

Phase 8 is a config-translation deliverable. It does not rename or migrate runtime state. The canonical runtime-state categories are explicitly empty:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | None — the migration script does not touch PostgreSQL or any other datastore. | None. |
| Live service config | None — no running service configuration references the strings being migrated. | None. |
| OS-registered state | None — no OS-level tasks, units, or registrations are affected. | None. |
| Secrets/env vars | None — the script must *not* read or write SMTP secrets; it only rejects plaintext credentials in source YAML. | None. |
| Build artifacts / installed packages | None — the script is a new file; no existing compiled artifacts carry the old name. | None. |

**Nothing found in category:** All categories verified as not applicable for a one-time config migration CLI.

## Common Pitfalls

### Pitfall 1: Priority Inversion

**What goes wrong:** Vigilo sample documentation says "higher number = processed first" [CITED: ../vde-event-aggregation/config/rules.yaml:3], but Correlia's `RuleEngine` sorts ascending and returns the first match [CITED: app/processing/rule_engine.py:12,20-21]. A literal port of priorities would reverse rule precedence.

**Why it happens:** The two systems use opposite conventions. Correlia's loader also rejects duplicate priorities [CITED: app/config/rules.py:173-177], so any tie-breaking strategy must be decided explicitly.

**How to avoid:** Either (a) map Vigilo priority `P` to a rank such that higher Vigilo priority becomes a lower Correlia priority value (e.g., sort descending and assign `1, 2, 3…`), or (b) document that the migration intentionally changes numeric priority semantics and require operators to review.

**Warning signs:** A migrated config where the DC-level rule has priority `100` and the host-level rule has priority `50` will evaluate the host-level rule first in Correlia.

### Pitfall 2: Capture-Group Topology Requires Three-Way Coordination

**What goes wrong:** Adding `tag_capture_groups` to the YAML schema alone does nothing. If the compiler drops the field or the enricher ignores it, topology substitution silently fails.

**Why it happens:** Current `HostnameTopologyRule` and `CompiledHostnameRule` only store literal `tags` [CITED: app/config/topology.py:12-80], and `_apply_rule` never receives the regex match object [CITED: app/processing/enrichment.py:52-65].

**How to avoid:** Change schema → compiler → enricher together in one phase slice. Validate group indices at load time (`>= 1` and `<= pattern.groups`) and skip empty/None captures at enrichment time [CITED: 08-CONTEXT.md D-09].

**Warning signs:** Tests that only load `topology.yaml` pass, but end-to-end events never receive `topology.datacenter` tags.

### Pitfall 3: `load_plugin_registry_config` Passing but Startup Failing

**What goes wrong:** The plugin registry loader accepts any scalar option values, but `SmtpOutputOptions` requires `start_tls`/`use_tls` when credentials are present and bounds all strings [CITED: app/plugins/outputs/email.py:38-50].

**Why it happens:** CFG-7 only names the three loaders, but the loaders do not instantiate output plugins.

**How to avoid:** In tests, instantiate `PluginRegistry` from `app.plugins.loader` or validate `SmtpOutputOptions.model_validate(options)` for each migrated email output.

**Warning signs:** `make test` passes, but `uv run uvicorn app.main:create_app --factory` crashes on plugin load.

### Pitfall 4: Wildcard Tag Values Migrated Literally

**What goes wrong:** VDE rule `tags.datacenter: "*"` is a wildcard match; Correlia's `MatchCriteria` does exact equality on `tags` [CITED: app/domain/rules.py:17-23]. If the migration copies `"*"` literally, the rule will never match.

**Why it happens:** Correlia has no wildcard tag matcher today.

**How to avoid:** Fail fast on any non-literal tag value (`*`, `?`, `[`, `]`). This is already listed in `CONFIGURATION.md` porting notes and aligns with D-12.

**Warning signs:** Migrated rules load but produce zero incidents despite incoming events.

### Pitfall 5: Summary Placeholders Not Rewritten

**What goes wrong:** VDE `output_summary: "Major outage in {datacenter}"` must become `{topology.datacenter}` in Correlia because `_render_summary` looks up keys in `event.tags` [CITED: app/processing/rule_engine.py:151-157].

**Why it happens:** VDE topology tags are bare (`datacenter`) while Correlia requires the `topology.` prefix.

**How to avoid:** Rewrite bare tag placeholders to `topology.<key>` placeholders during migration; reject placeholders that do not map to a known normalized field or valid tag key.

**Warning signs:** Summary renders with literal `{datacenter}` placeholders.

### Pitfall 6: Partial Output on Validation Failure

**What goes wrong:** Writing `rules.yaml` and `topology.yaml` to `--out-dir` before `plugins.yaml` validation fails leaves inconsistent config behind.

**Why it happens:** Direct writes are not atomic across three files.

**How to avoid:** Stage all three files in a temp directory, run all loaders, then rename the temp directory over `--out-dir` or rename each file individually after the whole set is validated [CITED: 08-CONTEXT.md D-14].

**Warning signs:** `--out-dir` contains some generated YAML files even when the CLI reports failure.

## Code Examples

### VDE Rule → Correlia Rule

```yaml
# VDE source (excerpt)
- name: "Host Alert Aggregator"
  priority: 50
  match:
    severity: ["CRITICAL", "WARNING"]
    host: "*"
  window:
    duration_seconds: 1800
    group_by: ["host"]
    trigger_threshold: 5
  output_summary: "Multiple alerts on {host}"
  actions: ["email-ops"]
```

```yaml
# Generated Correlia rules.yaml
rules:
  - name: "Host Alert Aggregator"
    priority: 2          # inverted rank if planner chooses priority inversion
    match:
      severities: ["CRITICAL", "WARNING"]
      host_pattern: ".*"
    window:
      duration_seconds: 1800
      group_by: ["host"]
      trigger_threshold: 5
    output_summary: "Multiple alerts on {host}"
    actions:
      - name: "create_incident"
        plugin: "email-ops"
```

Source: VDE sample [CITED: ../vde-event-aggregation/config/rules.yaml:46-56] and `app/config/rules.py` `known_actions` default [CITED: app/config/rules.py:161].

### VDE Topology → Correlia Topology with Capture Groups

```yaml
# VDE source
hostname_patterns:
  - name: "Standard Naming Convention"
    regex: "^([a-z0-9]+)-prd-.*"
    target_tag: "datacenter"
```

```yaml
# Generated Correlia topology.yaml
hostname_rules:
  - id: "standard-naming-convention"
    name: "Standard Naming Convention"
    hostname_pattern: "^([a-z0-9]+)-prd-.*"
    tags: {}
    tag_capture_groups:
      topology.datacenter: 1
```

Source: VDE sample [CITED: ../vde-event-aggregation/config/topology.yaml:7-10] and D-07/D-10 [CITED: 08-CONTEXT.md].

### VDE Email Output → Correlia Plugin Registry

```yaml
# VDE source
outputs:
  email-ops:
    module: "app.plugins.outputs.email"
    class: "EmailPlugin"
    config:
      smtp_host: "smtp.example.com"
      smtp_port: 587
      from_address: "vigilo@example.com"
      to_addresses:
        - "ops@example.com"
```

```yaml
# Generated Correlia plugins.yaml
outputs:
  - name: "email-ops"
    plugin_type: "email"
    class_path: "app.plugins.outputs.email.SmtpOutputPlugin"
    options:
      host: "smtp.example.com"
      port: 587
      from_address: "vigilo@example.com"
      to_addresses:
        - "ops@example.com"
      start_tls: true
```

Source: VDE sample [CITED: ../vde-event-aggregation/config/plugins.yaml:18-28] and `app/config/plugins.py` [CITED: app/config/plugins.py:16-32].

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| VDE `config/plugins.yaml` with `module`/`class` keys and arbitrary plugin sections | Correlia `outputs[]` with `plugin_type`, `class_path`, bounded `options`, and only the `outputs` section | Phase 8 | Migration must reject non-output sections and map email options explicitly. |
| VDE `topology_rules.hostname_patterns[].target_tag` + capture group | Correlia literal `tags` only, with planned `tag_capture_groups` extension | Phase 8 | Preserves hostname-derived topology without introducing template syntax ambiguity. |
| VDE `actions: ["email-ops"]` string list | Correlia action objects `{name, plugin}` with `name` in `known_actions` | v1.0 / Phase 8 | Migration must produce valid action objects; `name` defaults to `create_incident`. |
| VDE `match.severity` bare list | Correlia `match.severities` validated against `Severity` enum | Phase 8 | Rename and validate each value. |

**Deprecated/outdated:**
- `.planning/research/CONFIG.md` recommends emitting `.env.example` placeholders and optionally `--smtp-username-env` flags. This is **superseded by D-04–D-06**; Phase 8 must fail-closed on plaintext credentials and must not emit placeholder syntax in `plugins.yaml`.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | VDE `use_tls` means STARTTLS and maps to Correlia `start_tls: true`. | Standard Stack / Code Examples | If Vigilo deployments use `use_tls` for implicit TLS on port 465, generated config will connect incorrectly. Recommend planner treat explicit `use_tls: true` as `start_tls: true` and `use_tls: false` as `start_tls: false`, and note the assumption. |
| A2 | VDE priorities are unique. | Common Pitfall 1 | If duplicate priorities exist, the inversion/ranking strategy must handle ties or fail. Correlia's loader rejects duplicate priorities. |
| A3 | All VDE rule actions dispatch to output plugins and can use the action name `create_incident`. | Phase Requirements / CFG-02 | If Vigilo uses different action semantics, the migration may need to widen `known_actions`; planner discretion applies. |

## Open Questions

1. **How should priority values be transformed?**
   - What we know: Vigilo higher-first, Correlia lower-first; both require unique values.
   - What's unclear: Whether to invert numeric priorities, assign rank order, or require operators to renumber.
   - Recommendation: Default to rank inversion so Vigilo `100, 50, 10` become Correlia `1, 2, 3`, preserving evaluation order. Document the mapping in `CONFIGURATION.md` and the CLI help.

2. **Should `tag_capture_groups` be optional or default to `{}`?**
   - What we know: D-09 wants load-time validation; Pydantic strict discipline favors explicit optional fields.
   - What's unclear: Whether an explicit `tag_capture_groups: {}` or omitted field is preferred for readability.
   - Recommendation: Use `tag_capture_groups: dict[str, int] = Field(default_factory=dict)` so existing literal-only rules do not need to change, but migration emits it only when capture groups exist.

3. **What is the exact unsupported-field catalog?**
   - What we know: D-12 lists `min_hosts`, `is_dc_level`, empty actions, non-output plugin sections, LLM config, unsupported plugin types, and plaintext SMTP credentials.
   - What's unclear: Whether `match.service` omission, `match.tags` omission, or other VDE fields (e.g., `email_dry_run`) should be rejected or silently defaulted.
   - Recommendation: Treat omitted optional fields as Correlia defaults; reject any field with no Correlia equivalent or no safe default. Maintain the catalog as a module-level constant in the migration script for easy review.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Python 3.14+ | Runtime | ✓ | 3.14.4 (via `uv run`) | — |
| uv | Package/script runner | ✓ | 0.11.7 | — |
| Pydantic v2 | Config validation | ✓ | 2.13.4 | — |
| PyYAML | YAML parse/emit | ✓ | 6.0.3 | — |
| PostgreSQL | Existing database-backed test suite | not required for migration-only tests | — | Use only for full-suite runs |
| Docker | Testcontainers | not required for migration-only tests | — | Use only for full-suite runs |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** None.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | pytest 8.x with `pytest-asyncio` (asyncio mode auto) |
| Config file | `pyproject.toml` (`[tool.pytest.ini_options]`) [CITED: pyproject.toml:31-34] |
| Quick run command | `uv run pytest tests/test_vigilo_config_migration.py -x` |
| Full suite command | `make test` → `uv run pytest` [CITED: Makefile:3-4] |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CFG-01 | CLI accepts `--rules`, `--topology`, `--plugins`, `--out-dir` and writes three YAML files | unit | `uv run pytest tests/test_vigilo_config_migration.py::test_cli_generates_files -x` | ❌ Wave 0 |
| CFG-02 | Supported VDE rules map to Correlia strict rule schema | unit | `uv run pytest tests/test_vigilo_config_migration.py::test_migrate_rules -x` | ❌ Wave 0 |
| CFG-03 | Supported VDE topology maps to Correlia strict topology schema | unit | `uv run pytest tests/test_vigilo_config_migration.py::test_migrate_topology -x` | ❌ Wave 0 |
| CFG-04 | Hostname capture groups produce `tag_capture_groups` and enricher applies them | integration (no DB) | `uv run pytest tests/test_vigilo_config_migration.py::test_capture_group_topology -x` | ❌ Wave 0 |
| CFG-05 | Email output maps to plugin schema and omits plaintext credentials | unit | `uv run pytest tests/test_vigilo_config_migration.py::test_migrate_email_plugin -x` | ❌ Wave 0 |
| CFG-06 | Unsupported fields produce aggregated non-zero exit | unit | `uv run pytest tests/test_vigilo_config_migration.py::test_unsupported_fields_fail -x` | ❌ Wave 0 |
| CFG-07 | Generated files validate through Correlia loaders and plugin instantiation | integration (no DB) | `uv run pytest tests/test_vigilo_config_migration.py::test_generated_files_load_and_instantiate -x` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `uv run pytest tests/test_vigilo_config_migration.py -x`
- **Per wave merge:** `make test`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_vigilo_config_migration.py` — covers CFG-01 through CFG-07.
- [ ] `tests/fixtures/vigilo/` — sample valid and unsupported VDE YAML fixtures.
- [ ] `scripts/migrate_vigilo_config.py` — the CLI entrypoint itself.
- [ ] `app/config/topology.py` — add `tag_capture_groups` schema + validation.
- [ ] `app/processing/enrichment.py` — apply capture groups in `StaticTopologyEnricher`.

## Security Domain

Phase 8 does not introduce authentication, session management, or access control. It does handle credential-bearing input and produces filesystem artifacts.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|------------------|
| V2 Authentication | no | Not touched in this phase. |
| V3 Session Management | no | Not touched in this phase. |
| V4 Access Control | no | Not touched in this phase. |
| V5 Input Validation | yes | Parse Vigilo YAML into strict Correlia schemas; fail fast on unsupported fields and malformed values using Pydantic. |
| V6 Cryptography | no | `config_hash` uses SHA-256 for change detection, not for security. |
| V8 File Upload | partial | The CLI reads operator-supplied YAML files; it must reject non-YAML paths (D-01) and never execute plugin class paths during migration. |

### Known Threat Patterns for the Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Plaintext credential leakage in generated YAML | Information disclosure | Fail-closed on `smtp_username`/`smtp_password`; do not write partial output (D-04, D-14). |
| Arbitrary code execution via malicious `class_path` | Elevation of privilege | Migration must not import or instantiate plugin classes; validation is done through `class_path` string prefix checks and loader validation, not dynamic import. |
| Overwriting operator config with partial/corrupt files | Tampering | Stage in temp dir, validate, then atomic move to `--out-dir` (D-14). |
| Secret exposure in logs | Information disclosure | Use `safe_log_extra` and avoid logging raw source payloads or credential-adjacent fields [CITED: app/processing/logging.py:61-70]. |

## Sources

### Primary (HIGH confidence — current codebase)
- `app/config/rules.py` — strict rule schema, `known_actions`, `known_plugins`, summary variable validation, loader.
- `app/config/topology.py` — strict topology schema, hostname/subnet compilation, overlap rejection.
- `app/config/plugins.py` — strict plugin registry, `PluginRegistryEntry`, option validation, config hash.
- `app/plugins/outputs/email.py` — `SmtpOutputOptions` and TLS/credential validation.
- `app/processing/enrichment.py` — `StaticTopologyEnricher` literal-tag application.
- `app/processing/rule_engine.py` — priority sort order and summary rendering.
- `app/domain/events.py` — `Severity`, `TagKey`, `TagValue` bounds.
- `app/processing/logging.py` — `safe_log_extra` for safe structured logging.
- `app/main.py` — startup load order for plugins, rules, topology.

### Secondary (MEDIUM confidence — project documentation and VDE sample)
- `08-CONTEXT.md` — user-locked decisions D-01 through D-15 and scope boundary.
- `compatibility research (removed for privacy)` §3 — original migration command target and constraints.
- `CONFIGURATION.md` — sample Correlia configs and porting notes (with noted drift on credential handling).
- `.planning/research/CONFIG.md` — VDE-to-Correlia field mappings and fail-fast catalog (with noted drift on `.env.example`/env-reference recommendations).
- `../vde-event-aggregation/config/{rules,topology,plugins}.yaml` — concrete Vigilo sample input shapes.

### Tertiary (LOW confidence — assumed)
- VDE `use_tls` semantics = STARTTLS (see Assumptions Log A1).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — dependencies are already pinned and verified in the project lockfile and runtime.
- Architecture: HIGH — derived directly from existing loaders and the user-locked context.
- Pitfalls: HIGH — each pitfall is grounded in a specific code behavior (priority sort, exact tag matching, loader vs. instantiation gap, capture-group absence).

**Research date:** 2026-06-18
**Valid until:** 2026-07-18 (stable; revisit only if Correlia config schemas change before implementation)

## RESEARCH COMPLETE
