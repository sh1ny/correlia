# Configuration

Correlia ships executable, credential-free samples under `config/` and a matching `.env.example` for the local Compose stack. Copy `.env.example` to `.env` and replace every `replace-with-*` placeholder before starting the stack.

```bash
CORRELIA_RULES_PATH=config/rules.yaml
CORRELIA_TOPOLOGY_PATH=config/topology.yaml
CORRELIA_PLUGINS_PATH=config/plugins.yaml
```

`DATABASE_URL` is still required by the application settings.
`CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` is also required at startup. It protects the audit trail's ability to authenticate a pre-redaction raw audit payload against a candidate original. Supply it through your deployment's secret-management system; never commit it in configuration files.

## Accepted event tags

`POST /v1/icinga2/events` applies the same fixed contract to source tags and to the effective normalized tags after topology enrichment:

| Bound | Limit |
|---|---|
| Key | ASCII `^[a-z][a-z0-9_.-]*$`, 1–64 UTF-8 bytes |
| Value | 1–256 Unicode characters |
| Entries | 128 |
| Whole tag object | 16,384 compact UTF-8 JSON bytes |

Byte accounting uses sorted keys, `ensure_ascii=False`, and compact separators. It includes braces, quotes, colons, commas, JSON escaping, and multibyte value bytes. The empty map is allowed and costs two bytes. Non-ASCII keys, NUL values, and unpaired surrogates are rejected; keys and values are never normalized, renamed, or clipped.

Hostname topology matches still precede subnet fallback. Literal topology tags override source values; capture tags override literals. Collisions count once, with the winning value's encoded size. Static topology literals and capture destinations are validated when configuration loads. The final merged map is checked before rule evaluation or the incident-plus-audit transaction.

Tag-contract failures return HTTP **422**, including oversized tags on SOFT events. Both source and enrichment failures have this fixed, input-free error shape:

```json
{"detail":[{"loc":["body","tags"],"msg":"invalid event tags","type":"value_error.event_tags"}]}
```

Request-body overflow remains HTTP **413**. Unrelated processing failures retain the generic HTTP 500 response. Before upgrading, check producer tags and topology configuration against these limits: maps accepted by older versions can now be rejected. Accepted final maps reach rules and the stored normalized snapshot unchanged.

## Raw audit retention

New audit rows use redaction version **2**. HMAC-SHA256 still authenticates the canonical, pre-redaction request-model dump—not raw HTTP bytes or the enriched event. Recursive sensitive-fragment redaction and the redacted-path count cover the complete source, including subtrees later omitted.

If the redacted object does not fit, capping removes whole top-level fields in descending encoded-byte contribution order, breaking ties lexically by key. It does not trim individual string leaves or repeatedly rescan the remaining document. The stored result is valid JSON and fits the smaller of the configured cap and the original canonical byte length; redaction expansion can therefore trigger omission even for a small input. When no field fits, the result is `{}`.

The configured default cap is 65,536 bytes; the production minimum is 1,024 bytes. The helper supports caps down to two bytes. Original/stored lengths use compact canonical UTF-8 JSON. `raw_payload_truncated` describes storage-time omission only. Existing version-1 rows, HMACs, lengths, and payloads are not rewritten.

The raw cap does not cap the separate normalized snapshot or audit response page. These have separate tag contracts. Sensitive-fragment matching is not general credential detection; this change does not make normalized snapshots secret-free at rest.

## Audit read projections

The operator-authenticated `GET /v1/incident-events` endpoint returns at most 200 rows. It does not expose raw payloads or the full normalized documents. Each row's tag projection contains at most **32 entries** and **4,096 compact UTF-8 JSON bytes**, using the accepted event key/value constraints above.

The repository checks complete message content for sensitive fragments before applying the 512-character response limit. It omits sensitive tag keys, rejects invalid legacy pairs, and redacts sensitive scalar values. It then retains whole pairs in lexical key order. A pair that would exceed the byte budget is skipped; later smaller pairs can still be retained. Ordinary keys and values are never shortened to fit.

Every row includes independent read-time omission metadata:

```json
{
  "normalized_event_tags": {"region": "west"},
  "normalized_event_tags_omitted": true,
  "normalized_event_tags_omission_reasons": ["size_limit"]
}
```

Reasons form a bounded set:

- `size_limit`: entries were omitted by the count/byte limits, or the whole historical map exceeded the SQL transfer guard.
- `invalid_legacy_shape`: an old map/container, key, or value does not meet the current flat string-map contract.
- `sensitive_key`: a sensitive-fragment key was omitted.

A complete projection has `normalized_event_tags_omitted: false` and an empty reason set. Value-only redaction does **not** mean an entry was omitted: returned values are redacted projections, not an original-value export. No exact omitted count is promised for a whole-map omission. `raw_payload_truncated` continues to describe storage-time capping, not these read-time omissions.

