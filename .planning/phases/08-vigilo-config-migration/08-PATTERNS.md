# Phase 8: Vigilo Config Migration - Pattern Map

**Mapped:** 2026-06-18
**Files analyzed:** 11 (1 new CLI script, 2 modified production files, 1 new test file, 7 new fixtures)
**Analogs found:** 11 / 11

This phase is a translation deliverable: one new CLI script, two production-code extensions (topology schema + enricher), one new test module, and a small set of Vigilo YAML fixtures. The script's value is **fail-closed translation and re-use of Correlia's strict loaders**; it must not re-implement validation. The two production extensions (`tag_capture_groups`) are coordinated additions to the existing Pydantic model + dataclass + enricher trio that the loaders already return.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/migrate_vigilo_config.py` (new) | CLI script | read-YAML → validate → stage → atomic write | `app/main.py:129-153` startup loader chain + `app/config/{rules,topology,plugins}.py` loader signatures | exact (functional pattern); no `scripts/` analog exists |
| `app/config/topology.py` (modify) | config schema / loader | YAML → strict Pydantic → `CompiledTopologyConfig` | same file, existing `HostnameTopologyRule` and `load_topology_config` | exact (extend in place) |
| `app/processing/enrichment.py` (modify) | enricher | `NormalizedEvent` → matched `re.Pattern` → `EnrichmentResult` | same file, existing `_apply_rule` and `enrich` | exact (extend in place) |
| `tests/test_vigilo_config_migration.py` (new) | test | pytest + `tmp_path` + `yaml.safe_dump`/loaders | `tests/test_rule_topology_yaml.py` (rule + topology loaders), `tests/test_plugin_registry.py` (plugin registry + instantiation), `tests/test_topology_enrichment.py` (enricher) | exact (composite) |
| `tests/fixtures/vigilo/rules_valid.yaml` (new) | fixture | valid VDE rules shape | `tests/test_rule_topology_yaml.py:22-68` `_valid_rule_yaml()` body (Correlia target) | exact (Correlia target shape) |
| `tests/fixtures/vigilo/rules_min_hosts.yaml` (new) | fixture | VDE rule with `min_hosts` (unsupported) | `tests/test_rule_topology_yaml.py:121-127` `test_load_rules_config_rejects_extra_keys` | exact (extra-key rejection shape) |
| `tests/fixtures/vigilo/rules_is_dc_level.yaml` (new) | fixture | VDE rule with `is_dc_level` (unsupported) | `tests/test_rule_topology_yaml.py:121-127` `test_load_rules_config_rejects_extra_keys` (same analog: both are unknown VDE fields) | exact (extra-key rejection shape) |
| `tests/fixtures/vigilo/rules_empty_actions.yaml` (new) | fixture | VDE rule with `actions: []` (unsupported) | `app/config/rules.py:56-62` `RuleDefinitionConfig._actions_not_empty` validator | exact |
| `tests/fixtures/vigilo/topology_valid.yaml` (new) | fixture | valid VDE topology with capture groups | `tests/test_topology_enrichment.py:42-66` (Correlia target) | exact |
| `tests/fixtures/vigilo/plugins_valid.yaml` (new) | fixture | valid VDE email output (no creds) | `tests/test_plugin_registry.py:36-42` `warning-email` entry (Correlia target, no credentials) | exact (credential-free Correlia target shape) |
| `tests/fixtures/vigilo/plugins_with_credentials.yaml` (new) | fixture | VDE email output with `smtp_username`/`smtp_password` (must fail) | `app/config/plugins.py:11-13` (`_ALLOWED_PLUGIN_TYPES`) + `app/plugins/outputs/email.py:39-50` (TLS/cred validators) | exact |

## Pattern Assignments

### `scripts/migrate_vigilo_config.py` (CLI, file-I/O + transform)

**Role:** Standalone CLI entrypoint. Reads three Vigilo YAML files, preflight-scans, transforms, stages in `tempfile.mkdtemp`, validates via the existing loaders, then `os.replace`s into `--out-dir`.

**Analog stack (composite — no `scripts/` exists in this repo):**

**1. Loader-chain / `known_plugins` injection** — `app/main.py:129-153`
```python
if not hasattr(app.state, "plugin_registry"):
    plugins_path = getattr(app.state.settings, "plugins_path", None)
    app.state.plugin_registry = (
        load_plugin_registry(plugins_path)
        if plugins_path is not None
        else PluginRegistry((), "")
    )

