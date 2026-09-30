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
| `clean:verification` | Deliberately delete the explicitly identified verification project's resources |
| `clean:verification:owned` | Automatic cleanup authorized by the current invocation's ownership receipt |

Use `mise run test:deployment` for focused deployment work, not as another step after `ci`. Focused debugging may use `mise exec -- uv run --locked --no-sync pytest <test-path>` after setup; that invocation is not the required gate.

Async tests and fixtures run under pytest-asyncio's configured `auto` mode. Do not add `pytest.mark.anyio` or AnyIO backend fixtures: allowing both plugins to own a test can put its database fixture and test on different event loops, making results depend on plugin discovery order. AnyIO remains an application dependency; it does not own this suite's test execution.

### Dependency advisory policy

`audit` uses uv 0.11.7's `uv --preview-features audit audit --locked`, with its universal dependency scope, including runtime and development packages. User-level uv configuration and inherited exclusion controls do not narrow the shared scan. Findings and scanner/service errors fail verification. There are no initial exceptions, global ignores or “ignore until fixed” allowances.

Resolve findings through a reviewed dependency update or removal and an intentional `uv lock` update, then rerun verification. Tasks never repair dependencies automatically. This scan covers known Python-package advisories, not container OS vulnerabilities or general malware assurance.

### Interrupted-run cleanup

Before creating resources, verification acquires a fresh `correlia-verify-...` namespace and a run-local receipt bound to both its project and invocation. An existing project resource or an existing physical PostgreSQL volume name, even without matching labels, rejects acquisition. A rejected run has no cleanup authority. The fixture, task wrapper and workflow's `clean:verification:owned` finalizer require that matching receipt before automatic deletion; a plausible project name alone is not ownership.

The smoke prints its project identifier before startup. If automatic cleanup was interrupted, an operator can deliberately delete an identified **disposable verification project** by passing its printed identifier:

```sh
mise run clean:verification correlia-verify-<printed-suffix>
```

This manual command is an explicit deletion authorization, not receipt-gated automatic recovery: it removes containers, volumes and networks labeled for that verification project, including its auxiliary containers. Missing/invalid identifiers and failed cleanup return non-zero. Confirm the printed identifier belongs to the intended disposable run; never substitute a local operator stack or another run's project. Repeating it is safe after those resources are gone. Anonymous volumes without project labels are not discovered or deleted by this command; a rehearsal removes only its own separately recorded anonymous volume. Hard termination or host loss may prevent finalizers from running; ephemeral hosted runners bound that risk, not a guarantee of crash-atomic teardown.

### Local factory startup

`mise run run` starts `app.main:create_app --factory --reload`. Export `DATABASE_URL`, `CORRELIA_RULES_PATH`, `CORRELIA_TOPOLOGY_PATH`, `CORRELIA_PLUGINS_PATH`, the distinct operator/ingress tokens and the separate audit HMAC key first. Use the checked-in `config/*.yaml` paths where appropriate. Host startup does not load `.env`, run migrations or create secrets. Apply migrations deliberately with `mise exec -- uv run --locked --no-sync alembic upgrade head`.

A host process needs a reachable PostgreSQL database. The sample `postgres` hostname is Compose-internal and Compose does not publish a PostgreSQL host port. Missing required settings remain startup errors.

### Required hosted check and administrator handoff

The PR workflow runs one check named **Linux verification** on `ubuntu-24.04`. It tests the proposed merge revision, records that SHA and the PR head, and cancels superseded runs. Only completed task outcomes count; an absent outcome is not a pass. Logs and the run summary provide evidence without uploading local `.env` files or raw Docker inspection.

A repository administrator must require **Linux verification** from GitHub Actions on `main`, with up-to-date base verification, while preserving existing review and merge protections. The workflow alone does not enforce merging. Read back the rule and link a successful run for the identified current revision before declaring issue #46 complete; the bot's push permission does not authorize protection changes.

Issue #49 should link this section as the onboarding boundary. Future #55 work may consume the shared tasks, but they do not publish candidates, tags, releases or production deployments and do not establish exact released-image identity.

## Local Compose stack