Before asyncpg decodes tags, PostgreSQL guards their shape and textual UTF-8 size. Only objects of at most **32,768 bytes** are inspected; non-string values are removed in SQL while string-valued siblings survive. This also protects reads of numeric legacy entries too large for Python's integer decoder. Other invalid containers and over-limit objects become empty projections with the corresponding reason. PostgreSQL may still detoast and scan a historical value to measure it; the guard bounds transfer, not database work.

Projection never rewrites stored snapshots, HMACs, or raw metadata. Filters use full persisted values. Cursor ordering remains `(accepted_at, id)` descending; totals, diagnostic offsets, and row counts are unchanged, including rows with omitted tags.

The complete uncompressed 200-row HTTP response is bounded to **20 MiB (20,971,520 bytes)** for application-produced non-tag fields, including historical rows with invalid or oversized tags. Qualification preserves Python's default **4,300-digit** integer conversion limit and the producer's 64-character SHA-256 hex HMAC. Increasing/disabling that runtime limit or corrupting unrelated historical columns is outside this qualified profile. The conservative allowance is 96 KiB per row plus 4 KiB for the envelope: 19,664,896 bytes. Actual serialized HTTP bodies—not Python object size, JSONB storage size, or compression—are checked by the PostgreSQL-backed maximum-page scenario.

No migration or historical backfill is needed. Rolling back application code restores the old unbounded projection and capping behavior; it is not a neutral mitigation.

## Qualifying audit bounds

Run function qualification on the pinned runtime:

```sh
mise exec -- uv run --locked --no-sync python scripts/qualify_audit_bounds.py
```

The JSON report records CPU, OS, Python version, Git revision and dirty-state flag, caps, fixture parameters/digests, output metadata, and median/p95/maximum timings. Each family has three warm-up calls followed by 30 timed `redact_payload` calls; fixture construction and validation are outside the timed interval. Both the default 65,536-byte cap and the production minimum of 1,024 bytes are qualified.

The corpus includes reconstructed 1,000/5,000/10,000-tag shapes of exactly 15,181/75,181/150,181 canonical bytes. Their original generator, contents, machine, and repetition counts are unavailable. The historical 0.0108/3.5014/46.4278-second observations are retained as reported evidence, not rerun or used for precise speedup claims. Those tag counts now fail ingress but remain direct redactor cases.

Separate permitted families cover 128 entries, 64-byte keys, exactly 16,384 tag bytes, four-byte Unicode values, escape-heavy values, redaction expansion, a 4,096-character message, and a request approaching 1 MiB through the currently permitted `ip_address` field. These are separate maxima, not an impossible combined event. Qualification fails if any family's p95 exceeds **250 ms**, or the 5,000-to-10,000 median ratio exceeds **3×** using a **20 ms denominator floor**. Raising the ingress-body ceiling requires requalification at the new permitted maximum.

`mise run ci` runs the function qualifier and the concurrent HTTP scenario within the existing Compose smoke, without starting a second deployment. The HTTP client runs separately from the single Uvicorn worker. It offers at most 10 ingress requests/second for 11 seconds, with at most two in flight, while an independent thread schedules health probes every 50 ms without awaiting earlier responses. Health latency includes delay from the scheduled deadline, so late dispatch cannot hide server stalls. A two-second idle baseline is recorded separately. At least 100 successful health probes must overlap the workload; loaded health p95 must be at most **250 ms**, and its maximum at most **1 second**. A 429 or any other unsuccessful probe fails qualification.

The smoke keeps rate limiting enabled, overriding only its generated test configuration: health allows 1,000 requests/60 seconds and ingress 500 requests/60 seconds, above the finite workload plus baseline and existing smoke traffic. Production quotas are unchanged. The report includes effective quotas, offered rate, observed duration, successful ingress responses, persisted audit outcomes, and topology-boundary equality. Function timings, real HTTP responsiveness, and PostgreSQL-backed maximum-page bytes appear as separate sections in the hosted run summary. The HTTP budget is a smoke criterion, not a general capacity SLO.

Native Windows `check:portable` and direct function timings are not PostgreSQL or deployment proof. Use the current revision's hosted **Linux verification** result for legacy JSONB guards, full-page HTTP bytes, committed ingress, concurrent health, SMTP, and lifecycle cleanup. Do not run `test:deployment` again after `ci`.

## Keeping credentials out of Git

Git ignores `.env` and `.env.*` at the repository root and in nested directories, except `.env.example`. Keep samples credential-free and supply deployment values through local configuration or your secret-management system.

