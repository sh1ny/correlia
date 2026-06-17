# Config Migration Research: Correlia v1.1 Vigilo/VDE Compatibility

**Scope:** Map Vigilo/VDE YAML configuration to Correlia's strict Pydantic config loaders, identify fail-fast incompatibilities, and define how a `scripts/migrate_vigilo_config.py` command should produce valid Correlia config files.

**Source documents:** `VIGILO_COMPATIBILITY.md`, `CONFIGURATION.md`.

---

## Evidence

### Correlia config loaders (canonical targets)

| File | Key symbols | Behavior |
|------|-------------|----------|
| `app/config/settings.py` | `Settings` (`rules_path`, `topology_path`, `plugins_path`, `database_url`, `env_prefix="CORRELIA_"`, `extra="forbid"`) | Config files are pointed at via `CORRELIA_RULES_PATH`, `CORRELIA_TOPOLOGY_PATH`, `CORRELIA_PLUGINS_PATH`. `DATABASE_URL` is required. |
| `app/config/rules.py` | `MatchCriteriaConfig`, `RuleActionConfig`, `RuleWindowConfig`, `RuleDefinitionConfig`, `RuleConfig`, `load_rules_config` | Strict Pydantic schemas (`extra="forbid"`). Actions must be non-empty. Rule names and priorities must be unique. Summary variables are validated against known normalized fields or tag-key regex. |
| `app/config/topology.py` | `HostnameTopologyRule`, `SubnetTopologyRule`, `TopologyConfig`, `load_topology_config` | Tag keys must start with `topology.`. Overlapping subnets with different tags are rejected. Hostname patterns are compiled as regex. |
| `app/config/plugins.py` | `PluginRegistryEntry`, `PluginRegistryConfigFile`, `load_plugin_registry_config` | Only `outputs` section. `plugin_type` must be `"email"`. `class_path` must be under `app.plugins.outputs.`. Options are bounded scalars/lists. |
| `app/plugins/outputs/email.py` | `SmtpOutputOptions`, `SmtpOutputPlugin` | Supports `host`, `port`, `from_address`, `to_addresses`, `subject_prefix`, `username`, `password`, `use_tls`, `start_tls`, `validate_certs`, `timeout`. Credentials require TLS/STARTTLS and cert validation. |
| `app/main.py` | `lifespan` | Loads plugins, rules, topology in order at startup. Rules are loaded with `known_plugins=frozenset(plugin_registry.names)`. |

### VDE config sources

| File | Key symbols | Behavior |
|------|-------------|----------|
| `config/rules.yaml` | `rules[].match.severity`, `host`, `service`, `tags`, `window.min_hosts`, `is_dc_level`, `actions[]` | `severity` is a list, `host`/`service`/`tags` support fnmatch wildcards, `min_hosts` adds an extra threshold, `is_dc_level` enables suppression, actions are plugin-name strings. |
| `config/topology.yaml` | `topology_rules.hostname_patterns[]` (`regex`, `target_tag`), `ip_subnets[]` (`cidr`, `value`, `target_tag`) | Hostname patterns use regex capture group 1 to derive the tag value. Subnets assign a static value. Target tags are bare (e.g. `datacenter`). |
| `config/plugins.yaml` | `task_runner`, `inputs`, `outputs`, `llm`, `enrichers`, `processor` | Outputs are the only section with a Correlia equivalent today. `llm`, `enrichers`, `processor`, `inputs`, and `task_runner` have no config target yet. |
| `app/core/config.py` | `Settings` (`api_token`, `dev_mode`, `database_url`, `rules_config_path`, `topology_config_path`, `plugins_config_path`, `email_dry_run`) | `API_TOKEN` is required when `DEV_MODE=false`; min 32 chars. |
| `app/plugins/enrichers/topology.py` | `_match_hostname`, `_match_ip` | Confirms VDE hostname enrichment uses `match.group(1)` and bare target tags; subnets use static `value`. |
| `app/core/rules.py` | `_match_pattern`, `_match_tags` | Confirms VDE uses `fnmatch.fnmatch` and wildcard `*`. |

---

## VDE → Correlia Mappings

### 1. Rules (`config/rules.yaml`)