if not hasattr(app.state, "rules_config"):
    rules_path = getattr(app.state.settings, "rules_path", None)
    app.state.rules_config = (
        load_rules_config(
            rules_path,
            known_plugins=frozenset(app.state.plugin_registry.names),
        )
        if rules_path is not None
        else CompiledRuleConfig((), "")
    )

if not hasattr(app.state, "topology_config"):
    topology_path = getattr(app.state.settings, "topology_path", None)
    app.state.topology_config = (
        load_topology_config(topology_path)
        if topology_path is not None
        else CompiledTopologyConfig((), ())
    )
```
**Why:** The migration's CFG-07 step must call the same three loaders in the same dependency order, and pass `known_plugins=frozenset(registry.names)` to `load_rules_config` (otherwise `load_rules_config` accepts any plugin name and the migration looks valid even when the generated `plugins.yaml` does not list the action's plugin). Mirroring this chain is what gives CFG-07 its teeth.

**2. YAML I/O + `config_hash` round-trip** — `app/config/rules.py:197-202` and `app/config/plugins.py:70-76`
```python
config_text = yaml.safe_dump(
    {"rules": [r.model_dump(mode="json") for r in config.rules]}
)
config_hash = hashlib.sha256(config_text.encode()).hexdigest()
```
```python
config_text = yaml.safe_dump(
    {"outputs": [entry.model_dump(mode="json") for entry in config.outputs]},
    sort_keys=True,
)
return CompiledPluginRegistryConfig(
    outputs=tuple(config.outputs),
    config_hash=hashlib.sha256(config_text.encode()).hexdigest(),
)
```
**Why:** The migration emits Correlia-shaped YAML and round-trips through the loaders. The existing loaders treat `yaml.safe_load` + `yaml.safe_dump(sort_keys=True)` as the canonical parse/emit pair; the migration must do the same to avoid drift (e.g., re-serializing Pydantic models via `model_dump(mode="json")` is the established emit pattern; `sort_keys=True` is what makes `config_hash` deterministic).

**3. `tempfile.mkdtemp` + atomic `os.replace`** — stdlib
**Why:** D-14 requires staging, validation, then atomic promotion. There is no project-internal analog for this exact pattern, but the principle ("never leave `--out-dir` partial") is enforced by staging all three files first.

**4. `safe_log_extra` for safe logging** — `app/processing/logging.py:55-69`
```python
def safe_log_extra(**fields: object) -> dict[str, object]:
    extra: dict[str, object] = {}
    for key, value in fields.items():
        if key not in SAFE_LOG_KEYS or key in _RESERVED_LOG_KEYS:
            continue
        if isinstance(value, _SCALAR_TYPES):
            extra[key] = value
        elif value is not None:
            extra[key] = str(value)
    return extra
```
**Why:** The script must log unsupported-field errors and migration counts without ever logging raw source payloads or credential-adjacent fields. `safe_log_extra` enforces a closed allowlist of scalar keys — the exact contract needed for D-13/D-14 reporting.

**5. Settings shape (`CORRELIA_*` env, `Path | None`)** — `app/config/settings.py:9-14`
```python
model_config = SettingsConfigDict(
    env_prefix="CORRELIA_",
    case_sensitive=False,
    extra="forbid",
)
```
**Why:** D-02 says the script mirrors the settings shape. The CLI flag names (`--rules`, `--topology`, `--plugins`, `--out-dir`) and the settings keys (`rules_path`, `topology_path`, `plugins_path`, defined at `app/config/settings.py:17-19`) come from this file.

**6. Priority sort reference (for inversion logic)** — `app/processing/rule_engine.py:10-11`
```python
self._rules = sorted(rules, key=lambda r: r.definition.priority)
```
**Why:** The Pitfall-1 priority inversion issue requires the migration to either invert numeric priorities or document the behavior change. This is the canonical sort order the migration must align with; the corresponding uniqueness constraint is `app/config/rules.py:172-177` (`if rule.priority in priorities: raise ValueError("duplicate priority ...")`).

---

### `app/config/topology.py` (config schema, modify)

**Role:** Add `tag_capture_groups: dict[str, int]` to `HostnameTopologyRule` and carry it through `CompiledHostnameRule`. Validate `>= 1` and `<= pattern.groups` at load time.

**Analog: same file, current `HostnameTopologyRule` + `CompiledHostnameRule` + `load_topology_config`**

**Imports / strict Pydantic setup** — `app/config/topology.py:1-13`
```python
from __future__ import annotations