Ignore rules prevent ordinary staging of untracked files; they do not remove already-tracked files or historical content, and `git add --force` can bypass them. Review staged changes before committing. Do not force-add local environment files or put secrets in tracked YAML, source, commit messages, PRs, issues, or verification logs.

If a credential reaches GitHub, treat it as exposed: contact its owner privately and revoke or rotate it before considering history cleanup. Do not paste the value into a public report or assume deleting the file removes other copies.

### Native secret scanning and push protection

Repository-level GitHub secret scanning and push protection are enabled for `sh1ny/correlia`. The web-commit path was verified with GitHub's documented non-secret dummy token; the blocked attempt was cancelled without bypass or a new commit. The dated [secret-exposure audit](docs/security/secret-exposure-audit.md) records the historical scan scope and hosted proof separately.

When GitHub blocks a commit, cancel it and remove the credential rather than choosing a bypass to get the change through. Repository administrators own reviewing secret-scanning alerts and bypass activity; credential owners handle private revocation or rotation. The qualification did not change bypass permissions.

These controls detect supported patterns, not every credential. Unsupported formats, size and processing limits, and permitted bypasses remain risks; the browser proof does not establish every Git/API push path. See GitHub's [secret-scanning scope](https://docs.github.com/en/code-security/reference/secret-security/secret-scanning-scope) and [supported patterns](https://docs.github.com/en/code-security/reference/secret-security/supported-secret-scanning-patterns). Account-level push protection is not a substitute for repository settings. Docker exclusions affect the build context only, and `mise run audit` checks Python dependency advisories, not secrets.

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

Async tests and fixtures run under pytest-asyncio's configured `auto` mode. Do not add `pytest.mark.anyio` or AnyIO backend fixtures: allowing both plugins to own a test can put its database fixture and test on different event loops, making results depend on plugin discovery order. AnyIO remains an application dependency; it does not own this suite's test execution.

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

### Rule windows and threshold capacity

`window.trigger_threshold` must be an integer from **1 through 100**, inclusive. Invalid, non-integer, or larger values are rejected when rules load, not clamped. The sample `config/rules.yaml` deliberately uses threshold **1**; 100 is the supported maximum for the retained-fingerprint representation, **not** a PostgreSQL limit or a default threshold for every rule.

A rule groups matching PROBLEM events by its `window.group_by` values and counts distinct retained fingerprints within `window.duration_seconds` of the latest persisted event-time window end (inclusive of both bounds). Retained replays do not increase the count; a late distinct event inside the window can count, but one outside it cannot. The incident stores at most 100 fingerprints for this window, so configure a threshold no greater than 100 and send that many distinct eligible events in the **same group and event-time window** to reach it. Deduplication is bounded by retained history: a fingerprint pruned or evicted from the map has no unlimited replay protection.

For each accepted PROBLEM event, PostgreSQL aggregation supplies the request's count, bounds, and current `crossed` result in both API `threshold_decision` copies. The audit summary records that request's count, applied threshold, monotone crossing marker, and first-transition intent; it does not expose window bounds. Current-window `threshold_decision.crossed` can become false when older events age out. The incident and API `threshold_crossed` marker remains true after its **first** crossing; a first persisted transition is required for notification submission, but does not guarantee it. An accepted submission (`notification_count`) is not delivery confirmation. `AsyncIOTaskRunner` holds pending work in memory, so a restart may lose it; this is not a durable queue or exactly-once delivery.

Lowering a rule's threshold on an existing OPEN incident applies the new window parameters through the normal merge without resetting its crossing marker. A replay still retained in the window can meet the lower threshold and mark the incident crossed for the first time, yet replay suppression prevents notification submission; later distinct events cannot produce another first transition. A crossed marker does not mean an alert was sent.

Preflight candidate rules with the same loader used at startup, then deploy a consistent application/configuration version and restart the application. Rules do not hot-reload; a rejected threshold prevents startup rather than letting a service run with an unreachable value. Existing incident history is not backfilled or retroactively counted when rules change.

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
- The converter rejects an unsupported converted `window.trigger_threshold` without promoting files. If staged validation reaches the shared rule loader, recognized threshold errors appear in the report at `rules[index].window.trigger_threshold` with the supported 1–100 bound, without echoing raw values or configuration content. Other errors within that rule validation retain generic sanitized entries; plugin construction and other loader failures remain generic and fail fast rather than aggregating errors across stages.

## Current gaps before exact VDE parity

- No direct config support for VDE `min_hosts` thresholds.
- No direct config support for VDE `is_dc_level` notification suppression semantics.
- No actionless tracking rule support because Correlia rejects empty action lists.
- No config surface yet for input plugins, enrichment plugins, decision/processor plugins, or task-runner adapters.
- No first-class secret references in `plugins.yaml`; operators must supply credentials outside the migration artifact.