| VDE field | Correlia field | Transform | Notes |
|-----------|----------------|-----------|-------|
| `rules[].name` | `rules[].name` | pass-through | Must be unique. |
| `rules[].priority` | `rules[].priority` | pass-through | Must be unique int. |
| `rules[].match.severity` | `rules[].match.severities` | rename; validate each value ∈ `{OK, WARNING, UNKNOWN, CRITICAL}` | Correlia requires a non-empty list. If VDE omits severity, fail (no "match any" equivalent). |
| `rules[].match.host` | `rules[].match.host_pattern` | omitted → `".*"`; else translate fnmatch wildcards to regex (`*` → `.*`, `?` → `.`) | Correlia uses `re.match` (prefix match). Simple wildcards translate safely; complex fnmatch features must fail. |
| `rules[].match.service` | `rules[].match.service_pattern` | omitted → omit field; else translate fnmatch → regex | Optional in Correlia. |
| `rules[].match.tags` | `rules[].match.tags` | key → `topology.<key>` if not already prefixed; value must be literal | Correlia does exact-equality tag matching. Any wildcard (`*`, `?`) in tag values must fail. |
| `rules[].window.duration_seconds` | `rules[].window.duration_seconds` | pass-through | `>= 1`. |
| `rules[].window.group_by` | `rules[].window.group_by` | rewrite tag references to `topology.<tag>`; keep `host`/`service` | Correlia resolves unknown fields via `event.tags.get(field)`. |
| `rules[].window.trigger_threshold` | `rules[].window.trigger_threshold` | pass-through | `>= 1`. |
| `rules[].output_summary` | `rules[].output_summary` | rewrite `{datacenter}` → `{topology.datacenter}`; keep normalized fields (`host`, `service`, etc.) | Validated against `_KNOWN_NORMALIZED_FIELDS` and tag-key regex. |
| `rules[].actions[]` (string) | `rules[].actions[]` object | `{name: "create_incident", plugin: <plugin_name>}` | Correlia actions must be non-empty. `name` must be in `known_actions` (default `{create_incident}`). The plugin name is what actually gets dispatched. |
| `rules[].window.min_hosts` | — | **unsupported** | Fail fast. |
| `rules[].is_dc_level` | — | **unsupported** | Fail fast when `true`. |
| `rules[].actions: []` | — | **unsupported** | Fail fast unless a no-op output plugin is introduced. |

### 2. Topology (`config/topology.yaml`)

| VDE field | Correlia field | Transform | Notes |
|-----------|----------------|-----------|-------|
| `topology_rules.hostname_patterns[].name` | `hostname_rules[].name` | pass-through | Generate `id` from a slug of `name` if not provided by VDE. |
| `topology_rules.hostname_patterns[].regex` | `hostname_rules[].hostname_pattern` | pass-through | Must be valid Python regex. |
| `topology_rules.hostname_patterns[].target_tag` | `hostname_rules[].tags` key | `topology.<target_tag>` | **Value is the captured group in VDE**. Current Correlia `StaticTopologyEnricher` assigns static strings only, so VDE patterns with capture groups require either enricher enhancement or manual expansion. |
| `topology_rules.ip_subnets[].cidr` | `subnet_rules[].subnet` | pass-through | Validated as CIDR. |
| `topology_rules.ip_subnets[].value` | `subnet_rules[].tags` value | pass-through | Static value. |
| `topology_rules.ip_subnets[].target_tag` | `subnet_rules[].tags` key | `topology.<target_tag>` | — |

### 3. Plugins (`config/plugins.yaml`)

| VDE section | Correlia target | Transform |
|-------------|-----------------|-----------|
| `task_runner` | none | **Fail fast.** Correlia uses a built-in `AsyncIOTaskRunner`. |
| `inputs` | none | **Fail fast.** Correlia has a single built-in Icinga2 ingress path; input plugin slots are future work. |
| `outputs.<name>` | `outputs[]` | `name: <key>`, `plugin_type: "email"`, `class_path: <module>.<class>` mapped into `app.plugins.outputs.*`, `options: <config>` | Unknown plugin types or non-`app.plugins.outputs.` class paths fail. |
| `llm` | none | **Fail fast.** No Correlia config target yet. |
| `enrichers` | none | **Fail fast.** Topology enrichment is configured via `topology.yaml`; LLM enrichers are future work. |
| `processor` | none | **Fail fast.** No LLM processor slot yet. |

#### Email output option mapping

| VDE option | Correlia option | Notes |
|------------|-----------------|-------|
| `smtp_host` | `host` | — |
| `smtp_port` | `port` | — |
| `from_address` | `from_address` | — |
| `to_addresses` | `to_addresses` | list of strings |
| `subject_prefix` | `subject_prefix` | — |
| `use_tls` | `start_tls` | VDE `use_tls` means STARTTLS. Correlia default is `use_tls=false`, `start_tls=null`; migration should set `start_tls: true` when VDE `use_tls` is true/unset, or `start_tls: false` when explicitly false. |
| `smtp_username` | `username` | **Never emit plaintext.** Must be env-reference or omitted. |
| `smtp_password` | `password` | **Never emit plaintext.** Must be env-reference or omitted. |

