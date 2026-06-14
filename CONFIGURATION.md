# Configuration

Correlia currently has configuration loaders but no checked-in root configuration files. A Vigilo/VDE port should add these files under `config/` and point Correlia at them with environment variables.

```bash
CORRELIA_RULES_PATH=config/rules.yaml
CORRELIA_TOPOLOGY_PATH=config/topology.yaml
CORRELIA_PLUGINS_PATH=config/plugins.yaml
```

`DATABASE_URL` is still required by the application settings.

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
    priority: 100
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
      - name: "email-ops"
        plugin: "email-ops"

  - name: "Host Alert Aggregator"
    priority: 50
    match:
      severities: ["CRITICAL", "WARNING"]
      host_pattern: ".*"
    window:
      duration_seconds: 1800
      group_by: ["host"]
      trigger_threshold: 5
    output_summary: "Multiple alerts on {host}"
    actions:
      - name: "email-ops"
        plugin: "email-ops"
```

Porting notes:

- VDE `match.severity` becomes Correlia `match.severities`.
- VDE wildcard `host: "*"` becomes regex `host_pattern: ".*"`.
- VDE `actions: ["email-ops"]` becomes action objects with `name` and `plugin`.
- Correlia requires every rule to have at least one action today. VDE's service-tracker rule with `actions: []` will not load without a no-op output plugin or a schema change.
- Correlia does not currently support VDE's `min_hosts` or `is_dc_level` rule fields directly.

## Topology configuration

Example `config/topology.yaml`:

```yaml
hostname_rules:
  - id: "standard-naming-convention"
    name: "Standard Naming Convention"
    hostname_pattern: "^([a-z0-9]+)-prd-.*"
    tags:
      topology.datacenter: "\\1"

  - id: "development-environment"
    name: "Development Environment"
    hostname_pattern: "^([a-z0-9]+)-dev-.*"
    tags:
      topology.datacenter: "\\1"

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
- VDE `target_tag: "datacenter"` should become `topology.datacenter`; Correlia requires topology tag keys to start with `topology.`.
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
- SMTP credentials should be supplied through environment-specific secret handling, not copied as plaintext from VDE config.
- VDE task-runner, input plugin, LLM enricher, and LLM processor sections have no direct Correlia config target yet.

## Current gaps before exact VDE parity

- No direct config support for VDE `min_hosts` thresholds.
- No direct config support for VDE `is_dc_level` notification suppression semantics.
- No actionless tracking rule support because Correlia rejects empty action lists.
- No config surface yet for input plugins, enrichment plugins, decision/processor plugins, or task-runner adapters.
- No config migration command exists yet; a future `scripts/migrate_vigilo_config.py` should fail on unsupported VDE fields rather than silently dropping them.