import re
from dataclasses import dataclass
from ipaddress import IPv4Network, IPv6Network, ip_network
from pathlib import Path

import yaml
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator
```

**`HostnameTopologyRule` shape (current)** — `app/config/topology.py:15-28`
```python
class HostnameTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    id: str
    name: str
    hostname_pattern: str
    tags: dict[str, str]

    @field_validator("tags")
    @classmethod
    def _tags_must_start_with_topology(cls, value: dict[str, str]) -> dict[str, str]:
        for key in value:
            if not key.startswith("topology."):
                raise ValueError(f"tag key must start with 'topology.': {key}")
        return value
```
**Extension pattern:** Add `tag_capture_groups: dict[str, int] = Field(default_factory=dict)` and a `@field_validator("tag_capture_groups")` that checks `>= 1` (the `<= pattern.groups` check needs the compiled pattern, so it lives in the loader, not the Pydantic validator). Reuse the exact `_tags_must_start_with_topology` validator on the capture-group keys (D-07 requires the `topology.` prefix).

**`CompiledHostnameRule` shape (current)** — `app/config/topology.py:70-76`
```python
@dataclass(frozen=True, slots=True)
class CompiledHostnameRule:
    id: str
    name: str
    pattern: re.Pattern[str]
    tags: dict[str, str]
```
**Extension pattern:** Add `tag_capture_groups: dict[str, int]` (the compiled representation; the loader has already done the pattern-group-count check).

**`load_topology_config` pattern compilation loop (current)** — `app/config/topology.py:97-121`
```python
def load_topology_config(path: Path) -> CompiledTopologyConfig:
    data = yaml.safe_load(path.read_text())
    if data is None:
        data = {}
    config = TopologyConfig.model_validate(data)

    compiled_hostname_rules: list[CompiledHostnameRule] = []
    for hostname_rule in config.hostname_rules:
        try:
            pattern = re.compile(hostname_rule.hostname_pattern)
        except re.error as exc:
            raise ValueError(
                f"Invalid regex in hostname rule '{hostname_rule.id}': "
                f"{hostname_rule.hostname_pattern}"
            ) from exc
        compiled_hostname_rules.append(
            CompiledHostnameRule(
                id=hostname_rule.id,
                name=hostname_rule.name,
                pattern=pattern,
                tags=dict(hostname_rule.tags),
            )
        )
```
**Extension pattern:** Inside the loop, after `pattern = re.compile(...)`, validate that every key in `hostname_rule.tag_capture_groups` has an index `>= 1 and <= pattern.groups`, raising `ValueError` (matches the existing error format). Then pass `tag_capture_groups=dict(hostname_rule.tag_capture_groups)` into the `CompiledHostnameRule` constructor. Subnet rules (D-11) stay as-is — no new field on `SubnetTopologyRule` or `CompiledSubnetRule`.

---

### `app/processing/enrichment.py` (enricher, modify)

**Role:** When a hostname rule matches, also resolve the regex match groups referenced in `tag_capture_groups` and apply them after literal `tags`. Skip empty/None captures; bound by the existing `TagValue` length.

**TagValue length reference:** `app/domain/events.py:30` defines
```python
TagValue = Annotated[str, Field(min_length=1, max_length=256)]
```
`TagValue` is an `Annotated` alias, not a class with a public `MAX_LEN` constant. The enricher must use the literal `256` (a comment on the check should cite `app/domain/events.py:30` to keep the two values in sync). The `app.processing.enrichment` module already imports from `app.domain.events` (line 7: `from app.domain.events import NormalizedEvent`), so reusing the alias by extending the import to also pull `TagValue` is a one-line, no-cycle addition.

**Analog: same file, current `enrich` and `_apply_rule`**

**Imports (current)** — `app/processing/enrichment.py:1-7`
```python
from __future__ import annotations