For the VDE `EmailPlugin` → Correlia mapping, set `class_path: app.plugins.outputs.email.SmtpOutputPlugin`.

### 4. Environment variables

| VDE env | Correlia env | Notes |
|---------|--------------|-------|
| `DATABASE_URL` | `DATABASE_URL` | Required by both. Correlia Settings also reads it via `validation_alias`. |
| `API_TOKEN` | `CORRELIA_API_TOKEN` | To be added to Correlia Settings for static Bearer auth. |
| `DEV_MODE` | `CORRELIA_DEV_MODE` | To be added. Default false; when false, `API_TOKEN` required. |
| `EMAIL_DRY_RUN` | `CORRELIA_EMAIL_DRY_RUN` | Not in current Correlia; add if parity needed. |
| `OPENAI_API_KEY` | `OPENAI_API_KEY` | Only relevant if LLM adapters are added later. |
| (SMTP credentials) | `CORRELIA_SMTP_USERNAME`, `CORRELIA_SMTP_PASSWORD` | Recommended naming. Plugin options can read these as fallback. |

---

## Fail-Fast Rules

The migration command must reject the following rather than silently drop or approximate:

1. `rules[].window.min_hosts` set to any value.
2. `rules[].is_dc_level: true`.
3. `rules[].actions: []` (empty list).
4. `rules[].match.severity` missing.
5. `rules[].match.tags` values containing wildcard characters (`*`, `?`, `[`, `]`).
6. `rules[].match.tags` keys that are not bare topology tags and cannot be prefixed with `topology.`.
7. `rules[].output_summary` placeholders that cannot be rewritten to a known normalized field or valid `topology.*` tag key.
8. Any plugin section other than `outputs` (`task_runner`, `inputs`, `llm`, `enrichers`, `processor`).
9. Any output plugin with `plugin_type` other than `email`.
10. Any output plugin `class_path` not under `app.plugins.outputs.`.
11. Plaintext `smtp_username` or `smtp_password` in output plugin config.
12. Topology hostname patterns with capture groups unless the Correlia enricher has been extended to substitute them.
13. Duplicate rule names or priorities (caught by Correlia loaders, but migration should surface clearly).
14. Overlapping subnet rules that assign different tags (caught by `load_topology_config`).

---

## Credential Handling

- **No plaintext in generated YAML.** This is a hard requirement from `VIGILO_COMPATIBILITY.md`.
- When VDE `plugins.yaml` contains `smtp_username` / `smtp_password`, the migration command must:
  - Refuse to copy them into `config/plugins.yaml`.
  - Optionally accept `--smtp-username-env` / `--smtp-password-env` CLI flags and emit an env-var reference, or omit the options and instruct the operator to set `CORRELIA_SMTP_USERNAME` / `CORRELIA_SMTP_PASSWORD`.
- Generated artifacts should include an `.env.example` with placeholders for `CORRELIA_API_TOKEN`, `CORRELIA_SMTP_USERNAME`, and `CORRELIA_SMTP_PASSWORD`.
- A future code change should make `SmtpOutputPlugin` read `CORRELIA_SMTP_USERNAME` / `CORRELIA_SMTP_PASSWORD` when the corresponding option is absent, so the generated YAML can safely omit credentials.

---

## Generated Config Files

A successful migration run with `--out-dir <dir>` should produce:

- `<dir>/rules.yaml`
- `<dir>/topology.yaml`
- `<dir>/plugins.yaml`
- `<dir>/.env.example` (commented placeholders only, no secrets)

The operator then copies `.env.example` to `.env`, fills in secrets, and points Correlia at the generated files:

```bash
export DATABASE_URL=postgresql+asyncpg://...
export CORRELIA_RULES_PATH=config/rules.yaml
export CORRELIA_TOPOLOGY_PATH=config/topology.yaml
export CORRELIA_PLUGINS_PATH=config/plugins.yaml
export CORRELIA_API_TOKEN=<32-char-token>
# export CORRELIA_SMTP_USERNAME=...
# export CORRELIA_SMTP_PASSWORD=...
```

---

## Validation Path

The migration command should validate its own output by reusing Correlia's existing loaders:

1. Parse VDE YAML as plain `dict` so every field can be inspected before transformation.
2. Transform and write the three Correlia YAML files.
3. Call `load_plugin_registry_config(out_dir / "plugins.yaml")`.
4. Call `load_rules_config(out_dir / "rules.yaml", known_plugins=frozenset(registry.names))`.
5. Call `load_topology_config(out_dir / "topology.yaml")`.
6. If any loader raises, print the original error and exit non-zero.

