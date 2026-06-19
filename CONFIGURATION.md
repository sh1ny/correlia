# Configuration

Correlia currently has configuration loaders but no checked-in root configuration files. A Vigilo/VDE port should add these files under `config/` and point Correlia at them with environment variables.

```bash
CORRELIA_RULES_PATH=config/rules.yaml
CORRELIA_TOPOLOGY_PATH=config/topology.yaml
CORRELIA_PLUGINS_PATH=config/plugins.yaml
```

`DATABASE_URL` is still required by the application settings.

## Rate limiting

Rate-limit counters for in-process request buckets are expired by a background sweep worker. Configure how often it runs with:

```bash
CORRELIA_RATE_LIMIT_SWEEP_INTERVAL_SECONDS=60
```

Default is `60` seconds. Minimum `1`, maximum `3600`. Shorter intervals reduce memory growth from stale buckets but increase CPU use.

## Files

Create:

- `config/rules.yaml`
- `config/topology.yaml`
- `config/plugins.yaml`

## Rules configuration

Example `config/rules.yaml`:

```yaml
rules:
  - name: "DC-Level Outage Aggregator"
    priority: 1
    match:
      severities: ["CRITICAL", "WARNING"]
      host_pattern: ".*"
      tags:
        topology.datacenter: ".+"
    window:
      duration_seconds: 1800
      group_by: ["topology.datacenter"]
      trigger_threshold: 10
    output_summary: "Major outage detected in Datacenter {topology.datacenter}"
    actions:
      - name: "create_incident"
        plugin: "email-ops"

  - name: "Host Alert Aggregator"
    priority: 2
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

Porting notes:

- VDE `match.severity` becomes Correlia `match.severities`.
- VDE wildcard `host`/`service` values are translated with `fnmatch.translate()` into anchored regex `host_pattern`/`service_pattern` values.
- VDE `actions: ["email-ops"]` becomes action objects with `name: create_incident` and `plugin: <action-name>`.
- Correlia requires every rule to have at least one action today. VDE's service-tracker rule with `actions: []` will not load without a no-op output plugin or a schema change.
- Correlia does not currently support VDE's `min_hosts` or `is_dc_level` rule fields directly.

## Topology configuration

Example `config/topology.yaml`:

```yaml
hostname_rules:
  - id: "standard-naming-convention"
    name: "Standard Naming Convention"
    hostname_pattern: "^([a-z0-9]+)-prd-.*"
    tags: {}
    tag_capture_groups:
      topology.datacenter: 1

  - id: "development-environment"
    name: "Development Environment"
    hostname_pattern: "^([a-z0-9]+)-dev-.*"
    tags: {}
    tag_capture_groups:
      topology.datacenter: 1

subnet_rules:
  - id: "prm1-subnet"
    name: "PRM1 subnet"
    subnet: "10.10.0.0/16"
    tags:
      topology.datacenter: "prm1"

  - id: "prm2-subnet"
    name: "PRM2 subnet"
    subnet: "10.20.0.0/16"
    tags:
      topology.datacenter: "prm2"

  - id: "dev-subnet"
    name: "Development subnet"
    subnet: "192.168.0.0/16"
    tags:
      topology.datacenter: "dev"
```

Porting notes:

- VDE `topology_rules.hostname_patterns[].regex` becomes Correlia `hostname_rules[].hostname_pattern`.
- VDE hostname patterns with a parenthesized capture group and a `target_tag` become `tag_capture_groups: {topology.<target_tag>: 1}` instead of literal backreference strings.
- VDE subnet `cidr` becomes Correlia `subnet`.
- VDE subnet `value` becomes the value under the selected topology tag.

## Plugin configuration

Example `config/plugins.yaml`:

```yaml
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
      subject_prefix: "[Correlia]"
      start_tls: true
```

Porting notes:

- Correlia currently supports output plugin registry entries under `outputs`.
- `plugin_type` must be `email` today.
- `class_path` must live under `app.plugins.outputs.`.
- VDE `smtp_host` maps to Correlia `host`.
- VDE `smtp_port` maps to Correlia `port`.
- VDE `from_address`, `to_addresses`, and `subject_prefix` map directly.
- VDE `use_tls: true` or omitted `use_tls` maps to Correlia `start_tls: true`; explicit `use_tls: false` maps to `start_tls: false`.
- SMTP credentials should be supplied through environment-specific secret handling, not copied as plaintext from VDE config.
- VDE task-runner, input plugin, LLM enricher, and LLM processor sections have no direct Correlia config target yet.

## Vigilo/VDE config migration

Use the standalone migration CLI to translate supported Vigilo/VDE YAML into Correlia config:

```bash
uv run python scripts/migrate_vigilo_config.py \
  --rules vigilo/rules.yaml \
  --topology vigilo/topology.yaml \
  --plugins vigilo/plugins.yaml \
  --out-dir config/ \
  --report-path migration-report.json
```

Behavior:

- The CLI accepts exactly one YAML file per `--rules`, `--topology`, and `--plugins` flag. Directories, globs, missing files, and non-YAML files are rejected.
- Each of `--rules`, `--topology`, `--plugins`, and `--out-dir` may only be specified once.
- Vigilo priorities are sorted by descending numeric value and rewritten as Correlia ascending ranks (`1`, `2`, `3`, ...), so Correlia's lower-first rule engine preserves Vigilo's higher-first evaluation order.
- Supported topology capture-group patterns emit `tag_capture_groups` instead of literal backreference strings.
- Plaintext SMTP credential keys (`smtp_username`, `smtp_password`, `username`, `password`) cause the migration to fail closed with no output files written.
- Unknown Vigilo email plugin option keys (e.g. `smtp_timeout`, `connection_pool_size`) are rejected so unmapped semantics are not silently copied or dropped.
- Any top-level plugin section other than `outputs` is rejected, including generic unknown section names.
- Unsupported fields across all three input files are aggregated into one structured report (`ok: false`, `errors: [...]`, `generated: null`) before the CLI exits non-zero.
- Generated files are staged in a temporary directory, validated through Correlia's loaders plus generated email plugin instantiation, and only then atomically promoted to `--out-dir`. A failed migration leaves `--out-dir` untouched.

## Current gaps before exact VDE parity

- No direct config support for VDE `min_hosts` thresholds.
- No direct config support for VDE `is_dc_level` notification suppression semantics.
- No actionless tracking rule support because Correlia rejects empty action lists.
- No config surface yet for input plugins, enrichment plugins, decision/processor plugins, or task-runner adapters.
- No first-class secret references in `plugins.yaml`; operators must supply credentials outside the migration artifact.