from dataclasses import dataclass, field
from ipaddress import ip_address

from app.config.topology import CompiledHostnameRule, CompiledSubnetRule, CompiledTopologyConfig
from app.domain.events import NormalizedEvent
```

**Hostname-match dispatch (current)** — `app/processing/enrichment.py:31-35`
```python
async def enrich(self, event: NormalizedEvent) -> EnrichmentResult:
    # Try hostname rules first (D-09: hostname precedence)
    for hostname_rule in self._config.hostname_rules:
        if hostname_rule.pattern.match(event.host):
            return self._apply_rule(event, hostname_rule, "hostname")
```
**Extension pattern:** Capture the `re.Match` (e.g., `match = hostname_rule.pattern.match(event.host)`), and pass it into `_apply_rule` only for hostname rules. Subnet rules never have capture groups, so the subnet branch stays unchanged. The cleanest refactor is `_apply_hostname_rule(event, rule, match)` vs. `_apply_subnet_rule(event, rule)`, with a shared private helper for the literal-tag application — but the minimal-diff approach is to add an optional `match: re.Match[str] | None` parameter to `_apply_rule`.

**`_apply_rule` literal-tag loop (current)** — `app/processing/enrichment.py:54-75`
```python
def _apply_rule(
    self,
    event: NormalizedEvent,
    rule: CompiledHostnameRule | CompiledSubnetRule,
    match_source: str,
) -> EnrichmentResult:
    tags_added: dict[str, str] = {}
    tags_overridden: list[tuple[str, str, str]] = []
    conflicts: list[tuple[str, str, str]] = []

    new_tags = dict(event.tags)

    for key, value in rule.tags.items():
        if key in new_tags:
            old_value = new_tags[key]
            if old_value != value:
                tags_overridden.append((key, old_value, value))
                conflicts.append((key, old_value, value))
        else:
            tags_added[key] = value
        new_tags[key] = value

    enriched_event = event.model_copy(update={"tags": new_tags})
```
**Extension pattern:** After the literal-tag loop and before the `event.model_copy` line, for hostname rules only, iterate `rule.tag_capture_groups` and look up `match.group(group_index)`. Skip `None` and empty strings (D-09). For the non-empty case, enforce the `TagValue` length cap (256) explicitly via `if len(captured) > 256: raise ValueError(...)` — the literal `256` mirrors the `max_length=256` in `TagValue = Annotated[str, Field(min_length=1, max_length=256)]` at `app/domain/events.py:30`; a comment on the check should cite that line so the two stay in sync. Apply the same `tags_added` / `tags_overridden` / `conflicts` accounting reused above; the loader already enforced the `topology.` prefix on capture-group keys.

---

### `tests/test_vigilo_config_migration.py` (test, new)

**Role:** Covers CFG-01 through CFG-07: CLI flag handling, rule/topology/plugin transforms, capture-group topology, unsupported-field aggregation, atomic-staging behavior, and end-to-end loader round-trip + `SmtpOutputPlugin` instantiation.

**Analog stack (composite of three existing test files):**

**1. `tmp_path` + `yaml.safe_dump` + `load_*_config` shape** — `tests/test_rule_topology_yaml.py:78-90`
```python
def test_load_rules_config_accepts_valid_yaml(tmp_path: Path) -> None:
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(_valid_rule_yaml()))
    config = load_rules_config(path)
    assert len(config.rules) == 2
    assert config.rules[0].definition.name == "critical-web"
    assert config.rules[0].definition.priority == 10
    assert config.rules[1].definition.name == "warning-db"
    assert config.rules[1].definition.priority == 20
    assert config.config_hash is not None