This guarantees that the generated files pass the same strict validation that Correlia runs at startup.

---

## Sample Migration Verification Approach

```python
import subprocess
from pathlib import Path

from app.config.plugins import load_plugin_registry_config
from app.config.rules import load_rules_config
from app.config.topology import load_topology_config


def test_migrate_vigilo_sample(tmp_path: Path) -> None:
    out = tmp_path / "out"
    out.mkdir()

    result = subprocess.run(
        [
            "python", "scripts/migrate_vigilo_config.py",
            "--rules", "../vde-event-aggregation/config/rules.yaml",
            "--topology", "../vde-event-aggregation/config/topology.yaml",
            "--plugins", "../vde-event-aggregation/config/plugins.yaml",
            "--out-dir", str(out),
        ],
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    registry = load_plugin_registry_config(out / "plugins.yaml")
    rules = load_rules_config(
        out / "rules.yaml",
        known_plugins=frozenset(registry.names),
    )
    topology = load_topology_config(out / "topology.yaml")

    assert len(rules.rules) > 0
    assert len(topology.hostname_rules) > 0 or len(topology.subnet_rules) > 0
    assert len(registry.outputs) > 0

    generated = (out / "plugins.yaml").read_text()
    assert "smtp_username" not in generated
    assert "smtp_password" not in generated
```

Negative tests should pass unsupported VDE fixtures (e.g. `min_hosts`, `is_dc_level`, `actions: []`, `llm` block) and assert the migration exits non-zero with a clear message.

---

## Requirements Implications

- A `scripts/migrate_vigilo_config.py` command must be added, matching the inputs/outputs described in `VIGILO_COMPATIBILITY.md`.
- `StaticTopologyEnricher` must either support regex backreference substitution in tag values or the migration must fail on all dynamic hostname patterns. Because every VDE hostname pattern in the sample config uses a capture group, backreference support is the only path to automated migration.
- Correlia Settings must grow `api_token` and `dev_mode` (and possibly `email_dry_run`) for deployment parity.
- The `known_actions` set used by `load_rules_config` must include `"create_incident"` (current default) or be expanded to include `"notify"` if the migration chooses a different semantic name.
- Input plugin, enricher, processor, and task-runner adapter slots are explicitly out of scope for v1.1 config compatibility and must fail fast.

---

## Roadmap Implications

- **Immediate:** implement migration CLI and the rule/topology/plugin transformation logic; add backreference support to topology enrichment.
- **Next:** add Bearer auth and required env settings (`CORRELIA_API_TOKEN`, `CORRELIA_DEV_MODE`).
- **Later:** expand the plugin registry to input, enrichment, decision, and task-runner adapters so that the VDE `inputs`, `enrichers`, `processor`, and `task_runner` sections can be migrated instead of rejected.
- **Last:** config hot-reload and a dry-run/simulation endpoint are useful but should wait until the static migration path is proven.

---

## Risks

| Risk | Impact | Mitigation |
|------|--------|------------|
| **Semantic mismatch in host/service matching** | VDE uses `fnmatch` full-string; Correlia uses `re.match` prefix. Translated wildcards mostly overlap, but edge cases differ. | Translate simple wildcards only; fail on complex fnmatch patterns; document the regex semantics. |
| **Tag matching is exact in Correlia, wildcard in VDE** | A migrated rule with `tags.datacenter: "*"` would never match. | Fail fast on non-literal tag values. |
| **Topology capture groups** | VDE derives tag values from regex groups; Correlia does not. | Add backreference substitution to `StaticTopologyEnricher`, or require manual per-value rules. |
| **Empty action lists** | VDE service-tracker rules use `actions: []`; Correlia rejects them. | Introduce a no-op output plugin or explicitly fail and require operator decision. |
| **Credential leakage** | Migration could copy `smtp_password` into generated YAML. | Hard-code a check that fails if plaintext credentials are present; emit `.env.example` placeholders instead. |
| **Action name mismatch** | Correlia validates `action.name` against `known_actions` but dispatches by `plugin`. Using `"create_incident"` works today but may confuse future readers. | Document that `name` is a compatibility shim and consider expanding `known_actions` to `"notify"`. |
| **Silent dropping of unsupported sections** | If the migration tolerates `llm`/`enrichers`/`processor`, behavior changes silently. | Fail fast on every unsupported section and field listed above. |

---

*Research for: Correlia v1.1 Vigilo/VDE config compatibility*
