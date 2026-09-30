"""Temporary U3 Linux evidence carrier; remove after recording the CI rehearsal."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import importlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from typing import Any
from uuid import UUID, uuid4

import pytest
import yaml

from scripts import cleanup_verification


_EMPTY_TARGET_SQL = """
SELECT
  (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
  (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
  (SELECT count(*) FROM pg_type t JOIN pg_namespace n ON n.oid=t.typnamespace
    WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema') +
  (SELECT count(*) FROM pg_namespace
    WHERE nspname !~ '^pg_' AND nspname NOT IN ('public','information_schema')) +
  (SELECT count(*) FROM pg_extension WHERE extname <> 'plpgsql') +
  (SELECT count(*) FROM pg_default_acl) +
  (SELECT count(*) FROM pg_largeobject_metadata);
"""

_INVENTORY_SQL = """
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
"""

_BASELINE_SQL = """
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
"""

_SOURCE_IDENTITY_GATE = """
set -- $SOURCE_CANDIDATES
if [ "$#" -ne 1 ]; then
    printf '%s\n' 'STOP: missing or ambiguous source container' >&2
    exit 1
fi
exec docker inspect --format '{{.Id}}' "$1"
"""


def rehearse_local_postgres_migration(stack: dict[str, object], tmp_path: Path) -> None:
    """Use the acquired canonical stack, never another application stack or fixture."""
    # Runtime import follows pytest's test-module import convention and avoids a
    # cycle when the canonical smoke imports this temporary helper locally.
    deployment = importlib.import_module("test_deployment")

    project = str(stack["project"])
    invocation = str(stack["invocation"])
    receipt = stack["ownership_receipt"]
    assert isinstance(receipt, Path)
    assert cleanup_verification.has_ownership(project, invocation, receipt)
    secrets = stack["secrets"]
    environment = stack["environment"]
    assert isinstance(secrets, dict)
    assert isinstance(environment, dict)
    operator_token = str(secrets["operator_token"])
    ingress_token = str(secrets["ingress_token"])
    password = str(secrets["postgres_password"])
    canonical_pg = deployment._require_docker_success(
        deployment._docker_compose_arguments(stack, "ps", "--quiet", "postgres")
    ).stdout.strip()
    canonical_app = deployment._require_docker_success(
        deployment._docker_compose_arguments(stack, "ps", "--quiet", "correlia")
    ).stdout.strip()
    assert canonical_pg and canonical_app
    pg_image = deployment._require_docker_success(
        ["inspect", "--format", "{{.Config.Image}}", canonical_pg]
    ).stdout.strip()
    app_image = deployment._require_docker_success(
        ["inspect", "--format", "{{.Image}}", canonical_app]
    ).stdout.strip()
    network = f"{project}_database"
    network_labels = deployment._docker_json(
        ["network", "inspect", "--format", "{{json .Labels}}", network]
    )
    assert isinstance(network_labels, dict)
    assert network_labels.get("com.docker.compose.project") == project

    suffix = uuid4().hex[:10]
    source_name = f"{project}-u3-source-{suffix}"
    target_name = f"{project}-u3-target-{suffix}"
    target_volume = f"{project}_u3-target-{suffix}"
    target_app = f"{project}-u3-target-app-{suffix}"
    source_app = f"{project}-u3-source-app-{suffix}"
    recovery_name = f"{project}-u3-recovery-{suffix}"
    missing_name = f"{project}_u3-missing-{suffix}"
    marker = f"io.correlia.migration-rehearsal={invocation}-{suffix}"
    destination_label = f"io.correlia.migration-destination={invocation}-{suffix}"
    source_volume: str | None = None
    containers: list[str] = []
    named_volumes: list[str] = []
    work = tmp_path / f"u3-migration-{suffix}"
    work.mkdir(mode=0o700)
    work.chmod(0o700)
    report: dict[str, object] = {}

    def protected_file(name: str, contents: str) -> Path:
        path = work / name
        path.write_text(contents, encoding="utf-8")
        path.chmod(0o600)
        return path

    def volume_names() -> set[str]:
        return set(
            deployment._require_docker_success(
                ["volume", "ls", "--format", "{{.Name}}"]
            ).stdout.splitlines()
        )

    def container_names() -> set[str]:
        return set(
            deployment._require_docker_success(
                ["ps", "--all", "--format", "{{.Names}}"]
            ).stdout.splitlines()
        )

    def mount(container: str) -> str:
        mounts = deployment._docker_json(
            ["inspect", "--format", "{{json .Mounts}}", container]
        )
        assert isinstance(mounts, list)
        selected = [
            item
            for item in mounts
            if isinstance(item, dict)
            and item.get("Destination") == "/var/lib/postgresql/data"
        ]
        assert len(selected) == 1
        assert selected[0]["Type"] == "volume"
        name = selected[0]["Name"]
        assert isinstance(name, str) and name
        return name

    def sql(container: str, command: str, *, database: str = "correlia") -> str:
        result = deployment._docker(
            [
                "exec",
                "--interactive",
                container,
                "sh",
                "-eu",
                "-c",
                'export PGPASSWORD="$POSTGRES_PASSWORD"; '
                "exec psql --no-psqlrc --host=127.0.0.1 --username=correlia "
                '--dbname="$1" --set=ON_ERROR_STOP=1 --tuples-only --no-align',
                "sh",
                database,
            ],
            input_data=command,
        )
        if result.returncode != 0:
            pytest.fail("U3 SQL command failed; diagnostics withheld", pytrace=False)
        return result.stdout.strip()

    def snapshot(container: str) -> dict[str, Any]:
        value = json.loads(sql(container, _BASELINE_SQL))
        assert isinstance(value, dict)
        return value

    def inventory(container: str) -> dict[str, Any]:
        value = json.loads(sql(container, _INVENTORY_SQL))
        assert isinstance(value, dict)
        return value

    def wait_pg(container: str) -> None:
        deployment._wait_until(
            "U3 PostgreSQL TCP readiness",
            lambda: (
                deployment._docker(
                    [
                        "exec",
                        container,
                        "sh",
                        "-eu",
                        "-c",
                        'export PGPASSWORD="$POSTGRES_PASSWORD"; '
                        "psql --no-psqlrc --host=127.0.0.1 --username=correlia "
                        '--dbname=postgres --set=ON_ERROR_STOP=1 --command="SELECT 1"',
                    ]
                ).returncode
                == 0
            ),
            timeout=60,
        )

    def start_pg(name: str, database: str, volume: str | None = None) -> str:
        assert name not in container_names()
        pg_env = protected_file(
            f"{name}.env",
            f"POSTGRES_USER=correlia\nPOSTGRES_DB={database}\n"
            f"POSTGRES_PASSWORD={password}\n",
        )
        arguments = [
            "run",
            "--detach",
            "--name",
            name,
            "--label",
            f"com.docker.compose.project={project}",
            "--label",
            marker,
            "--network",
            network,
            "--env-file",
            str(pg_env),
        ]
        if volume is not None:
            arguments.extend(
                [
                    "--mount",
                    f"type=volume,source={volume},target=/var/lib/postgresql/data",
                ]
            )
        containers.append(name)
        deployment._require_docker_success([*arguments, pg_image])
        # The implicit image VOLUME supplies real anonymous source storage.
        actual_volume = mount(name)
        if volume is not None:
            assert actual_volume == volume
        return actual_volume

    def http(
        app: str,
        path: str,
        *,
        token: str | None = operator_token,
        payload: dict[str, object] | None = None,
        method: str = "GET",
    ) -> tuple[int, bytes]:
        return deployment._container_http_response(
            app,
            f"http://127.0.0.1:8000{path}",
            token=token,
            payload=payload,
            method=method,
        )

    def get_json(app: str, path: str) -> object:
        status, body = http(app, path)
        assert status == 200
        return json.loads(body)

    def start_app(name: str, host: str, *, destination: bool = False) -> None:
        assert name not in container_names()
        app_environment = {
            **environment,
            "DATABASE_URL": f"postgresql+asyncpg://correlia:{password}@{host}:5432/correlia",
        }
        app_env = protected_file(
            f"{name}.env",
            "\n".join(
                f"{key}={value}"
                for key, value in app_environment.items()
                if key == "DATABASE_URL" or key.startswith("CORRELIA_")
            )
            + "\n",
        )
        probe_stack = {**stack, "env_file": app_env}
        containers.append(name)
        arguments = deployment._docker_compose_arguments(
            probe_stack,
            "--file",
            str(app_override),
            "run",
            "--detach",
            "--no-deps",
            "--name",
            name,
            "--label",
            marker,
        )
        if destination:
            arguments.extend(["--label", destination_label])
        deployment._require_docker_success(
            [*arguments, "correlia"], environment=app_environment
        )
        deployment._wait_until(
            "U3 authenticated application readiness",
            lambda: http(name, "/v1/readyz")[0] == 200,
            timeout=60,
        )

    def destination_unstarted() -> None:
        assert not deployment._require_docker_success(
            ["ps", "--all", "--quiet", "--filter", f"label={destination_label}"]
        ).stdout.strip()
        assert target_app not in container_names()

    def ingest(app: str, host: str, index: int) -> tuple[str, str]:
        source_id = f"icinga2:service:{host}:http:{index}"
        status, body = http(
            app,
            "/v1/icinga2/events",
            token=ingress_token,
            method="POST",
            payload={
                "source_id": source_id,
                "host": host,
                "service": "http",
                "state": "CRITICAL",
                "state_type": "HARD",
                "timestamp": (
                    datetime.now(timezone.utc) + timedelta(seconds=index)
                ).isoformat(),
                "ip_address": "192.0.2.10",
                "check_output": f"Migration rehearsal HTTP 503 sample {index}",
                "tags": {"team.name": "platform", "topology.datacenter": "dc1"},
            },
        )
        assert status == 200
        response = json.loads(body)
        assert response["threshold_crossed"] is True
        return str(UUID(str(response["incident_id"]))), source_id

    def incident_api(app: str, incident_id: str) -> dict[str, object]:
        incident = get_json(app, f"/v1/incidents/{incident_id}")
        assert isinstance(incident, dict)
        return {
            key: incident[key]
            for key in (
                "id",
                "rule_name",
                "group_key",
                "status",
                "event_count",
                "affected_hosts",
                "affected_services",
                "acknowledgement",
                "window_state",
                "closed_at",
            )
        }

    def audit_api(app: str) -> dict[str, dict[str, Any]]:
        page = get_json(app, "/v1/incident-events?limit=200")
        assert isinstance(page, dict)
        items = page["items"]
        assert isinstance(items, list)
        assert page["total"] == len(items)
        return {
            str(item["id"]): {
                key: item[key]
                for key in (
                    "id",
                    "source_id",
                    "fingerprint",
                    "incident_ids",
                    "incident_effect",
                    "decision_summary",
                )
            }
            for item in items
        }

    def restore(
        database: str, *, archive_path: str = "/tmp/source.dump"
    ) -> subprocess.CompletedProcess[str]:
        # The same real empty-target command gate used in CONFIGURATION.md,
        # followed by the real transactional restore (never a fake failure).
        restore_script = (
            'export PGPASSWORD="$POSTGRES_PASSWORD"\n'
            "objects=$(psql --no-psqlrc --host=127.0.0.1 --username=correlia "
            '--dbname="$1" --set=ON_ERROR_STOP=1 --tuples-only --no-align '
            '--command="$2")\n'
            'if [ "$objects" != 0 ]; then\n'
            '  printf "%s\\n" "STOP: destination database is populated" >&2\n'
            "  exit 1\n"
            "fi\n"
            'exec pg_restore --host=127.0.0.1 --username=correlia --dbname="$1" '
            '--exit-on-error --single-transaction "$3"'
        )
        return deployment._docker(
            [
                "exec",
                "--user",
                "postgres",
                target_name,
                "sh",
                "-eu",
                "-c",
                restore_script,
                "sh",
                database,
                _EMPTY_TARGET_SQL,
                archive_path,
            ]
        )

    def recovery_compose(volume: str, service: str, name: str) -> Path:
        return protected_file(
            f"{service}.yaml",
            yaml.safe_dump(
                {
                    "services": {
                        service: {
                            "image": pg_image,
                            "container_name": name,
                            "labels": {
                                marker.partition("=")[0]: marker.partition("=")[2]
                            },
                            "environment": {
                                "POSTGRES_USER": "correlia",
                                "POSTGRES_DB": "correlia",
                            },
                            "volumes": ["retained-source:/var/lib/postgresql/data"],
                            "networks": ["database"],
                        }
                    },
                    "volumes": {"retained-source": {"external": True, "name": volume}},
                    "networks": {"database": {"external": True, "name": network}},
                }
            ),
        )

    def external_up(manifest: Path, service: str) -> subprocess.CompletedProcess[str]:
        return deployment._docker(
            [
                "compose",
                "--project-name",
                project,
                "--file",
                str(manifest),
                "up",
                "--detach",
                "--no-deps",
                service,
            ]
        )

    try:
        rules = protected_file(
            "rules.yaml",
            yaml.safe_dump(
                {
                    "rules": [
                        {
                            "name": "migration-long-window",
                            "priority": 0,
                            "match": {"severities": ["CRITICAL"], "host_pattern": ".+"},
                            "window": {
                                "duration_seconds": 315_360_000,
                                "group_by": ["host"],
                                "trigger_threshold": 1,
                            },
                            "output_summary": "Migration baseline on {host}",
                            "actions": [
                                {"name": "create_incident", "plugin": "email-ops"}
                            ],
                        }
                    ]
                }
            ),
        )
        # Only this nonsecret bind-mounted file must be readable by USER correlia.
        rules.chmod(0o644)
        app_override = protected_file(
            "app-override.yaml",
            yaml.safe_dump(
                {
                    "services": {
                        "correlia": {
                            "image": app_image,
                            "environment": {
                                "CORRELIA_RULES_PATH": "/app/u3/rules.yaml",
                                # Any expiry observed before 30s must be the
                                # immediate first sweep, not the next interval.
                                "CORRELIA_LIFECYCLE_SCAN_INTERVAL_SECONDS": "86400",
                            },
                            "volumes": [f"{rules}:/app/u3/rules.yaml:ro"],
                        }
                    }
                }
            ),
        )
        source_volume = start_pg(source_name, "correlia")
        wait_pg(source_name)
        source_container_id = deployment._require_docker_success(
            ["inspect", "--format", "{{.Id}}", source_name]
        ).stdout.strip()
        canonical_storage = stack["postgres_storage"]
        assert isinstance(canonical_storage, dict)
        assert source_volume != str(canonical_storage["name"])
        tool_version = deployment._require_docker_success(
            ["exec", source_name, "pg_dump", "--version"]
        ).stdout.strip()
        assert " 16." in tool_version
        assert sql(source_name, "SHOW server_version;").startswith("16.")
        start_app(source_app, source_name)
        image_head = deployment._require_docker_success(
            ["exec", source_app, "alembic", "heads"]
        ).stdout.split()[0]
        primary_id, first_source_id = ingest(source_app, f"u3-baseline-{suffix}", 0)
        repeated_id, _ = ingest(source_app, f"u3-baseline-{suffix}", 1)
        assert repeated_id == primary_id
        status, acknowledged_body = http(
            source_app,
            f"/v1/incidents/{primary_id}/ack",
            method="POST",
            payload={"operator": "migration-operator"},
        )
        assert status == 200
        acknowledgement = json.loads(acknowledged_body)["acknowledgement"]
        assert acknowledgement["acknowledged_by"] == "migration-operator"
        assert acknowledgement["acknowledged_at"] is not None
        overdue_id, _ = ingest(source_app, f"u3-overdue-{suffix}", 2)
        primary_api = incident_api(source_app, primary_id)
        assert primary_api["status"] == "OPEN"
        assert primary_api["event_count"] == 2
        source_audit_api = audit_api(source_app)
        assert len(source_audit_api) == 3
        assert any(
            item["source_id"] == first_source_id
            and item["incident_ids"] == [primary_id]
            for item in source_audit_api.values()
        )
        # Stop every actual source writer before the baseline and archive.
        deployment._require_docker_success(["stop", "--time", "30", source_app])
        assert (
            sql(
                source_name,
                "SELECT count(*) FROM pg_stat_activity WHERE datname = current_database() "
                "AND pid <> pg_backend_pid();",
            )
            == "0"
        )
        sql(
            source_name,
            "UPDATE incidents SET last_update_time = now() - interval '1 hour', "
            "window_state = jsonb_set(window_state, '{window_seconds}', '5'::jsonb) "
            f"WHERE id = '{overdue_id}'::uuid;",
        )
        baseline = snapshot(source_name)
        source_inventory = inventory(source_name)
        properties = source_inventory["database"]
        assert isinstance(properties, dict)
        assert properties["name"] == properties["owner"] == "correlia"
        assert properties["locale_provider"] == "c"
        assert properties["grants"] is None
        assert properties["tablespace"] == "pg_default"
        assert source_inventory["memberships"] == []
        assert source_inventory["settings"] == []
        roles = source_inventory["roles"]
        assert isinstance(roles, list) and len(roles) == 1
        assert roles[0]["name"] == "correlia"
        assert roles[0]["login"] is True and roles[0]["superuser"] is True
        assert baseline["revision"] == [image_head]
        protected_file("source-inventory.json", json.dumps(source_inventory))
        baseline_file = protected_file("source-baseline.json", json.dumps(baseline))
        deployment._require_docker_success(
            [
                "exec",
                "--user",
                "postgres",
                source_name,
                "sh",
                "-eu",
                "-c",
                'umask 077; export PGPASSWORD="$POSTGRES_PASSWORD"; '
                "exec pg_dump --host=127.0.0.1 --username=correlia --dbname=correlia "
                "--format=custom --file=/tmp/source.dump",
            ]
        )
        archive = work / "source.dump"
        deployment._require_docker_success(
            ["cp", f"{source_name}:/tmp/source.dump", str(archive)]
        )
        archive.chmod(0o600)
        deployment._require_docker_success(
            ["exec", source_name, "pg_restore", "--list", "/tmp/source.dump"]
        )

        assert target_volume not in volume_names()
        named_volumes.append(target_volume)
        deployment._require_docker_success(
            [
                "volume",
                "create",
                "--label",
                f"com.docker.compose.project={project}",
                "--label",
                marker,
                target_volume,
            ]
        )
        assert start_pg(target_name, "postgres", target_volume) == target_volume
        wait_pg(target_name)
        assert source_volume != target_volume
        create_database = sql(
            source_name,
            "SELECT format('CREATE DATABASE %I OWNER %I TEMPLATE template0 ENCODING %L "
            "LOCALE_PROVIDER libc LC_COLLATE %L LC_CTYPE %L;', datname, "
            "pg_get_userbyid(datdba), pg_encoding_to_char(encoding), datcollate, datctype) "
            "FROM pg_database WHERE datname = current_database() AND datlocprovider = 'c';",
        )
        assert create_database
        sql(target_name, create_database, database="postgres")
        target_empty_inventory = inventory(target_name)
        for field in ("database", "roles", "memberships", "settings", "schema_grants"):
            assert target_empty_inventory[field] == source_inventory[field]
        target_database_inventory = sql(
            target_name,
            "SELECT jsonb_agg(datname ORDER BY datname) FROM pg_database;",
            database="postgres",
        )
        assert sql(target_name, _EMPTY_TARGET_SQL) == "0"
        deployment._require_docker_success(
            ["cp", str(archive), f"{target_name}:/tmp/source.dump"]
        )
        deployment._require_docker_success(
            ["exec", target_name, "chown", "postgres:postgres", "/tmp/source.dump"]
        )
        deployment._require_docker_success(
            ["exec", target_name, "chmod", "600", "/tmp/source.dump"]
        )

        # Discover real container identities, then run the guide's cardinality
        # stop gate with two actual candidates and with no candidates.
        candidates = deployment._require_docker_success(
            ["ps", "--all", "--quiet", "--filter", f"label={marker}"]
        ).stdout.splitlines()
        assert len(candidates) >= 2
        for candidate_ids in (" ".join(candidates[:2]), ""):
            gate = subprocess.run(
                ["sh", "-eu", "-c", _SOURCE_IDENTITY_GATE],
                env={**os.environ, "SOURCE_CANDIDATES": candidate_ids},
                capture_output=True,
                text=True,
                check=False,
            )
            assert gate.returncode != 0
            assert "STOP: missing or ambiguous source container" in gate.stderr
            assert gate.stdout == ""
        destination_unstarted()
        assert snapshot(source_name) == baseline

        sql(
            target_name,
            create_database.replace(
                "CREATE DATABASE correlia ", "CREATE DATABASE populated_target "
            ),
            database="postgres",
        )
        sql(
            target_name,
            "CREATE TABLE migration_sentinel (id integer PRIMARY KEY, value text NOT NULL); "
            "INSERT INTO migration_sentinel VALUES (7, 'retain this exact sentinel');",
            database="populated_target",
        )
        populated_before = sql(
            target_name,
            "SELECT row_to_json(s) FROM migration_sentinel s;",
            database="populated_target",
        )
        populated_catalog = sql(
            target_name, _EMPTY_TARGET_SQL, database="populated_target"
        )
        populated = restore("populated_target")
        assert populated.returncode != 0
        assert "STOP: destination database is populated" in populated.stderr
        assert (
            sql(
                target_name,
                "SELECT row_to_json(s) FROM migration_sentinel s;",
                database="populated_target",
            )
            == populated_before
        )
        assert (
            sql(target_name, _EMPTY_TARGET_SQL, database="populated_target")
            == populated_catalog
        )
        assert (
            sql(
                target_name,
                "SELECT to_regclass('public.incidents') IS NULL;",
                database="populated_target",
            )
            == "t"
        )
        destination_unstarted()
        assert snapshot(source_name) == baseline

        # Build a separate archive on the destination cluster: the original
        # source, its inventory, and source.dump never acquire synthetic objects.
        scratch_database = f"u3_scratch_{suffix}"
        control_database = f"u3_control_{suffix}"
        missing_owner = f"u3_missing_owner_{suffix}"
        synthetic_archive_path = "/tmp/late-owner.dump"
        for database in (scratch_database, control_database, "failed_target"):
            sql(
                target_name,
                create_database.replace(
                    "CREATE DATABASE correlia ", f"CREATE DATABASE {database} "
                ),
                database="postgres",
            )
        sql(
            target_name,
            f"CREATE ROLE {missing_owner} NOLOGIN;",
            database="postgres",
        )
        sql(
            target_name,
            "CREATE TABLE a_good (id integer NOT NULL); "
            "ALTER TABLE a_good OWNER TO correlia; "
            "CREATE TABLE z_bad (id integer NOT NULL); "
            f"ALTER TABLE z_bad OWNER TO {missing_owner};",
            database=scratch_database,
        )
        deployment._require_docker_success(
            [
                "exec",
                "--user",
                "postgres",
                target_name,
                "sh",
                "-eu",
                "-c",
                'umask 077; export PGPASSWORD="$POSTGRES_PASSWORD"; '
                "exec pg_dump --host=127.0.0.1 --username=correlia "
                '--dbname="$1" --format=custom --file="$2"',
                "sh",
                scratch_database,
                synthetic_archive_path,
            ]
        )
        synthetic_archive = work / "late-owner.dump"
        deployment._require_docker_success(
            ["cp", f"{target_name}:{synthetic_archive_path}", str(synthetic_archive)]
        )
        synthetic_archive.chmod(0o600)
        sql(
            target_name,
            f"DROP DATABASE {scratch_database}; DROP ROLE {missing_owner};",
            database="postgres",
        )
        assert snapshot(source_name) == baseline
        assert inventory(source_name) == source_inventory

        # A nontransactional control must retain a_good before the later z_bad
        # owner failure; this proves the transactional case is not failing at
        # its first object or relying on a permission-denying --role shim.
        assert sql(target_name, _EMPTY_TARGET_SQL, database=control_database) == "0"
        partial_restore = deployment._docker(
            [
                "exec",
                "--user",
                "postgres",
                target_name,
                "sh",
                "-eu",
                "-c",
                'export PGPASSWORD="$POSTGRES_PASSWORD"; '
                "exec pg_restore --host=127.0.0.1 --username=correlia "
                '--dbname="$1" --exit-on-error "$2"',
                "sh",
                control_database,
                synthetic_archive_path,
            ]
        )
        assert partial_restore.returncode != 0
        assert f'role "{missing_owner}" does not exist' in partial_restore.stderr
        assert (
            sql(
                target_name,
                "SELECT pg_get_userbyid(relowner) FROM pg_class "
                "WHERE oid = to_regclass('public.a_good');",
                database=control_database,
            )
            == "correlia"
        )
        assert (
            sql(
                target_name,
                "SELECT to_regclass('public.z_bad') IS NOT NULL;",
                database=control_database,
            )
            == "t"
        )
        assert sql(target_name, _EMPTY_TARGET_SQL, database=control_database) != "0"
        destination_unstarted()
        assert snapshot(source_name) == baseline
        assert inventory(source_name) == source_inventory

        assert sql(target_name, _EMPTY_TARGET_SQL, database="failed_target") == "0"
        failed_restore = restore("failed_target", archive_path=synthetic_archive_path)
        assert failed_restore.returncode != 0
        assert f'role "{missing_owner}" does not exist' in failed_restore.stderr
        assert sql(target_name, _EMPTY_TARGET_SQL, database="failed_target") == "0"
        destination_unstarted()
        assert snapshot(source_name) == baseline
        assert inventory(source_name) == source_inventory

        # These databases are confined to this invocation-owned target cluster.
        # Remove the control's surviving objects as well as both failure targets.
        sql(
            target_name,
            f"DROP DATABASE {control_database}; DROP DATABASE failed_target; "
            "DROP DATABASE populated_target;",
            database="postgres",
        )
        assert inventory(target_name) == target_empty_inventory
        assert (
            sql(
                target_name,
                "SELECT jsonb_agg(datname ORDER BY datname) FROM pg_database;",
                database="postgres",
            )
            == target_database_inventory
        )
        assert snapshot(source_name) == baseline
        assert inventory(source_name) == source_inventory

        # A missing exact external volume must fail without manufacturing a
        # replacement. Docker run's volume mounts do not provide this property.
        assert missing_name not in volume_names()
        missing_container = f"{project}-u3-missing-{suffix}"
        assert missing_container not in container_names()
        missing_manifest = recovery_compose(
            missing_name, "u3-missing", missing_container
        )
        containers.append(missing_container)
        missing = external_up(missing_manifest, "u3-missing")
        assert missing.returncode != 0
        assert "external" in missing.stderr.lower()
        assert missing_name not in volume_names()
        assert missing_container not in container_names()
        assert snapshot(source_name) == baseline
        destination_unstarted()

        # Detach without --volumes, then reopen only the recorded source.
        deployment._require_docker_success(["stop", source_name])
        deployment._require_docker_success(["rm", source_name])
        containers.remove(source_name)
        assert source_volume in volume_names()
        recovery_manifest = recovery_compose(
            source_volume, "u3-recovery", recovery_name
        )
        containers.append(recovery_name)
        recovery = external_up(recovery_manifest, "u3-recovery")
        if recovery.returncode != 0:
            pytest.fail(
                "U3 exact-source recovery failed; diagnostics withheld", pytrace=False
            )
        assert mount(recovery_name) == source_volume
        # Recovery has no initialization password environment. Supply the known
        # generated source password over stdin, not an argv/printed DSN.
        recovery_script = (
            "IFS= read -r PGPASSWORD; export PGPASSWORD; "
            "exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia "
            "--set=ON_ERROR_STOP=1 --tuples-only --no-align"
        )
        deployment._wait_until(
            "U3 exact-source recovered PostgreSQL",
            lambda: (
                deployment._docker(
                    [
                        "exec",
                        "--interactive",
                        recovery_name,
                        "sh",
                        "-eu",
                        "-c",
                        recovery_script,
                    ],
                    input_data=f"{password}\nSELECT 1;\n",
                ).returncode
                == 0
            ),
            timeout=60,
        )

        def recovered_sql(command: str) -> str:
            result = deployment._docker(
                [
                    "exec",
                    "--interactive",
                    recovery_name,
                    "sh",
                    "-eu",
                    "-c",
                    recovery_script,
                ],
                input_data=f"{password}\n{command}",
            )
            if result.returncode != 0:
                pytest.fail(
                    "U3 recovered source query failed; diagnostics withheld",
                    pytrace=False,
                )
            return result.stdout.strip()

        assert json.loads(recovered_sql(_BASELINE_SQL)) == baseline
        assert json.loads(recovered_sql(_INVENTORY_SQL)) == source_inventory

        restored = restore("correlia")
        if restored.returncode != 0:
            pytest.fail(
                "U3 transactional restore failed; diagnostics withheld", pytrace=False
            )
        destination_unstarted()
        assert snapshot(target_name) == baseline
        assert inventory(target_name) == source_inventory
        assert (
            sql(
                target_name,
                "SELECT jsonb_agg(datname ORDER BY datname) FROM pg_database;",
                database="postgres",
            )
            == target_database_inventory
        )
        assert json.loads(recovered_sql(_BASELINE_SQL)) == baseline
        wrong_password = deployment._docker(
            [
                "exec",
                "--interactive",
                target_name,
                "sh",
                "-eu",
                "-c",
                "IFS= read -r PGPASSWORD; export PGPASSWORD; "
                "exec psql --no-psqlrc --host=127.0.0.1 --username=correlia --dbname=correlia "
                '--no-password --set=ON_ERROR_STOP=1 --command="SELECT current_user"',
            ],
            input_data=f"u3-invalid-{uuid4().hex}\n",
        )
        assert wrong_password.returncode != 0
        assert "password authentication failed" in wrong_password.stderr
        assert sql(target_name, "SELECT current_user;") == "correlia"

        # App startup is the mutation boundary; no ingress is resumed yet.
        start_app(target_app, target_name, destination=True)
        expiry = deployment._wait_until(
            "U3 immediate first-sweep expiry after destination startup",
            lambda: (
                value
                if (
                    value := sql(
                        target_name,
                        "SELECT status, closed_at IS NOT NULL, "
                        "decision_context->'notes'->>'lifecycle.reason' FROM incidents "
                        f"WHERE id = '{overdue_id}'::uuid;",
                    )
                )
                == "CLOSED|t|expired"
                else None
            ),
            timeout=20,
        )
        assert expiry == "CLOSED|t|expired"
        after_start = snapshot(target_name)
        assert after_start["revision"] == baseline["revision"]
        assert after_start["audit"] == baseline["audit"]
        source_primary = next(
            item for item in baseline["incidents"] if item["id"] == primary_id
        )
        target_primary = next(
            item for item in after_start["incidents"] if item["id"] == primary_id
        )
        assert target_primary == source_primary
        assert incident_api(target_app, primary_id) == primary_api
        assert audit_api(target_app) == source_audit_api
        for path in (
            "/v1/readyz",
            f"/v1/incidents/{primary_id}",
            "/v1/incident-events",
        ):
            for token in (None, "u3-invalid-operator", ingress_token):
                status, body = http(target_app, path, token=token)
                assert status == 401
                assert json.loads(body) == {"detail": "unauthorized"}
        assert json.loads(recovered_sql(_BASELINE_SQL)) == baseline
        assert after_start != baseline

        # Execute the documentation's Python verbatim, not a test-side rewrite
        # of its timestamp, role-boundary, or global cursor-scan comparisons.
        configuration = (deployment.PROJECT_ROOT / "CONFIGURATION.md").read_text(
            encoding="utf-8"
        )
        probe_anchor = (
            'docker exec --interactive --env "BASELINE_INCIDENT_ID=$BASELINE_INCIDENT_ID" \\\n'
            "    \"$APP_CONTAINER\" python - <<'PY'\n"
        )
        _, separator, probe_tail = configuration.partition(probe_anchor)
        if not separator:
            pytest.fail(
                "U3 documented baseline Python entrypoint missing", pytrace=False
            )
        documented_probe, separator, _ = probe_tail.partition("\nPY\n")
        if not separator:
            pytest.fail(
                "U3 documented baseline Python terminator missing", pytrace=False
            )
        deployment._require_docker_success(
            ["cp", str(baseline_file), f"{target_app}:/tmp/cutover-baseline.json"]
        )
        deployment._require_docker_success(
            [
                "exec",
                "--user",
                "root",
                target_app,
                "chown",
                "correlia:correlia",
                "/tmp/cutover-baseline.json",
            ]
        )
        deployment._require_docker_success(
            [
                "exec",
                "--user",
                "root",
                target_app,
                "chmod",
                "600",
                "/tmp/cutover-baseline.json",
            ]
        )
        burst_script = """
import os as _u3_os
import urllib.request as _u3_transport
from time import monotonic as _u3_monotonic
from urllib.error import HTTPError as _u3_HTTPError

_u3_urlopen = _u3_transport.urlopen
_u3_burst_request = _u3_transport.Request(
    "http://127.0.0.1:8000/v1/incidents/" + _u3_os.environ["BASELINE_INCIDENT_ID"],
    headers={"Authorization": "Bearer " + _u3_os.environ["CORRELIA_OPERATOR_API_TOKEN"]},
)
_u3_burst_deadline = _u3_monotonic() + 20
_u3_burst_429 = 0
while _u3_monotonic() < _u3_burst_deadline:
    try:
        with _u3_urlopen(_u3_burst_request, timeout=5) as _u3_response:
            assert _u3_response.status == 200
    except _u3_HTTPError as _u3_error:
        if _u3_error.code != 429:
            raise
        _u3_burst_429 += 1
        _u3_error.close()
        break
assert _u3_burst_429 >= 1, "The unchanged operator quota must produce a real HTTP 429"

# Observe only real transport errors from the unchanged documented snippet.
# Every request still calls urllib's original HTTP transport with the same args.
_u3_documented_429 = 0
def _u3_observe_urlopen(*args, **kwargs):
    global _u3_documented_429
    try:
        return _u3_urlopen(*args, **kwargs)
    except _u3_HTTPError as _u3_error:
        if _u3_error.code == 429:
            _u3_documented_429 += 1
        raise
_u3_transport.urlopen = _u3_observe_urlopen
"""
        probe_result = deployment._docker(
            [
                "exec",
                "--interactive",
                "--env",
                f"BASELINE_INCIDENT_ID={primary_id}",
                target_app,
                "python",
                "-",
            ],
            input_data=burst_script
            + "\n"
            + documented_probe
            + """
assert _u3_documented_429 >= 1, "The documented operator probe must itself retry a real 429"
print(json.dumps({
    "real_documented_baseline_probe_verified": True,
    "documented_probe_rate_limit_recovery_verified": True,
    "private_operator_burst_429_count": _u3_burst_429,
    "documented_probe_429_retry_count": _u3_documented_429,
}))
""",
            timeout=180,
        )
        if probe_result.returncode != 0:
            pytest.fail(
                "U3 exact documented baseline HTTP probe failed; diagnostics withheld",
                pytrace=False,
            )
        probe_evidence = json.loads(probe_result.stdout.splitlines()[-1])
        assert probe_evidence["private_operator_burst_429_count"] >= 1
        assert probe_evidence["documented_probe_429_retry_count"] >= 1
        assert probe_evidence["real_documented_baseline_probe_verified"] is True
        assert probe_evidence["documented_probe_rate_limit_recovery_verified"] is True
        assert snapshot(target_name) == after_start
        assert json.loads(recovered_sql(_BASELINE_SQL)) == baseline
        assert json.loads(recovered_sql(_INVENTORY_SQL)) == source_inventory

        new_id, new_source_id = ingest(target_app, f"u3-new-write-{suffix}", 3)
        assert new_id not in {primary_id, overdue_id}
        assert incident_api(target_app, new_id)["status"] == "OPEN"
        after_write = snapshot(target_name)
        assert len(after_write["incidents"]) == len(baseline["incidents"]) + 1
        new_audit = [
            item for item in after_write["audit"] if item["source_id"] == new_source_id
        ]
        assert len(new_audit) == 1
        assert new_audit[0]["incident_ids"] == [new_id]
        assert new_audit[0]["id"] not in {item["id"] for item in baseline["audit"]}
        assert {
            item["id"]: item
            for item in after_write["audit"]
            if item["source_id"] != new_source_id
        } == {item["id"]: item for item in baseline["audit"]}
        assert incident_api(target_app, primary_id) == primary_api
        assert json.loads(recovered_sql(_BASELINE_SQL)) == baseline
        assert source_volume in volume_names()
        assert archive.is_file()
        report = {
            "schema_version": 1,
            "source_container_id": source_container_id,
            "pg_dump_version": tool_version,
            "data_destination": "/var/lib/postgresql/data",
            "source_volume": source_volume,
            "target_volume": target_volume,
            "source_target_separate": True,
            "primary_incident_id": primary_id,
            "primary_event_count": 2,
            "acknowledged_by": "migration-operator",
            "baseline_audit_ids": sorted(source_audit_api),
            "restored_revision": image_head,
            "owner_encoding_locale_roles_grants_verified": True,
            "tcp_credentials_verified": True,
            "operator_auth_and_role_denials_verified": True,
            "real_documented_baseline_probe_verified": probe_evidence[
                "real_documented_baseline_probe_verified"
            ],
            "documented_probe_rate_limit_recovery_verified": probe_evidence[
                "documented_probe_rate_limit_recovery_verified"
            ],
            "private_operator_burst_429_count": probe_evidence[
                "private_operator_burst_429_count"
            ],
            "documented_probe_429_retry_count": probe_evidence[
                "documented_probe_429_retry_count"
            ],
            "populated_target_unchanged": True,
            "late_missing_owner_nontransactional_partial_restore_verified": True,
            "failed_restore_transaction_rolled_back": True,
            "synthetic_scratch_role_and_databases_removed": True,
            "failure_destinations_unstarted": True,
            "exact_detached_source_baseline_verified": True,
            "missing_external_source_created_no_volume": True,
            "missing_ambiguous_identity_stopped": True,
            "overdue_incident_id": overdue_id,
            "immediate_expiry": "CLOSED|closed_at-set|expired",
            "expiry_audit_unchanged": True,
            "source_unchanged_after_destination_startup_and_write": True,
            "new_committed_incident_id": new_id,
            "new_committed_audit_id": new_audit[0]["id"],
            "source_and_archive_retained_through_acceptance": True,
        }
    finally:
        # Only these invocation-owned synthetic resources, never a prune or a
        # canonical down. The anonymous source is removed by its recorded name.
        if not cleanup_verification.has_ownership(project, invocation, receipt):
            pytest.fail(
                "U3 cleanup lost invocation ownership; refusing deletion", pytrace=False
            )
        existing_containers = container_names()
        cleanup_failed = False
        for name in reversed(containers):
            if name in existing_containers:
                if source_volume is None and name == source_name:
                    source_volume = mount(name)
                removed = deployment._docker(["rm", "--force", name])
                cleanup_failed |= removed.returncode != 0
        existing_volumes = volume_names()
        for name in [
            *named_volumes,
            *([source_volume] if source_volume is not None else []),
        ]:
            if name in existing_volumes:
                removed = deployment._docker(["volume", "rm", name])
                cleanup_failed |= removed.returncode != 0
        remaining_containers = deployment._require_docker_success(
            ["ps", "--all", "--quiet", "--filter", f"label={marker}"]
        ).stdout.strip()
        remaining_volumes = volume_names()
        cleanup_failed |= bool(remaining_containers)
        cleanup_failed |= any(name in remaining_volumes for name in named_volumes)
        cleanup_failed |= (
            source_volume is not None and source_volume in remaining_volumes
        )
        shutil.rmtree(work)
        if cleanup_failed:
            pytest.fail(
                "U3 recorded-resource cleanup failed; diagnostics withheld",
                pytrace=False,
            )
    report["scoped_auxiliary_cleanup_verified"] = True
    report["protected_archive_and_secret_files_removed"] = not work.exists()
    assert (
        deployment._require_docker_success(
            deployment._docker_compose_arguments(stack, "ps", "--quiet", "postgres")
        ).stdout.strip()
        == canonical_pg
    )
    assert (
        deployment._require_docker_success(
            deployment._docker_compose_arguments(stack, "ps", "--quiet", "correlia")
        ).stdout.strip()
        == canonical_app
    )
    assert (
        deployment._container_http_response(
            canonical_app, "http://127.0.0.1:8000/v1/readyz", token=operator_token
        )[0]
        == 200
    )
    deployment._publish_qualification_report("PG16 legacy migration rehearsal", report)