```
**Why:** Every loader test uses the `tmp_path / "x.yaml" → path.write_text(yaml.safe_dump(...)) → load_*_config(path)` pattern. The migration test must do the same for both directions: emit YAML in the migration, then load it back through the same loader.

**2. Parametrized rejection tests with `pytest.raises(ValueError, match=...)`** — `tests/test_rule_topology_yaml.py:121-127`
```python
def test_load_rules_config_rejects_extra_keys(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["extra_field"] = "nope"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)
```
**Why:** The unsupported-field test cases (`min_hosts`, `is_dc_level`, empty actions, plaintext SMTP creds) follow this exact shape — write a fixture, run the loader, assert the right `ValueError` matches.

**3. Plugin instantiation in tests** — `tests/test_plugin_registry.py:20-61`
```python
def test_registry_loads_named_outputs_caches_instances_and_lists_safe_status(tmp_path: Path) -> None:
    registry_path = write_registry(
        tmp_path / "plugins.yaml",
        """
outputs:
  - name: critical-email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      host: localhost
      port: 1025
      from_address: correlia@example.test
      to_addresses: [ops@example.test]
      password: super-secret
      username: operator
      start_tls: true
""",
    )
    registry = load_plugin_registry(registry_path)
    critical = registry.get_plugin("critical-email")
    assert isinstance(critical, SmtpOutputPlugin)