`compose.yaml` starts PostgreSQL, one Correlia application container, and [Mailpit](https://github.com/axllent/mailpit) for local SMTP capture:

```sh
umask 077
cp .env.example .env
chmod 600 .env
# Replace every replace-with-* value in .env; do not commit it.
PROJECT=correlia-local
dc() {
    docker compose --project-name "$PROJECT" --env-file .env --file compose.yaml "$@"
}
dc up --build --detach --wait
```

`DATABASE_URL` is the database alias consumed by `Settings`; keep its PostgreSQL username, password, database, and hostname consistent with `POSTGRES_USER`, `POSTGRES_PASSWORD`, and `POSTGRES_DB`. The required `CORRELIA_OPERATOR_API_TOKEN`, `CORRELIA_INGRESS_API_TOKEN`, and `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` must be distinct non-empty deployment secrets.

The operator configuration is mounted read-only at `/app/config`. PostgreSQL and SMTP are isolated on private Compose networks; only the Correlia API (`127.0.0.1:8000`) and Mailpit UI (`127.0.0.1:8025`) are published to the host. Mailpit's SMTP listener remains private at `mailpit:1025`.

The sample intentionally selects `local`, enables API authentication, protects `/v1/readyz` with the operator token, and exposes `/v1/metrics` publicly. Compose's container healthcheck calls `/v1/readyz` with the operator bearer token; it is not token-free. `/v1/health` remains public minimal liveness and is independent of readiness.

### Persistent local lifecycle

The PG16 service mounts the project-scoped `postgres-data` volume at `/var/lib/postgresql/data`; with the explicit project above its physical name is `correlia-local_postgres-data`. Use the **same project, manifest and protected env file** every time. Do not rely on the checkout directory's implicit project name: moving/renaming the directory or choosing another `--project-name` selects different storage, which can be healthy but empty. Adding this mount does **not** adopt an older anonymous volume.

| Operation using `dc` above | PostgreSQL container | Incident, acknowledgement and audit data |
|---|---|---|
| `dc stop`, then `dc start` | Retained | Reattached to the same named volume |
| `dc down`, then `dc up --detach --wait` | Replaced | Retained in the same named volume |
| Stop Correlia, recreate PostgreSQL, then restart Correlia (below) | Replaced | Retained in the same named volume |
| `down --volumes`, explicit volume removal or host storage loss | May be replaced | Data can be deleted; not an ordinary shutdown |

For an intentional database-container replacement without deleting data:

```sh
dc stop correlia
dc up --detach --wait --force-recreate postgres
dc start correlia
dc up --detach --wait
```

`POSTGRES_USER`, `POSTGRES_DB` and `POSTGRES_PASSWORD` initialize an **empty** PostgreSQL data directory. An existing volume keeps its initialized roles, databases and passwords. Editing those values does not rotate a password or rename a database; update the actual database deliberately, then update the application's protected `DATABASE_URL` consistently. Do not delete data to repair an authentication mismatch.

This is local persistence, **not a backup or production durability guarantee**. It does not protect against volume deletion, corruption, Docker-host/disk loss or restore mistakes, and supplies no replication or backup schedule. A per-database logical archive also needs a separate roles/settings/grants inventory. Keep protected backups off the Docker host and test recovery according to your operating requirements. Intentional verification deletion belongs only to the isolated `correlia-verify-...` projects described under [Interrupted-run cleanup](#interrupted-run-cleanup), never to an operator stack.

### Preserve an older anonymous-volume database

Do this **before** starting Correlia against the new named mount. The container entrypoint runs `alembic upgrade head` before HTTP startup, and the lifecycle worker sweeps immediately at startup. An empty destination must not receive either action before restore and verification.

The following is a POSIX Linux, pinned **PG16.9** logical whole-database cutover for the default single login/owner role `correlia` and database `correlia`. It uses a fresh, explicitly selected destination project so the old source remains separate. It is not an automatic discovery/migration tool. Use trusted source data; a restore executes SQL chosen by the source's owners. Other roles, role memberships, nondefault database grants/settings, tablespaces or an ICU locale require a reviewed extension of the role/property setup below; **stop**, do not skip them or blindly replay cluster globals. Never add `--no-owner`, `--no-acl`, `--clean`, `--create` or parallel restore jobs to make an error disappear.

#### 1. Identify exactly one source and stop every writer

Start a dedicated shell from the repository root. Set `SOURCE_PROJECT` to the old stack's **recorded** project, not a guess, and choose a new destination project whose resources do not already exist:

```sh
set -eu
umask 077
SOURCE_PROJECT=correlia-local
PROJECT=correlia-local-persistent
WORK=$(mktemp -d "${TMPDIR:-/tmp}/correlia-cutover.XXXXXXXX")
chmod 700 "$WORK"
dc() {
    docker compose --project-name "$PROJECT" --env-file .env --file compose.yaml "$@"
}
SOURCE_CANDIDATES=$(docker ps --all --quiet \
    --filter "label=com.docker.compose.project=$SOURCE_PROJECT" \
    --filter "label=com.docker.compose.service=postgres")
set -- $SOURCE_CANDIDATES
if [ "$#" -ne 1 ]; then
    printf '%s\n' 'STOP: missing or ambiguous source container' >&2
    exit 1
fi
SOURCE_CONTAINER=$1
docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{println .Type .Name .Destination}}{{end}}{{end}}' \
    "$SOURCE_CONTAINER" > "$WORK/source-mount.txt"
set -- $(cat "$WORK/source-mount.txt")
if [ "$#" -ne 3 ] || [ "$1" != volume ] || [ "$3" != /var/lib/postgresql/data ]; then
    printf '%s\n' 'STOP: source mount is missing or ambiguous' >&2
    exit 1
fi
SOURCE_VOLUME=$2
docker volume inspect --format '{{.Name}}' "$SOURCE_VOLUME"
docker inspect --format '{{.Id}} {{.Config.Image}}' "$SOURCE_CONTAINER"
printf '%s\n' "$SOURCE_CONTAINER" > "$WORK/source-container-id"
printf '%s\n' "$SOURCE_VOLUME" > "$WORK/source-volume-name"
```

Verify those selected fields identify the intended PG16 database; the anonymous volume's actual name is the source identity, not its age, size or an inferred naming pattern. If the old container is already gone, stop this discovery path and use a previously recorded exact volume identity with the recovery procedure below. An unidentified detached volume needs operator investigation; no command here chooses one for you.

Fence ingress, stop schedulers/integrations and every application/worker that can write to this database, including host processes or other deployments. For the old checked-in stack:

```sh
docker compose --project-name "$SOURCE_PROJECT" --env-file .env \
    --file compose.yaml stop correlia
```

Keep the source PostgreSQL container running for the dump. Check for remaining database clients; unexpected clients are a stop gate, not a reason to terminate someone else's session:

```sh
docker exec -it --user postgres "$SOURCE_CONTAINER" psql --no-psqlrc \
    --host=127.0.0.1 --username=correlia --dbname=correlia --password \
    --set=ON_ERROR_STOP=1 \
    --command="SELECT pid, usename, application_name, state FROM pg_stat_activity WHERE datname = current_database() AND pid <> pg_backend_pid();"
```

Enter the source's **initialized password** at the prompt. It may differ from today's `.env`; do not expose it in shell arguments, history or a printed DSN. No other rows should remain, and writers must stay fenced through acceptance. Verify `SHOW server_version;` and `pg_dump --version` identify PG16 tools before continuing.

```sh
docker exec --user postgres "$SOURCE_CONTAINER" pg_dump --version
docker exec -it --user postgres "$SOURCE_CONTAINER" psql --no-psqlrc \
    --host=127.0.0.1 --username=correlia --dbname=correlia --password \
    --set=ON_ERROR_STOP=1 --command='SHOW server_version;'
```

#### 2. Record properties, roles and a durable baseline; create the archive

Use a protected SQL file to record database properties and role/database settings separately from application records:

```sh
cat > "$WORK/inventory.sql" <<'SQL'
SELECT jsonb_build_object(
  'database', (SELECT jsonb_build_object(
    'name', datname, 'owner', pg_get_userbyid(datdba),
    'encoding', pg_encoding_to_char(encoding), 'locale_provider', datlocprovider,
    'collate', datcollate, 'ctype', datctype, 'icu_locale', daticulocale,
    'collation_version', datcollversion, 'connection_limit', datconnlimit,
    'tablespace', (SELECT spcname FROM pg_tablespace WHERE oid = dattablespace),
    'grants', datacl) FROM pg_database WHERE datname = current_database()),
  'roles', (SELECT jsonb_agg(jsonb_build_object(
    'name', rolname, 'superuser', rolsuper, 'inherit', rolinherit,
    'create_role', rolcreaterole, 'create_db', rolcreatedb, 'login', rolcanlogin,
    'replication', rolreplication, 'bypass_rls', rolbypassrls,
    'connection_limit', rolconnlimit, 'valid_until', rolvaliduntil) ORDER BY rolname)
    FROM pg_roles WHERE rolname !~ '^pg_'),
  'memberships', (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'role', pg_get_userbyid(roleid), 'member', pg_get_userbyid(member),
    'admin', admin_option, 'inherit', inherit_option, 'set', set_option)
    ORDER BY roleid, member), '[]'::jsonb) FROM pg_auth_members
    WHERE pg_get_userbyid(roleid) !~ '^pg_' OR pg_get_userbyid(member) !~ '^pg_'),
  'settings', (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'database', setdatabase, 'role', setrole, 'values', setconfig)
    ORDER BY setdatabase, setrole), '[]'::jsonb) FROM pg_db_role_setting),
  'object_owners', (SELECT coalesce(jsonb_agg(DISTINCT pg_get_userbyid(c.relowner)),
    '[]'::jsonb) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'),
  'schema_grants', (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'schema', nspname, 'owner', pg_get_userbyid(nspowner), 'grants', nspacl)
    ORDER BY nspname), '[]'::jsonb) FROM pg_namespace
    WHERE nspname !~ '^pg_' AND nspname <> 'information_schema'));
SQL
cat > "$WORK/baseline.sql" <<'SQL'
SELECT jsonb_build_object(
  'revision', (SELECT jsonb_agg(version_num ORDER BY version_num) FROM alembic_version),
  'incidents', (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'status', status, 'event_count', event_count,
    'acknowledged_at', acknowledged_at, 'acknowledged_by', acknowledged_by,
    'last_update_time', last_update_time, 'window_state', window_state,
    'closed_at', closed_at, 'decision_context', decision_context) ORDER BY id),
    '[]'::jsonb) FROM incidents),
  'audit', (SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', id, 'source_id', source_id, 'fingerprint', fingerprint,
    'incident_ids', incident_ids, 'incident_effect', incident_effect,
    'decision_summary', decision_summary) ORDER BY id), '[]'::jsonb)
    FROM incident_events));
SQL
docker exec --user postgres "$SOURCE_CONTAINER" sh -eu -c \
    'umask 077; mkdir /tmp/correlia-cutover'
docker cp "$WORK/inventory.sql" "$SOURCE_CONTAINER:/tmp/correlia-cutover/inventory.sql"
docker cp "$WORK/baseline.sql" "$SOURCE_CONTAINER:/tmp/correlia-cutover/baseline.sql"
docker exec "$SOURCE_CONTAINER" chown -R postgres:postgres /tmp/correlia-cutover
for kind in inventory baseline; do
    docker exec -it --user postgres "$SOURCE_CONTAINER" sh -eu -c '
        umask 077
        exec psql --no-psqlrc --host=127.0.0.1 --username=correlia \
          --dbname=correlia --password --set=ON_ERROR_STOP=1 --tuples-only --no-align \
          --file="/tmp/correlia-cutover/$1.sql" --output="/tmp/correlia-cutover/$1.txt"
    ' sh "$kind"
    docker cp "$SOURCE_CONTAINER:/tmp/correlia-cutover/$kind.txt" "$WORK/source-$kind.txt"
done
docker exec -it --user postgres "$SOURCE_CONTAINER" sh -eu -c '
    umask 077
    exec pg_dump --host=127.0.0.1 --username=correlia --dbname=correlia \
      --password --format=custom --file=/tmp/correlia-cutover/source.dump
'
docker cp "$SOURCE_CONTAINER:/tmp/correlia-cutover/source.dump" "$WORK/source.dump"
chmod 600 "$WORK/"*
docker exec --user postgres "$SOURCE_CONTAINER" pg_restore \
    --list /tmp/correlia-cutover/source.dump > "$WORK/archive-contents.txt"
```

The custom archive is written **inside PostgreSQL's container** and transferred by `docker cp`, never host-shell binary redirection. Treat the archive, inventories and baseline as sensitive database material; keep them outside Git and do not upload them to CI artifacts or paste them into logs. This is a complete application-database dump, not selected tables or a PGDATA filesystem copy.

Review the inventory privately. The path below requires database name/owner `correlia`, exactly that one non-`pg_` role with the default image-initialized attributes, no custom-role memberships or database/role settings, default database ACL (`null`), `pg_default` tablespace and a `libc` provider (`c`). Object ownership and grants must match the intended one-role installation (`pg_database_owner` for the default public schema is normal). Do not omit object grants from the archive. Record any nondefault settings/grants and provision every required role with reviewed attributes and credentials before restore; this default path stops rather than losing them. A dump does not carry role passwords or cluster globals, and restoring to a pre-created database does not automatically reproduce all database-level properties/settings/grants.

Generate the empty database's creation command from the recorded source properties, using PostgreSQL quoting rather than copying locale text into shell SQL:

```sh
cat > "$WORK/create-target.sql" <<'SQL'
SELECT format(
  'CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L LOCALE_PROVIDER libc LC_COLLATE %L LC_CTYPE %L;',
  datname, pg_get_userbyid(datdba), pg_encoding_to_char(encoding), datcollate, datctype)
FROM pg_database WHERE datname = current_database() AND datlocprovider = 'c';
SQL
docker cp "$WORK/create-target.sql" "$SOURCE_CONTAINER:/tmp/correlia-cutover/create-target.sql"
docker exec "$SOURCE_CONTAINER" chown postgres:postgres /tmp/correlia-cutover/create-target.sql
docker exec -it --user postgres "$SOURCE_CONTAINER" sh -eu -c '
    umask 077
    exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia \
      --password --set=ON_ERROR_STOP=1 --tuples-only --no-align \
      --file=/tmp/correlia-cutover/create-target.sql --output=/tmp/correlia-cutover/create-target.sql.out
'
docker cp "$SOURCE_CONTAINER:/tmp/correlia-cutover/create-target.sql.out" "$WORK/create-target.sql.out"
test -s "$WORK/create-target.sql.out"
```

#### 3. Create only a fresh destination database, then restore transactionally

Keep the old project stopped except for its source PostgreSQL. Privately prepare the destination `.env`, including its new database password, consistent application DSN and distinct API/HMAC secrets. Preserve existing operator/ingress/HMAC secrets if clients and audit continuity require them. Do not print `docker compose config` or a full container environment.

This default path requires `POSTGRES_USER=correlia`, `POSTGRES_DB=correlia`, and an application DSN for role/database `correlia` at Compose hostname `postgres`. Build the intended application image below without starting it; do not accidentally reuse an old `correlia:local` tag.

Fail closed on inspection errors or a pre-existing destination resource; an unlabeled physical volume name is still a collision:

```sh
docker ps --all --quiet --filter "label=com.docker.compose.project=$PROJECT" > "$WORK/target-containers"
docker network ls --quiet --filter "label=com.docker.compose.project=$PROJECT" > "$WORK/target-networks"
docker volume ls --quiet --filter "label=com.docker.compose.project=$PROJECT" > "$WORK/target-volumes"
docker volume ls --format '{{.Name}}' > "$WORK/all-volume-names"
test ! -s "$WORK/target-containers"
test ! -s "$WORK/target-networks"
test ! -s "$WORK/target-volumes"
if grep -Fx "${PROJECT}_postgres-data" "$WORK/all-volume-names"; then
    printf '%s\n' 'STOP: destination physical volume already exists' >&2
    exit 1
fi
dc build correlia
POSTGRES_DB=postgres dc up --detach --wait postgres
TARGET_CONTAINER=$(dc ps --quiet postgres)
test -n "$TARGET_CONTAINER"
docker inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/var/lib/postgresql/data"}}{{println .Type .Name .Destination}}{{end}}{{end}}' \
    "$TARGET_CONTAINER" > "$WORK/target-mount.txt"
set -- $(cat "$WORK/target-mount.txt")
test "$#" -eq 3
test "$1" = volume
test "$2" = "${PROJECT}_postgres-data"
test "$2" != "$SOURCE_VOLUME"
test "$3" = /var/lib/postgresql/data
docker volume inspect --format '{{json .Labels}}' "${PROJECT}_postgres-data"
docker cp "$WORK/create-target.sql.out" "$TARGET_CONTAINER:/tmp/create-target.sql"
docker exec "$TARGET_CONTAINER" sh -eu -c '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=postgres \
      --set=ON_ERROR_STOP=1 --file=/tmp/create-target.sql
'
```

The bootstrap database is `postgres`, so `correlia` is created explicitly from **`template0`** with its recorded owner/encoding/locale; a pre-existing database makes `CREATE DATABASE` fail. The target role is initialized from the protected `.env`. Inspect its role attributes and the new database's properties against the source inventory before proceeding. No application container has been started in this new project.

Copy the archive and apply this empty-target gate immediately before the restore. It counts user relations, functions/types/schemas, nonbuiltin extensions, default ACLs and large objects, not just incident rows:

```sh
docker cp "$WORK/source.dump" "$TARGET_CONTAINER:/tmp/source.dump"
docker exec "$TARGET_CONTAINER" chown postgres:postgres /tmp/source.dump
docker exec "$TARGET_CONTAINER" chmod 600 /tmp/source.dump
docker exec --user postgres "$TARGET_CONTAINER" sh -eu -c '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    objects=$(psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia \
      --set=ON_ERROR_STOP=1 --tuples-only --no-align --command="
      SELECT
        (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
          WHERE n.nspname !~ '\''^pg_'\'' AND n.nspname <> '\''information_schema'\'') +
        (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
          WHERE n.nspname !~ '\''^pg_'\'' AND n.nspname <> '\''information_schema'\'') +
        (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
          WHERE n.nspname !~ '\''^pg_'\'' AND n.nspname <> '\''information_schema'\'') +
        (SELECT count(*) FROM pg_namespace
          WHERE nspname !~ '\''^pg_'\'' AND nspname NOT IN ('\''public'\'','\''information_schema'\'')) +
        (SELECT count(*) FROM pg_extension WHERE extname <> '\''plpgsql'\'') +
        (SELECT count(*) FROM pg_default_acl) +
        (SELECT count(*) FROM pg_largeobject_metadata);")
    if [ "$objects" != 0 ]; then
        printf "%s\n" "STOP: destination database is populated" >&2
        exit 1
    fi
    exec pg_restore --host=127.0.0.1 --username=correlia --dbname=correlia \
      --exit-on-error --single-transaction /tmp/source.dump
'
```

A populated target or any restore error is a **stop**: do not start Correlia, do not overwrite/drop the target to force success, and do not modify the source. Investigate using the retained source/archive. `--single-transaction` leaves no partially restored objects on an SQL failure; it is not permission to ignore a non-zero result.

#### 4. Verify SQL and credentials before app startup, then verify consumers

Copy the same `inventory.sql` and `baseline.sql` to the target, execute them with the target's protected initialized password and compare the results **before** starting the app:

```sh
for kind in inventory baseline; do
    docker cp "$WORK/$kind.sql" "$TARGET_CONTAINER:/tmp/$kind.sql"
    docker exec "$TARGET_CONTAINER" sh -eu -c '
        umask 077
        export PGPASSWORD="$POSTGRES_PASSWORD"
        exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia \
          --set=ON_ERROR_STOP=1 --tuples-only --no-align \
          --file="/tmp/$1.sql" --output="/tmp/$1.txt"
    ' sh "$kind"
    docker cp "$TARGET_CONTAINER:/tmp/$kind.txt" "$WORK/target-$kind.txt"
    cmp "$WORK/source-$kind.txt" "$WORK/target-$kind.txt"
done
```

Inventory settings are empty on this default path; customized inventories containing cluster-local OIDs require semantic role/database-name comparison, not raw OID equality. Confirm the incident UUIDs/status/acknowledgement fields, audit UUIDs/source IDs/fingerprints/linkage/decision summaries and exact `alembic_version` match. Acknowledgement is metadata: an acknowledged incident remains `OPEN`. Compare a long-window/non-expiring incident separately from any incident already overdue.

The target queries above use **TCP and password authentication**, not local socket trust. Confirm a deliberately incorrect password is rejected, without putting it in command arguments or changing the role:

```sh
# Enter a deliberately incorrect password at this prompt.
if docker exec -it --user postgres "$TARGET_CONTAINER" psql --no-psqlrc \
    --host=127.0.0.1 --username=correlia --dbname=correlia --password \
    --set=ON_ERROR_STOP=1 --command='SELECT current_user;'; then
    printf '%s\n' 'STOP: incorrect database password was accepted' >&2
    exit 1
fi
```

Require the failure to be **password authentication failed**, not a broken container/network; the preceding successful TCP queries establish the working credential path. The actual application DSN must use the verified role/password/database. Owner/ACL errors are failures, not reasons to suppress ownership/grants.

Only after those checks:

```sh
dc up --detach --wait
```

This may recreate the bootstrap PostgreSQL container when the `.env` initialization value returns to `POSTGRES_DB=correlia`; the named volume keeps the already restored cluster. Correlia runs startup migrations. Refresh container handles and recheck the SQL revision:

```sh
TARGET_CONTAINER=$(dc ps --quiet postgres)
APP_CONTAINER=$(dc ps --quiet correlia)
test -n "$TARGET_CONTAINER"
test -n "$APP_CONTAINER"
docker exec "$TARGET_CONTAINER" sh -eu -c '
    export PGPASSWORD="$POSTGRES_PASSWORD"
    exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia \
      --set=ON_ERROR_STOP=1 --tuples-only --no-align \
      --command="SELECT version_num FROM alembic_version"
'
```

Compare that revision to the saved baseline and the intended image's `alembic heads`. For authenticated consumer checks, use the tokens already injected into the app container, never bearer tokens in host shell arguments. Select a recorded stable incident UUID (a long-window `OPEN` record or a terminal record, not the separate overdue incident):

```sh
dc exec correlia alembic heads
```

```sh
printf '%s' 'Recorded stable incident UUID: '
IFS= read -r BASELINE_INCIDENT_ID
docker cp "$WORK/source-baseline.txt" "$APP_CONTAINER:/tmp/cutover-baseline.json"
docker exec --user root "$APP_CONTAINER" chown correlia:correlia /tmp/cutover-baseline.json
docker exec --interactive --env "BASELINE_INCIDENT_ID=$BASELINE_INCIDENT_ID" \
    "$APP_CONTAINER" python - <<'PY'
import json
import os
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from uuid import UUID
from time import sleep

base = "http://127.0.0.1:8000"
operator = os.environ["CORRELIA_OPERATOR_API_TOKEN"]
ingress = os.environ["CORRELIA_INGRESS_API_TOKEN"]
saved = json.loads(Path("/tmp/cutover-baseline.json").read_text())
incident_id = str(UUID(os.environ["BASELINE_INCIDENT_ID"]))
expected = next(row for row in saved["incidents"] if row["id"] == incident_id)

def request(path, token):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    probe = Request(base + path, headers=headers)
    while True:
        try:
            with urlopen(probe, timeout=5) as response:
                return response.status, json.load(response)
        except HTTPError as error:
            if error.code != 429 or token != operator:
                return error.code, None
            retry_after = error.headers.get("Retry-After", "")
            if not retry_after.isascii() or not retry_after.isdecimal() or int(retry_after) < 1:
                raise RuntimeError("Expected a positive numeric Retry-After for operator GET") from error
            sleep(int(retry_after))

for path in ("/v1/readyz", f"/v1/incidents/{incident_id}", "/v1/incident-events"):
    for token in (None, "cutover-invalid-operator", ingress):
        assert request(path, token)[0] == 401
assert request("/v1/readyz", operator)[0] == 200
status, incident = request(f"/v1/incidents/{incident_id}", operator)
assert status == 200 and incident["id"] == expected["id"]
assert incident["status"] == expected["status"]
assert incident["acknowledgement"]["acknowledged_by"] == expected["acknowledged_by"]
# PostgreSQL JSON and HTTP use different timestamp renderings; compare instants.
from datetime import datetime
if expected["acknowledged_at"] is None:
    assert incident["acknowledgement"]["acknowledged_at"] is None
else:
    assert datetime.fromisoformat(incident["acknowledgement"]["acknowledged_at"]) == \
        datetime.fromisoformat(expected["acknowledged_at"])
fields = ("id", "source_id", "fingerprint", "incident_ids", "incident_effect", "decision_summary")
baseline_ids = {row["id"] for row in saved["audit"]}
actual_audit = {}
cursor = None
while True:
    query = {"limit": 200}
    if cursor is not None:
        query["cursor"] = cursor
    status, page = request("/v1/incident-events?" + urlencode(query), operator)
    assert status == 200
    actual_audit.update({
        row["id"]: {key: row[key] for key in fields}
        for row in page["items"] if row["id"] in baseline_ids
    })
    cursor = page["next_cursor"]
    if cursor is None:
        break
for audit in saved["audit"]:
    assert actual_audit[audit["id"]] == {key: audit[key] for key in fields}
print("Restored incident/acknowledgement/audit and operator role boundaries verified")
PY
```

The probe scans the audit endpoint once globally, using 200-row pages and `next_cursor`, retaining the baseline audit IDs and selected values; it must not accept a missing baseline row. Operator verification GETs honor a 429 response's positive numeric `Retry-After` by sleeping and retrying the same path/page without relaxing quotas. A missing or invalid header stops the probe; other errors are not retried. No raw payloads are needed. PostgreSQL JSON timestamps and HTTP timestamps can differ in spelling; compare timestamp **instants**, not their rendered strings.

After the baseline matches and startup expiry changes are understood, prepare **one intended new monitoring event** in a protected `$WORK/accepted-event.json` file, with a new `source_id` and a payload that matches the configured rules. Then admit and read back its committed records:

```sh
test -s "$WORK/accepted-event.json"
chmod 600 "$WORK/accepted-event.json"
docker cp "$WORK/accepted-event.json" "$APP_CONTAINER:/tmp/cutover-accepted-event.json"
docker exec --user root "$APP_CONTAINER" chown correlia:correlia /tmp/cutover-accepted-event.json
docker exec --interactive "$APP_CONTAINER" python - <<'PY'
import json
import os
from pathlib import Path
from time import sleep
from urllib.error import HTTPError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

base = "http://127.0.0.1:8000"
operator = os.environ["CORRELIA_OPERATOR_API_TOKEN"]
event = json.loads(Path("/tmp/cutover-accepted-event.json").read_text())
saved = json.loads(Path("/tmp/cutover-baseline.json").read_text())
assert event["source_id"] not in {row["source_id"] for row in saved["audit"]}
def request(path, token, payload=None):
    headers = {"Authorization": f"Bearer {token}"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode()
    probe = Request(base + path, data=data, headers=headers)
    while True:
        try:
            with urlopen(probe, timeout=5) as response:
                assert response.status == 200
                return json.load(response)
        except HTTPError as error:
            if error.code != 429 or data is not None or token != operator:
                raise
            retry_after = error.headers.get("Retry-After", "")
            if not retry_after.isascii() or not retry_after.isdecimal() or int(retry_after) < 1:
                raise RuntimeError("Expected a positive numeric Retry-After for operator GET") from error
            sleep(int(retry_after))
accepted = request("/v1/icinga2/events", os.environ["CORRELIA_INGRESS_API_TOKEN"], event)
incident_id = accepted["incident_id"]
assert incident_id is not None
assert request(f"/v1/incidents/{incident_id}", operator)["id"] == incident_id
page = request("/v1/incident-events?" + urlencode({"source_id": event["source_id"]}), operator)
assert page["total"] == 1 and page["items"][0]["incident_ids"] == [incident_id]
assert page["items"][0]["id"] not in {row["id"] for row in saved["audit"]}
print("New accepted event has a committed incident and new audit identity")
PY
```

The new-write probe uses the same 429 backoff only for operator verification GETs. It never retries the ingress POST or any other error.

A healthy empty database, an accepted task or SMTP delivery is not migration proof. Keep the source and archive retained while making this acceptance decision.

#### Recovery and the rollback boundary

Retain the original source volume, recorded mount identity and protected archive through operator acceptance. If the source container is still present, keep all its writers stopped and inspect/query that exact container. To reopen a detached **recorded existing** source, first ensure no PostgreSQL process is using its volume. Stop the source container if present; if detaching it is necessary, `docker rm "$SOURCE_CONTAINER"` without `--volumes` retains the recorded volume.

Create this recovery-only manifest in the protected `$WORK` directory; it is not the default persistent stack:

```sh
cat > "$WORK/source-recovery.yaml" <<'YAML'
services:
  recovered-postgres:
    image: postgres:16.9-alpine
    environment:
      POSTGRES_USER: correlia
      POSTGRES_DB: correlia
    volumes:
      - retained-source:/var/lib/postgresql/data
    networks:
      - recovery
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U correlia -d correlia"]
      interval: 2s
      timeout: 3s
      retries: 30
volumes:
  retained-source:
    external: true
    name: ${SOURCE_VOLUME:?recorded exact source volume is required}
networks:
  recovery:
    internal: true
YAML
export SOURCE_VOLUME
docker volume inspect --format '{{.Name}}' "$SOURCE_VOLUME"
docker compose --project-name "$SOURCE_PROJECT" --file "$WORK/source-recovery.yaml" \
    up --detach --wait recovered-postgres
```

The exact **external Compose volume** fails if it is absent and does not create a replacement. Neither `docker run -v` nor `--mount type=volume` supplies that guarantee: Docker can auto-create a named volume. Missing or ambiguous identity means **stop without guessing**. Inspect the recovery container's actual mount, re-run the saved SQL baseline/inventory with the initialized source password, and compare before resuming any source app. Do not mount a running source cluster concurrently, prune volumes, or use a reset as recovery.

The mutation-free rollback boundary ends at **destination application startup**, not when ingress resumes: Alembic can change the schema, and the worker's first asynchronous sweep can close restored overdue `OPEN` incidents immediately (`closed_at` plus `lifecycle.reason=expired`) without creating an audit event. Poll the separate overdue incident to observe that transition; do not let it invalidate a non-expiring baseline. Before destination startup, returning to the unchanged source can recover the saved application baseline. After startup, stop destination writers and review/reconcile schema changes, lifecycle expiry and all accepted writes before deciding how to return; merely repointing the DSN cannot promise lossless rollback.

Do not automatically delete the operator's source or archive on success or failure. Keep them protected until acceptance and an adequate backup/recovery decision. The verification rehearsal deletes only its own synthetic, invocation-owned resources by recorded names after exercising these checks.

Command semantics: [PG16 `pg_dump`](https://www.postgresql.org/docs/16/app-pgdump.html), [transactional `pg_restore`](https://www.postgresql.org/docs/16/app-pgrestore.html), [`CREATE DATABASE`/`template0`](https://www.postgresql.org/docs/16/sql-createdatabase.html), and [Compose external-volume absence behavior](https://docs.docker.com/reference/compose-file/volumes/#external). These references explain the procedure; documentation alone is not runtime migration evidence.

## Production authentication and route exposure

Production must be selected explicitly; the application does not infer it from network location. With valid database/configuration inputs, set all four policy values:

```bash
CORRELIA_ENVIRONMENT=production
CORRELIA_API_AUTH_ENABLED=true
CORRELIA_EXPOSE_READYZ=false
CORRELIA_EXPOSE_METRICS=false
```

Supply distinct, non-empty `CORRELIA_OPERATOR_API_TOKEN`, `CORRELIA_INGRESS_API_TOKEN`, and `CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY` through protected deployment configuration. Production application authentication is mandatory, even behind an authenticated proxy. The operator and ingress tokens grant separate roles; neither grants the other role.

An omitted environment means `local`. Direct application settings retain defaults of authentication enabled and both operational exposure flags `true`; Compose and `.env.example` instead set readiness exposure `false` and metrics exposure `true`. These nonproduction defaults are unchanged. Selecting production alone intentionally fails: both flags must resolve to `false`, whether supplied explicitly or through deployment environment values. Production rejects authentication disabled or either exposure flag `true` before the application can serve requests; it does not silently clamp values or substitute safer defaults.

### Settings ownership and precedence

`create_app(settings=...)` uses the supplied `Settings` instance rather than loading another one from the process environment. Explicit `Settings(...)` constructor values take precedence over environment values for the same field. Without injection, the factory resolves settings from the process environment and defaults. One resolved settings instance owns the factory's route surface, lifespan initialization, and request dependencies; lifespan does not reload settings.

Host startup does not automatically load `.env` (see [Local factory startup](#local-factory-startup)). Compose's `.env`/`--env-file` handling is a separate CLI interpolation step: the [Compose shell environment takes precedence over env-file values](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/), and this manifest passes interpolated `environment:` values into the container. A safe-looking env file therefore does not prove the effective container policy. Check only the resolved environment selector and three nonsecret policy flags; do not print or log full rendered Compose configuration, container environments, or secret-bearing diagnostics.

Startup rejection guarantees no application serving, not that no database work or dependency resources were started. Compose starts its dependencies first, and the checked-in container entrypoint runs `alembic upgrade head` before starting the one-worker Uvicorn HTTP backend.

### Normative route matrix

“Operator” and “Ingress” require the matching bearer token when authentication is enabled. Local/test with authentication disabled bypass those role dependencies, including readiness/metrics protection regardless of the exposure flags. Production cannot select that mode.

| Method and path | Local/test, auth enabled | Local/test, auth disabled | Valid production |
|---|---|---|---|
| GET `/v1/health` | Public minimal liveness | Public minimal liveness | Public minimal liveness |
| GET `/v1/readyz` | Public if `expose_readyz=true`; otherwise Operator | Public, regardless of exposure flag | Operator |
| GET `/v1/metrics` | Public if `expose_metrics=true`; otherwise Operator | Public, regardless of exposure flag | Operator |
| POST `/v1/icinga2/events` | Ingress | Public | Ingress |
| GET `/v1/plugins` | Operator | Public | Operator |
| GET `/v1/rules` | Operator | Public | Operator |
| GET `/v1/topology` | Operator | Public | Operator |
| GET `/v1/incidents` | Operator | Public | Operator |
| GET `/v1/incidents/{incident_id}` | Operator | Public | Operator |
| POST `/v1/incidents/{incident_id}/ack` | Operator | Public | Operator |
| POST `/v1/incidents/{incident_id}/close` | Operator | Public | Operator |
| PATCH `/v1/incidents/{incident_id}` | Operator; compatibility acknowledge/close | Public; compatibility acknowledge/close | Operator; compatibility acknowledge/close |
| DELETE `/v1/incidents/{incident_id}` | Operator; compatibility close, not deletion | Public; compatibility close, not deletion | Operator; compatibility close, not deletion |
| GET `/v1/incident-events` | Operator | Public | Operator |
| GET `/docs` | Public Swagger | Public Swagger | Absent |
| GET `/redoc` | Public ReDoc | Public ReDoc | Absent |
| GET `/openapi.json` | Public schema | Public schema | Absent |
| GET `/docs/oauth2-redirect` | Public documentation helper | Public documentation helper | Absent |

Missing, invalid, and wrong-role credentials receive generic `401` denial on protected supported methods with syntactically valid bounded requests and available rate-limit capacity, without protected handler output or work. Existing routing, validation, size, and rate-limit precedence still applies; unsupported methods, malformed/oversized requests, or exhausted quotas need not return `401`. Production's four documentation URLs are absent, not merely authenticated: credentials do not restore them, and exact/trailing-slash GET/HEAD requests return `404` without following redirects. Obsolete unprefixed API paths remain absent.

### External TLS, backend reachability, and proxy trust

The repository supplies an HTTP backend, not a TLS terminator or production proxy. Before any external bearer-bearing request, establish **certificate-verified HTTPS** to the intended endpoint. Do not send a token over HTTP to test a redirect: redirecting afterward cannot undo disclosure. Keep credentials out of URLs and proxy/application diagnostics. Restrict readiness, metrics, and operator API routes at the edge to the operator/monitoring network, consistent with [OWASP management-endpoint guidance](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html#management-endpoints). Do not have the proxy inject a shared privileged token for arbitrary clients; application role checks must remain meaningful.

Choose and qualify the actual topology rather than combining these two designs:

- **Host reverse proxy:** retain a backend publication bound to host loopback, as the local manifest does at `127.0.0.1:8000`, and terminate external HTTPS at the host proxy. Loopback publication does not exclude host processes or prove all container/network paths are blocked.
- **Containerized reverse proxy:** use a controlled private network between proxy and backend, with no backend host-port publication. This requires deployment-specific networking, not a proxy already supplied by `compose.yaml`. An unpublished backend port is not “proxy-only”: the host and same-bridge peers may still reach it. Limit network membership and enforce the intended reachability.

The proxy-to-application HTTP hop carries bearer credentials in plaintext. Trust and protect that hop and its host/network peers; encrypt it if the network is untrusted or crosses hosts. Application authentication does not replace transport confidentiality or backend isolation. See [OWASP HTTPS and access-control guidance](https://cheatsheetseries.owasp.org/cheatsheets/REST_Security_Cheat_Sheet.html) and [Docker port-publishing behavior](https://docs.docker.com/engine/network/port-publishing/).

Forwarded metadata is neither authentication nor proof of TLS. Configure an explicit allowlist of trusted **connecting proxy peers**, based on the peer addresses the backend actually sees, and ensure the proxy overwrites untrusted incoming forwarding metadata. Pinned [Uvicorn 0.49.0 proxy handling](https://github.com/Kludex/uvicorn/blob/0.49.0/uvicorn/middleware/proxy_headers.py) defaults to trusting `127.0.0.1`; a proxy reached through container networking is not necessarily that peer. It processes `X-Forwarded-Proto` and `X-Forwarded-For` for scheme/client IP, not `X-Forwarded-Host`. Preserve or set the real `Host` header as required by the deployment. Do not use wildcard forwarding trust as a substitute for an explicit peer boundary.

Qualify IPv4 and IPv6, bridge membership, Docker direct routing/gateway modes, and Docker-aware firewall paths. Docker documents a localhost-published-port caveat for Engine versions before 28; [Docker firewall integration](https://docs.docker.com/engine/network/packet-filtering-firewalls/) also explains why a generic host firewall/ufw claim is not isolation proof. On the real topology, establish certificate trust first, then verify permitted proxy/operator/ingress traffic and blocked direct backend access from external IPv4/IPv6 and routable-container positions. Do not send real bearer credentials on an exposed plaintext probe path.

### Activation, rollback, and evidence boundaries

Prepare the production policy inputs, protected credentials, and operator-authenticated readiness/metrics monitoring before activation. If startup rejects effective settings, correct the inputs or keep the service unavailable. Never disable authentication, expose operations, or select local/test as an availability workaround.

Roll back only to an image/configuration proven to preserve the production authentication and route surface. Check compatibility with the current database schema first: migrations may already have run, and rollback must not automatically downgrade the database.

The checked-in image/Compose loopback HTTP smoke is the verification gate for application policy, authorized behavior, and unsafe-settings rejection; a passing run does **not** qualify external HTTPS, certificate trust, or backend network isolation. Those are separate deployment-operator checks before public operation.

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
        topology.datacenter: "prm1"
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

`match.host_pattern` and optional `match.service_pattern` are regular expressions; `match.tags` values use literal string equality. The priority-1 datacenter rule therefore requires `topology.datacenter=prm1`: `".+"` is not a tag wildcard. Rules are checked in ascending priority order, and the first match wins. For a CRITICAL PROBLEM event on `prm1-prd-web01` tagged `topology.datacenter=prm1`, the DC-Level Outage Aggregator selects the group `topology.datacenter=prm1`. With `topology.datacenter=prm2` or no datacenter tag, the Host Alert Aggregator instead selects `host=prm1-prd-web01` for that eligible host and severity. Rule selection alone does not cross a threshold or confirm notification delivery.

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
- Unknown source schema fields fail closed with `unknown_source_field` (`CFG-06`), rather than being silently dropped. Checks cover the rules document root, rule entries, `match`, `window`, the topology document root, `topology_rules`, hostname-pattern entries, subnet entries, and plugin output entries. Reports identify the exact source path, such as `rules[0].match.foo`, `topology_rules.hostname_patterns[0].foo`, or `plugins.outputs.email-ops.foo`; an unknown document-root key is reported as that key alone. Remove or explicitly translate each rejected field before retrying.
- Tag names inside rule/hostname `tags` mappings and output names inside plugin `outputs` are data, not schema fields, and remain open to valid user-defined names. Known unsupported fields (`is_dc_level`, `window.min_hosts`) retain their dedicated error codes.
- Unknown Vigilo email plugin option keys (e.g. `smtp_timeout`, `connection_pool_size`) are rejected with the existing `unsupported_plugin_option` code so unmapped semantics are not silently copied or dropped.
- Any top-level plugin section other than `outputs` is rejected with the existing `unsupported_plugin_section` code, including generic unknown section names.
- Unsupported fields across all three input files are aggregated into one structured report (`ok: false`, `errors: [...]`, `generated: null`) before the CLI exits non-zero.
- Generated files are staged in a temporary directory, validated through Correlia's loaders plus generated email plugin instantiation, and only then atomically promoted to `--out-dir`. A failed migration leaves `--out-dir` untouched.
- The converter rejects an unsupported converted `window.trigger_threshold` without promoting files. If staged validation reaches the shared rule loader, recognized threshold errors appear in the report at `rules[index].window.trigger_threshold` with the supported 1–100 bound, without echoing raw values or configuration content. Other errors within that rule validation retain generic sanitized entries; plugin construction and other loader failures remain generic and fail fast rather than aggregating errors across stages.

## Current gaps before exact VDE parity

- No direct config support for VDE `min_hosts` thresholds.
- No direct config support for VDE `is_dc_level` notification suppression semantics.
- No actionless tracking rule support because Correlia rejects empty action lists.
- No config surface yet for input plugins, enrichment plugins, decision/processor plugins, or task-runner adapters.
- No first-class secret references in `plugins.yaml`; operators must supply credentials outside the migration artifact.
