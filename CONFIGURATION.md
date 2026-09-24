# Configuration

Correlia ships executable, credential-free samples under `config/` and a matching `.env.example` for the local Compose stack. Copy `.env.example` to `.env` and replace every `replace-with-*` placeholder before starting the stack.

```bash
CORRELIA_RULES_PATH=config/rules.yaml
CORRELIA_TOPOLOGY_PATH=config/topology.yaml
CORRELIA_PLUGINS_PATH=config/plugins.yaml
```

`DATABASE_URL` is still required by the application settings.
`CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` is also required at startup. It protects the audit trail's ability to authenticate a pre-redaction raw audit payload against a candidate original. Supply it through your deployment's secret-management system; never commit it in configuration files.

## Contributor verification

Install [mise](https://mise.jdx.dev/getting-started.html) externally, review the checkout, then run from the repository root:

```sh
mise trust
mise install
mise run setup
```

The task interface is `mise.toml`, not Make. Python **3.14.7** and uv **0.11.7** are pinned; GitHub Actions also pins mise **2026.9.12** and action commit revisions. uv uses the selected Python executable, replaces incompatible virtual environments during setup, and installs the committed development resolution. Ruff, mypy and pytest come from `uv.lock`, never independent tool installations. Setup rejects a missing or stale lock. Verification does not regenerate it.

### Linux gate and Windows subset

Full verification requires Linux, a working Docker engine, the Compose v2 plugin (including `!reset` support), permission to use Docker, image pulls, and network access to the package and advisory services. Install Docker/Compose separately; tasks do not install or start the daemon. PostgreSQL **16** is the supported verification major. `compose.yaml` owns its image reference, which all PostgreSQL correctness fixtures also use.

```sh
mise run ci
```

`ci` runs setup once, format checking, lint, strict application typing, dependency audit, and the complete pytest suite. The suite includes real PostgreSQL, POSIX and the existing Compose/Mailpit smoke **once**. Required modes fail on missing Docker/Compose, narrowed selection, missing scenarios, collection/setup/call/teardown skips, xfails, errors or incomplete execution. No test-count threshold substitutes for completed scenarios.

Native Windows contributors can run:

```powershell
mise run check:portable
```

This runs the same quality/audit checks and a portable pytest subset. It requires neither Make, Bash, Docker nor symlink privilege. Resource-dependent tests are excluded before fixture setup; database-free tests in mixed modules remain included. A passing portable result is **not** PostgreSQL, Linux, deployment or release proof.

| Task | Purpose |
|---|---|
| `setup` | Exact locked development synchronization |
| `format:check` | Ruff formatting check, without rewriting |
| `lint` | Ruff lint checks |
| `typecheck` | Strict mypy for `app` |
| `audit` | Locked dependency advisory scan |
| `test` | Full required Linux pytest suite, including deployment |
| `test:deployment` | Only the existing required Compose/Mailpit smoke |
| `test:portable` | Portable pytest subset |
| `ci` | Complete Linux verification |
| `check:portable` | Portable development checks |
| `run` | Local reload-enabled FastAPI factory startup |
| `clean:verification` | Remove only the identified verification project's resources |

Use `mise run test:deployment` for focused deployment work, not as another step after `ci`. Focused debugging may use `mise exec -- uv run --locked --no-sync pytest <test-path>` after setup; that invocation is not the required gate.

### Dependency advisory policy

`audit` uses uv 0.11.7's `uv --preview-features audit audit --locked`, with its universal dependency scope, including runtime and development packages. User-level uv configuration and inherited exclusion controls do not narrow the shared scan. Findings and scanner/service errors fail verification. There are no initial exceptions, global ignores or “ignore until fixed” allowances.

Resolve findings through a reviewed dependency update or removal and an intentional `uv lock` update, then rerun verification. Tasks never repair dependencies automatically. This scan covers known Python-package advisories, not container OS vulnerabilities or general malware assurance.

### Interrupted-run cleanup

The smoke prints its run-specific `correlia-verify-...` project identifier before startup. Its finalizer and the task wrapper attempt cleanup on failure and interruption; the workflow invokes the same scoped cleanup task in finalization. To recover an interrupted local run, pass the printed identifier:

```sh
mise run clean:verification correlia-verify-<printed-suffix>
```

Cleanup removes only containers, volumes and networks labeled for that verification project, including auxiliary failure-test containers. Missing/invalid identifiers and failed cleanup return non-zero. Do not pass another run's identifier. Repeating cleanup is safe after the owned resources are gone. Hard termination or host loss may prevent finalizers from running; ephemeral hosted runners bound that risk, not a guarantee of crash-atomic teardown.

### Local factory startup

`mise run run` starts `app.main:create_app --factory --reload`. Export `DATABASE_URL`, `CORRELIA_RULES_PATH`, `CORRELIA_TOPOLOGY_PATH`, `CORRELIA_PLUGINS_PATH`, the distinct operator/ingress tokens and the separate audit HMAC key first. Use the checked-in `config/*.yaml` paths where appropriate. Host startup does not load `.env`, run migrations or create secrets. Apply migrations deliberately with `mise exec -- uv run --locked --no-sync alembic upgrade head`.

A host process needs a reachable PostgreSQL database. The sample `postgres` hostname is Compose-internal and Compose does not publish a PostgreSQL host port. Missing required settings remain startup errors.

### Required hosted check and administrator handoff

The PR workflow runs one check named **Linux verification** on `ubuntu-24.04`. It tests the proposed merge revision, records that SHA and the PR head, and cancels superseded runs. Only completed task outcomes count; an absent outcome is not a pass. Logs and the run summary provide evidence without uploading local `.env` files or raw Docker inspection.

A repository administrator must require **Linux verification** from GitHub Actions on `main`, with up-to-date base verification, while preserving existing review and merge protections. The workflow alone does not enforce merging. Read back the rule and link a successful run for the identified current revision before declaring issue #46 complete; the bot's push permission does not authorize protection changes.

Issue #49 should link this section as the onboarding boundary. Future #55 work may consume the shared tasks, but they do not publish candidates, tags, releases or production deployments and do not establish exact released-image identity.

## Local Compose stack

`compose.yaml` starts PostgreSQL, one Correlia application container, and [Mailpit](https://github.com/axllent/mailpit) for local SMTP capture:

```bash
cp .env.example .env
# Replace every replace-with-* value in .env.
docker compose up --build
```

`DATABASE_URL` is the database alias consumed by `Settings`; keep its PostgreSQL username, password, database, and hostname consistent with `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB`. The required `CORRELIA_OPERATOR_API_TOKEN`, `CORRELIA_INGRESS_API_TOKEN`, and `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` must be distinct non-empty deployment secrets.

The operator configuration is mounted read-only at `/app/config`. PostgreSQL and SMTP are isolated on private Compose networks; only the Correlia API (`127.0.0.1:8000`) and Mailpit UI (`127.0.0.1:8025`) are published to the host. Mailpit's SMTP listener remains private at `mailpit:1025`.

The sample keeps API authentication enabled, protects `/v1/readyz` with the operator token, leaves `/v1/health` public for the token-free container healthcheck, and preserves metrics exposure through `CORRELIA_EXPOSE_METRICS`.

## Rate limiting

Rate-limit counters for in-process request buckets are expired by a background sweep worker. Configure how often it runs with:

```bash
CORRELIA_RATE_LIMIT_SWEEP_INTERVAL_SECONDS=60
```

Default is `60` seconds. Minimum `1`, maximum `3600`. Shorter intervals reduce memory growth from stale buckets but increase CPU use.

## Files

The checked-in samples are:

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
mise exec -- uv run --locked --no-sync python scripts/migrate_vigilo_config.py \
  --rules vigilo/rules.yaml \
  --topology vigilo/topology.yaml \
  --plugins vigilo/plugins.yaml \
  --out-dir config/ \
  --report-path migration-report.json
```
To project the bounded migration-report gauges on `/v1/metrics`, set `CORRELIA_MIGRATION_REPORT_PATH` to the JSON emitted by `scripts/migrate_vigilo_config.py --report-path`. Leave it unset (the default) to disable projection.


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