```
**Why:** Pitfall 3 in the research says `load_plugin_registry_config` accepts any scalar options — it does not instantiate `SmtpOutputPlugin`. CFG-07's "validate generated files" step must call `load_plugin_registry(staging / "plugins.yaml")` and instantiate (or call `SmtpOutputOptions.model_validate(options)`) to catch the TLS/credential rules that the registry loader misses. The pattern above is the canonical instantiator.

**4. Enricher pattern with `load_topology_config` + `StaticTopologyEnricher`** — `tests/test_topology_enrichment.py:42-66`
```python
def test_load_topology_config_accepts_valid_hostname_rules(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web", "topology.site": "dc1"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    assert rule.tags == {"topology.role": "web", "topology.site": "dc1"}
```
**Why:** The capture-group test (`test_capture_group_topology`) follows the same shape — write a topology YAML with `tag_capture_groups`, load, enrich an event whose hostname matches the regex, assert the captured group appears in `result.event.tags` and in `result.diagnostics[0].tags_added`.

**5. Diagnostic assertions on conflict/override behavior** — `tests/test_topology_enrichment.py:418-443`
```python
result = await enricher.enrich(event)
assert result.event.tags["topology.role"] == "web"
assert result.event.tags["team.name"] == "platform"
assert len(result.diagnostics) == 1
diag = result.diagnostics[0]
assert diag.tags_overridden == [("topology.role", "old-value", "web")]
assert diag.conflicts == [("topology.role", "old-value", "web")]
```
**Why:** D-08 says derived tags merge *after* literal tags, overriding if both present. The diagnostic-assertion shape above is the exact pattern to assert that a hostname rule's `tag_capture_groups` correctly overrides a pre-existing event tag of the same key.

---

### `tests/fixtures/vigilo/rules_valid.yaml` (fixture, new)

**Role:** Valid VDE rules input that maps to a passing `rules.yaml` after migration. The fixture **shape** analog is the Correlia target, not the VDE source.

**Analog: `tests/test_rule_topology_yaml.py:22-68` `_valid_rule_yaml()` body (full function, verbatim)**
```python
def _valid_rule_yaml() -> dict[str, object]:
    return {
        "rules": [
            {
                "name": "critical-web",
                "priority": 10,
                "match": {
                    "severities": ["CRITICAL"],
                    "host_pattern": "web-.*",
                    "service_pattern": "http",
                    "tags": {"team.name": "platform"},
                },
                "window": {
                    "duration_seconds": 300,
                    "group_by": ["topology.site", "service"],
                    "trigger_threshold": 3,
                },
                "output_summary": "Critical web alert on {host} at {topology.site}",
                "actions": [
                    {"name": "create_incident", "plugin": "default_output"},
                ],
            },
            {
                "name": "warning-db",
                "priority": 20,
                "match": {
                    "severities": ["WARNING", "CRITICAL"],
                    "host_pattern": "db-.*",
                    "tags": {},
                },
                "window": {
                    "duration_seconds": 600,
                    "group_by": ["host"],
                    "trigger_threshold": 1,
                },
                "output_summary": "DB alert: {message}",
                "actions": [
                    {"name": "create_incident", "plugin": "default_output"},
                ],
            },
        ]
    }
```
**Why:** The test's "valid Correlia rules" fixture shows the exact post-migration shape the migration must produce. The VDE source fixture (`rules_valid.yaml`) is the **inverse** direction — VDE `severity: ["CRITICAL", "WARNING"]` must migrate to Correlia `severities: [...]`; VDE `actions: ["email-ops"]` must migrate to `actions: [{name: "create_incident", plugin: "email-ops"}]`.

---

### `tests/fixtures/vigilo/rules_min_hosts.yaml` (fixture, new)

**Role:** VDE rule with `min_hosts: N` — must trigger the unsupported-field preflight error.

**Analog: `tests/test_rule_topology_yaml.py:121-127` extra-keys rejection**
```python
def test_load_rules_config_rejects_extra_keys(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["extra_field"] = "nope"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)
```
**Why:** `min_hosts` is a VDE-only field with no Correlia equivalent. Even if the migration silently dropped it, the resulting YAML would be accepted (it has no extra keys). The test must assert that the **migration** rejects it during preflight, not that the loader does — the fixture's value is that it forces the migration's preflight path, not the loader's `extra="forbid"` validator.

---

### `tests/fixtures/vigilo/rules_is_dc_level.yaml` (fixture, new)

**Role:** VDE rule with `is_dc_level: true` — must trigger the unsupported-field preflight error.

**Analog: `tests/test_rule_topology_yaml.py:121-127` extra-keys rejection (same shape — `is_dc_level` is an unknown VDE-only field, just like `min_hosts` and `extra_field`)**
```python
def test_load_rules_config_rejects_extra_keys(tmp_path: Path) -> None:
    data = _valid_rule_yaml()
    data["rules"][0]["extra_field"] = "nope"
    path = tmp_path / "rules.yaml"
    path.write_text(yaml.safe_dump(data))
    with pytest.raises(ValueError):
        load_rules_config(path)
```
**Why:** `is_dc_level` is a VDE-only field with no Correlia equivalent. Even if the migration silently dropped it, the resulting YAML would be accepted (it has no extra keys). The test must assert that the **migration** rejects it during preflight, not that the loader does — the fixture's value is that it forces the migration's preflight path, not the loader's `extra="forbid"` validator. The migration preflight list (`_UNSUPPORTED_RULE_FIELDS`) covers both `min_hosts` and `is_dc_level`; the fixture simply exercises a different key on the same analog test.

---

### `tests/fixtures/vigilo/rules_empty_actions.yaml` (fixture, new)

**Role:** VDE rule with `actions: []` — must trigger preflight (D-12 lists empty actions as unsupported; Pydantic also rejects them but with a generic message).

**Analog: `app/config/rules.py:56-62` `RuleDefinitionConfig._actions_not_empty`**
```python
@field_validator("actions", mode="after")
@classmethod
def _actions_not_empty(cls, value: list[RuleActionConfig]) -> list[RuleActionConfig]:
    if not value:
        raise ValueError("actions must not be empty")
    return value
```
**Why:** The Pydantic validator would catch this, but D-12 demands the **preflight** catch it first so the error message references the VDE field name and rule index, not a generated-file `actions: []` line number. The fixture's value is exercising the preflight scan, not the loader.

---

### `tests/fixtures/vigilo/topology_valid.yaml` (fixture, new)

**Role:** VDE topology with at least one entry that has a parenthesized regex group and a `target_tag`, plus one entry without (to exercise both D-10 literal-tags and D-10 capture-group branches).

**Analog: `tests/test_topology_enrichment.py:42-66` (Correlia target)**
```python
def test_load_topology_config_accepts_valid_hostname_rules(tmp_path: Path) -> None:
    path = tmp_path / "topology.yaml"
    path.write_text(
        yaml.safe_dump(
            {
                "hostname_rules": [
                    {
                        "id": "web-servers",
                        "name": "Web Servers",
                        "hostname_pattern": "^web-.*",
                        "tags": {"topology.role": "web", "topology.site": "dc1"},
                    }
                ],
                "subnet_rules": [],
            }
        )
    )
    config = load_topology_config(path)
    assert rule.tags == {"topology.role": "web", "topology.site": "dc1"}
```
**Why:** The VDE source shape has `hostname_patterns: [{name, regex, target_tag}]`; the migration must produce a Correlia `hostname_rules: [{id, name, hostname_pattern, tags, tag_capture_groups}]` of the shape above. The fixture drives the migration transform, not the loader.

---

### `tests/fixtures/vigilo/plugins_valid.yaml` (fixture, new)

**Role:** VDE email output **without** SMTP credentials. Maps to a valid Correlia `plugins.yaml` whose `options` carry `host`/`port`/`to_addresses` only (other fields fall back to `SmtpOutputOptions` defaults at `app/plugins/outputs/email.py:18-30`).

**Analog: `tests/test_plugin_registry.py:36-42` `warning-email` entry (credential-free)**
```yaml
  - name: warning-email
    plugin_type: email
    class_path: app.plugins.outputs.email.SmtpOutputPlugin
    options:
      host: localhost
      port: 1025
      to_addresses: [noc@example.test]
```
**Why:** This is the credential-free Correlia target shape the migration must produce (the `warning-email` block has no `username`/`password`/`start_tls` keys; the unsupplied options fall back to `SmtpOutputOptions` defaults at `app/plugins/outputs/email.py:18-30`, including `from_address="correlia@localhost"` and `to_addresses=["ops@localhost"]` only when the entry omits them). The VDE source fixture's value is that it has no `smtp_username`/`smtp_password` keys, so the migration passes D-04's preflight.

---

### `tests/fixtures/vigilo/plugins_with_credentials.yaml` (fixture, new)

**Role:** VDE email output **with** `smtp_username`/`smtp_password`. Must trigger the fail-closed preflight error (D-04).

**Analog: `app/config/plugins.py:11-13` + `app/plugins/outputs/email.py:40-50`**
```python
_ALLOWED_PLUGIN_TYPES = frozenset({"email"})
_ALLOWED_CLASS_PREFIX = "app.plugins.outputs."
_ALLOWED_OPTION_TYPES = (str, int, float, bool, type(None))
```
```python
@model_validator(mode="after")
def require_tls_for_credentials(self) -> "SmtpOutputOptions":
    has_username = self.username is not None
    has_password = self.password is not None
    if has_username != has_password:
        raise ValueError("SMTP username and password must be configured together")
    if not has_username:
        return self
    if not (self.use_tls or self.start_tls is True):
        raise ValueError("authenticated SMTP requires explicit TLS or STARTTLS")
    if not self.validate_certs:
        raise ValueError("authenticated SMTP requires certificate validation")
    return self
```
**Why:** The plugin loader accepts any scalar option value, so `smtp_username: "literal-password"` would pass `load_plugin_registry_config` even though the migration is supposed to reject it. The preflight is what enforces D-04 — the fixture's job is to ensure that branch is exercised. The `SmtpOutputOptions` validators above are a secondary safety net for the test that confirms the **generated** (credential-free) YAML still instantiates correctly.

---

## Shared Patterns

### A. Strict Pydantic config surface

**Source:** every `app/config/*.py` loader
**Apply to:** `app/config/topology.py` (the new `tag_capture_groups` field must use `ConfigDict(strict=True, extra="forbid")`, `Field(default_factory=dict)`, and a `@field_validator`)

```python
class HostnameTopologyRule(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")
```
(Quoted from `app/config/topology.py:15-17`.)

**Apply to:** the migration script's preflight dataclasses if any (preferred: keep them as plain dicts and rely on the loaders for shape enforcement — see Pattern 1 in RESEARCH).

### B. `yaml.safe_load` + `yaml.safe_dump(sort_keys=True)` round-trip

**Source:** `app/config/rules.py:197-202`, `app/config/plugins.py:70-76`
**Apply to:** the migration script's emit step

```python
config_text = yaml.safe_dump(
    {"rules": [r.model_dump(mode="json") for r in config.rules]}
)
config_hash = hashlib.sha256(config_text.encode()).hexdigest()
```
(Quoted from `app/config/rules.py:197-201`.)
**Note:** The migration emits **before** the loader runs (it's the input to the loader, not its output), so the migration should `yaml.safe_dump({"rules": [transformed_rule, ...]}, sort_keys=True)` and let the loader compute the hash. `sort_keys=True` is what makes `config_hash` deterministic across re-runs.

### C. `safe_log_extra` for closed-allowlist logging

**Source:** `app/processing/logging.py:55-69`
**Apply to:** the migration script's stderr / `--report-path` output

```python
def safe_log_extra(**fields: object) -> dict[str, object]:
    extra: dict[str, object] = {}
    for key, value in fields.items():
        if key not in SAFE_LOG_KEYS or key in _RESERVED_LOG_KEYS:
            continue
        if isinstance(value, _SCALAR_TYPES):
            extra[key] = value
        elif value is not None:
            extra[key] = str(value)
    return extra
```
(Quoted from `app/processing/logging.py:55-69`.)
**Why:** D-12/D-13 require structured reporting without leaking source payloads or credentials. The migration should pipe its counts / file paths / rule indices through `safe_log_extra` rather than f-strings into `logger.info`, even though it's a CLI script.

### D. Settings shape (`CORRELIA_*` env prefix, `Path | None`)

**Source:** `app/config/settings.py:9-19`
**Apply to:** the migration script's CLI flag naming and env-var handling (D-02)

```python
model_config = SettingsConfigDict(
    env_prefix="CORRELIA_",
    case_sensitive=False,
    extra="forbid",
)
```
(Quoted from `app/config/settings.py:9-13`. The `rules_path: Path | None = None`, `topology_path: Path | None = None`, `plugins_path: Path | None = None` fields that D-02 requires the CLI to mirror are at `app/config/settings.py:17-19`.)

### E. `known_plugins` injection in `load_rules_config`

**Source:** `app/main.py:140-143` and `app/config/rules.py:158-165`
**Apply to:** the migration's CFG-07 step (must call loaders in the same dependency order)

```python
load_rules_config(
    rules_path,
    known_plugins=frozenset(app.state.plugin_registry.names),
)
```
(Quoted from `app/main.py:140-143`.)

### F. Atomic staging via `tempfile.mkdtemp` + `os.replace`

**Source:** stdlib (no in-repo analog)
**Apply to:** the migration's `--out-dir` step (D-14)
**Pattern:** `tempfile.mkdtemp()` → write all three YAMLs into the temp dir → call the three loaders → on success, `os.replace` each file into `--out-dir` (or replace the whole temp dir); on any failure, `shutil.rmtree` the temp dir and exit non-zero.

### G. Priority inversion (Pitfall 1)

**Source:** `app/processing/rule_engine.py:9-12` and `app/config/rules.py:172-177`
**Apply to:** the rule-transform step in the migration

```python
def __init__(self, rules: list[CompiledRule]) -> None:
    self._rules = sorted(rules, key=lambda r: r.definition.priority)
```
(Quoted from `app/processing/rule_engine.py:9-12`.)
```python
if rule.priority in priorities:
    raise ValueError(
        f"duplicate priority {rule.priority} in rule '{rule.name}'"
    )
```
(Quoted from `app/config/rules.py:172-176`.)
**Why:** Vigilo priority is higher-first; Correlia is lower-first. Either the migration inverts (e.g., sort descending by VDE priority, assign `1, 2, 3…`) or the planner must accept the behavior change. Either way, the generated priorities must be unique (`load_rules_config` rejects duplicates).

### H. `SmtpOutputPlugin` instantiation in CFG-07 verification

**Source:** `tests/test_plugin_registry.py:53-58` and `app/plugins/outputs/email.py:53-79`
**Apply to:** the migration's plugin-validation step (Pitfall 3: `load_plugin_registry_config` does not instantiate; need `SmtpOutputOptions.model_validate(options)` or `load_plugin_registry(staging / "plugins.yaml")` to catch TLS/credential errors)

```python
critical = registry.get_plugin("critical-email")
assert isinstance(critical, SmtpOutputPlugin)
```
(Quoted from `tests/test_plugin_registry.py:55-58`; `critical = ...` on line 55, the `assert` on line 58.)

---

## No Analog Found

None. Every planned file in this phase has at least one exact analog (same file for production edits, `tmp_path` + `yaml.safe_dump` for tests/fixtures, the loader chain + `safe_log_extra` for the CLI).

## Metadata

**Analog search scope:** `app/config/{rules,topology,plugins,settings}.py`, `app/processing/{enrichment,logging,rule_engine}.py`, `app/plugins/outputs/email.py`, `app/main.py`, `app/domain/events.py`, `tests/test_rule_topology_yaml.py`, `tests/test_plugin_registry.py`, `tests/test_topology_enrichment.py`.
**Files scanned:** 14
**Pattern extraction date:** 2026-06-18

## PATTERN MAPPING COMPLETE
