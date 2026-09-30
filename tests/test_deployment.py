"""Always-run deployment artifact and controlled entrypoint contract tests."""

from __future__ import annotations

from collections.abc import Iterator
from fnmatch import fnmatchcase
from http.server import BaseHTTPRequestHandler, HTTPServer
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
from threading import Thread
import time
from uuid import UUID, uuid4

import pytest
import yaml

from app.config.plugins import load_plugin_registry_config
from app.config.rules import load_rules_config
from app.config.settings import Settings
from app.config.topology import load_topology_config
from app.persistence.audit import canonical_json_bytes
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload
from scripts.qualify_audit_bounds import (
    BODY_CEILING,
    exact_tag_bytes,
    make_corpus,
)
from app.plugins.loader import load_plugin_registry
from scripts import cleanup_verification

PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENTRYPOINT_PATH = PROJECT_ROOT / "scripts" / "container-entrypoint.sh"
DOCKERFILE_PATH = PROJECT_ROOT / "Dockerfile"
DOCKERIGNORE_PATH = PROJECT_ROOT / ".dockerignore"

COMPOSE_PATH = PROJECT_ROOT / "compose.yaml"
ENV_EXAMPLE_PATH = PROJECT_ROOT / ".env.example"
CONFIG_DIRECTORY = PROJECT_ROOT / "config"

_DOCKER_UNAVAILABLE_CAPABILITIES = (
    "image user/filesystem/process/signal, network/SMTP, and runtime-secret placement"
)

# Qualification-only quotas: the 60s windows include Compose healthchecks,
# the existing smoke, idle health probes, and the finite loaded workload.
_QUALIFICATION_HEALTH_QUOTA = 1_000
_QUALIFICATION_INGRESS_QUOTA = 500
_QUALIFICATION_OPERATOR_QUOTA = 500
_QUALIFICATION_WINDOW_SECONDS = 60
_QUALIFICATION_DURATION_SECONDS = 11
_QUALIFICATION_OFFERED_RATE_PER_SECOND = 10
_QUALIFICATION_MAX_IN_FLIGHT = 2


def _assert_secret_absent(value: str, surface: str, secret: str) -> None:
    if secret in value:
        pytest.fail(f"secret sentinel appeared in {surface}")


def _docker_engine_available() -> bool:
    docker = shutil.which("docker")
    if docker is None:
        return False
    try:
        result = subprocess.run(
            [docker, "info"],
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )
    except OSError, subprocess.TimeoutExpired:
        return False
    return result.returncode == 0


def _docker(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    input_data: str | None = None,
    timeout: float = 120,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["docker", *arguments],
        cwd=PROJECT_ROOT,
        env=environment,
        input=input_data,
        capture_output=True,
        text=True,
        check=False,
        timeout=timeout,
    )


def _require_docker_success(
    arguments: list[str],
    *,
    environment: dict[str, str] | None = None,
    timeout: float = 120,
) -> subprocess.CompletedProcess[str]:
    result = _docker(arguments, environment=environment, timeout=timeout)
    if result.returncode != 0:
        pytest.fail("Docker deployment command failed without exposing its diagnostics")
    return result


def _docker_json(arguments: list[str]) -> object:
    result = _require_docker_success(arguments)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        pytest.fail("Docker inspection did not return JSON")


def _container_startup_policy_state(
    container: str,
) -> tuple[dict[str, str], bool, int, str]:
    """Inspect only nonsecret policy inputs and the named container's state."""
    policy_names = (
        "CORRELIA_ENVIRONMENT",
        "CORRELIA_API_AUTH_ENABLED",
        "CORRELIA_EXPOSE_READYZ",
        "CORRELIA_EXPOSE_METRICS",
    )
    selection = " ".join(f'(eq (index $parts 0) "{name}")' for name in policy_names)
    template = (
        '{"running":{{json .State.Running}},'
        '"exit_code":{{json .State.ExitCode}},'
        '"status":{{json .State.Status}},'
        '"environment":[{{range .Config.Env}}{{$parts := split . "="}}'
        "{{if or " + selection + "}}{{json .}},{{end}}{{end}}null]}"
    )
    inspection = _docker_json(["inspect", "--format", template, container])
    if not isinstance(inspection, dict):
        pytest.fail("policy inspection did not return the named container state")
    environment = inspection.get("environment")
    running = inspection.get("running")
    exit_code = inspection.get("exit_code")
    status = inspection.get("status")
    if (
        not isinstance(environment, list)
        or not isinstance(running, bool)
        or not isinstance(exit_code, int)
        or not isinstance(status, str)
    ):
        pytest.fail("policy inspection returned invalid nonsecret fields")
    policy = {
        entry.partition("=")[0]: entry.partition("=")[2]
        for entry in environment
        if isinstance(entry, str)
    }
    return policy, running, exit_code, status


def _wait_until(
    description: str,
    predicate: object,
    *,
    timeout: float = 30,
) -> object:
    deadline = time.monotonic() + timeout
    last_value: object = None
    while time.monotonic() < deadline:
        last_value = predicate()  # type: ignore[operator]
        if last_value:
            return last_value
        time.sleep(0.1)
    pytest.fail(f"timed out waiting for {description}")


def _container_http_response(
    container: str,
    url: str,
    *,
    token: str | None = None,
    payload: dict[str, object] | None = None,
    method: str = "GET",
    follow_redirects: bool = True,
) -> tuple[int, bytes]:
    script = """
import base64
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, file_pointer, code, message, headers, new_url):
        return None

url, method, token, payload, follow_redirects = json.loads(sys.stdin.read())
opener = build_opener() if follow_redirects else build_opener(NoRedirects())
data = json.dumps(payload).encode() if payload is not None else None
headers = {"Content-Type": "application/json"} if data is not None else {}
if token:
    headers["Authorization"] = f"Bearer {token}"
request = Request(url, data=data, headers=headers, method=method)
try:
    with opener.open(request, timeout=2) as response:
        status, body = response.status, response.read()
except HTTPError as error:
    status, body = error.code, error.read()
except URLError:
    status, body = 0, b""
print(json.dumps((status, base64.b64encode(body).decode())))
"""
    result = _docker(
        [
            "exec",
            "--interactive",
            container,
            "python",
            "-c",
            script,
        ],
        input_data=json.dumps((url, method, token, payload, follow_redirects)),
    )
    if result.returncode != 0:
        pytest.fail("container-local HTTP probe failed without exposing diagnostics")
    try:
        status, encoded_body = json.loads(result.stdout)
        return int(status), base64.b64decode(encoded_body)
    except TypeError, ValueError:
        pytest.fail("container-local HTTP probe returned an invalid response")


def _qualify_live_http(
    container: str,
    app_url: str,
    ingress_token: str,
    operator_token: str,
) -> dict[str, object]:
    """One container-local client schedules independent health and ingress I/O.

    The measuring health thread is not part of Uvicorn's event loop; the
    container is used only for network access because the app has no host port.
    No token or source payload goes on the docker command line or in reports.
    """
    corpus = {case.name: case for case in make_corpus()}
    families = ("exact_tag_bytes_16384", "four_byte_unicode", "message_4096")
    requests: list[dict[str, object]] = []
    for index in range(
        _QUALIFICATION_DURATION_SECONDS * _QUALIFICATION_OFFERED_RATE_PER_SECOND
    ):
        family = "near_1mib_body" if index == 0 else families[index % len(families)]
        payload = dict(corpus[family].payload)
        payload.update(
            source_id=f"u4-qual-{index:04}",
            host="q",  # no hostname enrichment; keeps exact-tag maps permitted
            service="probe",
            state="WARNING",  # audit transaction, no unrelated SMTP fan-out
            timestamp=datetime.now(timezone.utc).isoformat(),
        )
        assert len(canonical_json_bytes(payload)) <= BODY_CEILING
        Icinga2WebhookPayload.model_validate(payload)
        requests.append(payload)
    boundary = dict(corpus["exact_tag_bytes_16384"].payload)
    boundary.update(
        source_id="u4-qual-boundary",
        host="u4-app-boundary",
        state="DOWN",
        service=None,
        timestamp=datetime.now(timezone.utc).isoformat(),
        check_output="x" * 4096,
        tags=exact_tag_bytes(topology_collision=True),
    )
    assert len(canonical_json_bytes(boundary["tags"])) == 16_384
    Icinga2WebhookPayload.model_validate(boundary)
    rejected = dict(boundary)
    rejected.update(
        source_id="u4-qual-over-limit",
        tags={**boundary["tags"], "credential_payload": "secret-sentinel-value"},
    )
    script = """
import json
import statistics
import sys
import threading
import time
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

settings = json.load(sys.stdin)
base = settings["url"]
headers = {"Authorization": "Bearer " + settings["ingress_token"],
           "Content-Type": "application/json", "Connection": "close"}
operator_headers = {"Authorization": "Bearer " + settings["operator_token"],
                    "Connection": "close"}
cadence = 0.05
health_workers = 8

def request(url, *, data=None, headers=None):
    req = Request(url, data=data, headers=headers or {"Connection": "close"},
                  method="POST" if data is not None else "GET")
    started = time.monotonic()
    try:
        with urlopen(req, timeout=3) as response:
            status, body = response.status, response.read()
    except HTTPError as error:
        status, body = error.code, error.read()
    except (OSError, URLError):
        status, body = 0, b""
    return started, time.monotonic(), status, body

def health_probe(due):
    began, ended, status, _ = request(base + "/v1/health")
    return due, began, ended, status

def health_samples(duration):
    start = time.monotonic()
    index = 0
    with ThreadPoolExecutor(max_workers=health_workers) as pool:
        futures = []
        while start + index * cadence < start + duration:
            due = start + index * cadence
            remaining = due - time.monotonic()
            if remaining > 0:
                time.sleep(remaining)
            futures.append(pool.submit(health_probe, due))
            index += 1
        return [future.result() for future in futures]

def percentile95(values):
    ordered = sorted(values)
    at = 0.95 * (len(ordered) - 1)
    left = int(at)
    return ordered[left] + (ordered[min(left + 1, len(ordered) - 1)] -
                            ordered[left]) * (at - left)

def describe(samples):
    milliseconds = [(ended - due) * 1000 for due, _, ended, _ in samples]
    dispatch_delays = [(began - due) * 1000 for due, began, _, _ in samples]
    request_times = [(ended - began) * 1000 for _, began, ended, _ in samples]
    statuses = {}
    for _, _, _, code in samples:
        statuses[str(code)] = statuses.get(str(code), 0) + 1
    return {"probes": len(samples), "status_counts": statuses,
            "median_ms": statistics.median(milliseconds),
            "p95_ms": percentile95(milliseconds),
            "max_ms": max(milliseconds),
            "dispatch_delay_p95_ms": percentile95(dispatch_delays),
            "actual_request_p95_ms": percentile95(request_times)}

def post_prepared(body):
    began, ended, status, response = request(
        base + "/v1/icinga2/events", data=body, headers=headers)
    try:
        accepted = (status == 200 and json.loads(response).get("state_accepted") is True)
    except (ValueError, AttributeError):
        accepted = False
    return began, ended, status, accepted

# All request bodies, including the near-1MiB one, are serialized before
# the idle baseline and loaded measurement windows.
prepared = [json.dumps(p, ensure_ascii=False, separators=(",", ":")).encode()
            for p in settings["requests"]]
idle = health_samples(2)
loaded_samples = []
def monitor():
    loaded_samples.extend(health_samples(settings["duration_seconds"]))
monitor_thread = threading.Thread(target=monitor, name="independent-health-client")
monitor_thread.start()
sent = []
with ThreadPoolExecutor(max_workers=settings["max_in_flight"]) as pool:
    futures = set()
    start = time.monotonic()
    offered = 0
    last_offer = float("-inf")
    for raw in prepared:
        spacing = 1 / settings["offered_rate_per_second"]
        due = max(start + offered * spacing, last_offer + spacing)
        if due >= start + settings["duration_seconds"]:
            break
        if len(futures) >= settings["max_in_flight"]:
            done, futures = wait(futures, return_when=FIRST_COMPLETED)
            sent.extend(f.result() for f in done)
        remaining = due - time.monotonic()
        if remaining > 0:
            time.sleep(remaining)
        if time.monotonic() >= start + settings["duration_seconds"]:
            break
        futures.add(pool.submit(post_prepared, raw))
        last_offer = time.monotonic()
        offered += 1
    sent.extend(f.result() for f in futures)
monitor_thread.join()
first_ingress = min(row[0] for row in sent)
last_ingress = max(row[1] for row in sent)
overlap = [sample for sample in loaded_samples
           if first_ingress <= sample[1] <= last_ingress]
status_counts = {}
for _, _, code, _ in sent:
    status_counts[str(code)] = status_counts.get(str(code), 0) + 1

_, _, boundary_status, boundary_body = request(
    base + "/v1/icinga2/events",
    data=json.dumps(settings["boundary"], ensure_ascii=False, separators=(",", ":")).encode(),
    headers=headers)
try:
    boundary = json.loads(boundary_body)
except ValueError:
    boundary = {}
boundary_ok = (
    boundary_status == 200
    and boundary.get("state_accepted") is True
    and boundary.get("threshold_crossed") is True
    and boundary.get("matched_rules") == ["docker-smoke-threshold"]
    and boundary.get("final_tags") == settings["boundary"]["tags"]
    and any(item.get("match_source") == "hostname"
            for item in boundary.get("enrichment_diagnostics", []))
)
rejection_started, rejection_ended, rejection_status, rejected_body = request(
    base + "/v1/icinga2/events",
    data=json.dumps(settings["rejected"], ensure_ascii=False, separators=(",", ":")).encode(),
    headers=headers)
try:
    rejection = json.loads(rejected_body)
except ValueError:
    rejection = {}
rejection_safe = (
    rejection_status == 422
    and rejection.get("detail") == [
        {"loc": ["body", "tags"], "msg": "invalid event tags",
         "type": "value_error.event_tags"}]
    and "secret-sentinel-value" not in json.dumps(rejection)
    and "credential_payload" not in json.dumps(rejection)
)
_, _, audit_status, audit_body = request(
    base + "/v1/incident-events?source_id=u4-qual-boundary",
    headers=operator_headers)
try:
    audit = json.loads(audit_body)
except ValueError:
    audit = {}
items = audit.get("items", [])
audit_ok = (
    audit_status == 200 and audit.get("total") == 1 and len(items) == 1
    and items[0].get("redaction_version") == 2
    and items[0].get("normalized_event_tags_omitted") is True
    and "size_limit" in items[0].get("normalized_event_tags_omission_reasons", [])
    and len(items[0].get("normalized_event_message", "")) == 512
    and items[0].get("raw_payload_truncated") is False
    and isinstance(items[0].get("raw_payload_hmac"), str)
    and len(items[0]["raw_payload_hmac"]) == 64
    and items[0].get("raw_payload_original_byte_length", 0) >=
        items[0].get("raw_payload_stored_byte_length", 0) > 0
    and "raw_payload" not in items[0]
    and "normalized_event" not in items[0]
)
report = {
    "schema_version": 1, "qualification": "real_compose_one_worker_http",
    "effective_quotas": settings["quotas"],
    "duration_seconds": settings["duration_seconds"],
    "observed_ingress_workload_seconds": last_ingress - first_ingress,
    "health_probe_interval_ms": 50, "offered_rate_cap_per_second":
    settings["offered_rate_per_second"],
    "max_in_flight_ingress": settings["max_in_flight"],
    "idle_health": describe(idle), "loaded_health": describe(loaded_samples),
    "health_overlapping_workload": len(overlap),
    "ingress_offered": offered, "ingress_response_statuses": status_counts,
    "successful_ingress_responses": sum(row[2] == 200 and row[3] for row in sent),
    "topology_boundary_status": boundary_status, "topology_boundary_contract": boundary_ok,
    "over_limit_status": rejection_status, "over_limit_safe_422": rejection_safe,
    "over_limit_latency_ms": (rejection_ended - rejection_started) * 1000,
    "operator_audit_status": audit_status, "operator_audit_projection_contract": audit_ok,
}
print(json.dumps(report, sort_keys=True))
"""
    input_data = {
        "url": app_url,
        "ingress_token": ingress_token,
        "operator_token": operator_token,
        "requests": requests,
        "boundary": boundary,
        "rejected": rejected,
        "duration_seconds": _QUALIFICATION_DURATION_SECONDS,
        "offered_rate_per_second": _QUALIFICATION_OFFERED_RATE_PER_SECOND,
        "max_in_flight": _QUALIFICATION_MAX_IN_FLIGHT,
        "quotas": {
            "rate_limiting_enabled": True,
            "health": {
                "requests": _QUALIFICATION_HEALTH_QUOTA,
                "window_seconds": _QUALIFICATION_WINDOW_SECONDS,
            },
            "ingress": {
                "requests": _QUALIFICATION_INGRESS_QUOTA,
                "window_seconds": _QUALIFICATION_WINDOW_SECONDS,
            },
        },
    }
    result = _docker(
        ["exec", "--interactive", container, "python", "-c", script],
        input_data=json.dumps(input_data, ensure_ascii=False),
        timeout=180,
    )
    if result.returncode != 0:
        pytest.fail("container-local qualification failed without exposing diagnostics")
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError:
        pytest.fail("container-local qualification did not return JSON")
    assert isinstance(report, dict)
    report["workload_families"] = [
        "near_1mib_body",
        "exact_tag_bytes_16384",
        "four_byte_unicode",
        "message_4096",
        "exact_tag_bytes_16384_with_topology_collision",
        "over_limit_129_tags",
    ]
    report["largest_offered_canonical_body_bytes"] = max(
        len(canonical_json_bytes(payload)) for payload in requests
    )
    report["ingress_body_ceiling_bytes"] = BODY_CEILING
    report["raw_cap_bytes"] = 65_536
    return report


def _publish_qualification_report(title: str, report: dict[str, object]) -> None:
    document = json.dumps(report, sort_keys=True, ensure_ascii=False)
    print(f"{title}: {document}", flush=True)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write(f"\n### {title}\n\n```json\n{document}\n```\n")


def _mailpit_messages(container: str, url: str) -> list[dict[str, object]] | None:
    status, body = _container_http_response(container, url)
    if status != 200:
        return None
    try:
        response = json.loads(body)
    except json.JSONDecodeError:
        return None
    messages = response.get("messages") if isinstance(response, dict) else None
    if not isinstance(messages, list) or not all(
        isinstance(message, dict) for message in messages
    ):
        return None
    return messages


def _metric_value(
    metrics: str,
    name: str,
    labels: dict[str, str] | None = None,
    *,
    default: float | None = None,
) -> float:
    label_text = (
        ""
        if not labels
        else "{" + ",".join(f'{key}="{value}"' for key, value in labels.items()) + "}"
    )
    sample = f"{name}{label_text}"
    values = [
        line.removeprefix(sample).strip()
        for line in metrics.splitlines()
        if line.startswith(f"{sample} ")
    ]
    if not values and default is not None:
        return default
    assert len(values) == 1
    return float(values[0])


def _file_checksum(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _docker_compose_arguments(stack: dict[str, object], *arguments: str) -> list[str]:
    return [
        "compose",
        "--project-name",
        str(stack["project"]),
        "--env-file",
        str(stack["env_file"]),
        "--file",
        str(COMPOSE_PATH),
        "--file",
        str(stack["override_file"]),
        *arguments,
    ]


def _postgres_storage_identity(
    stack: dict[str, object], postgres_container: str
) -> dict[str, object]:
    """Prove the live PG16 mount is the production project's named volume."""
    project = str(stack["project"])
    expected_name = cleanup_verification.postgres_data_volume(project)
    mounts = _docker_json(
        ["inspect", "--format", "{{json .Mounts}}", postgres_container]
    )
    assert isinstance(mounts, list)
    data_mounts = [
        mount
        for mount in mounts
        if isinstance(mount, dict)
        and mount.get("Destination") == "/var/lib/postgresql/data"
    ]
    assert len(data_mounts) == 1
    mount = data_mounts[0]
    assert mount["Type"] == "volume"
    assert mount["Name"] == expected_name
    labels = _docker_json(
        ["volume", "inspect", "--format", "{{json .Labels}}", expected_name]
    )
    assert isinstance(labels, dict)
    assert labels["com.docker.compose.project"] == project
    assert labels["com.docker.compose.volume"] == "postgres-data"
    return {
        "name": expected_name,
        "destination": "/var/lib/postgresql/data",
        "project": project,
        "logical_volume": "postgres-data",
    }


def _compose_cleanup(stack: dict[str, object]) -> None:
    project = str(stack["project"])
    invocation = str(stack.get("invocation", ""))
    receipt = Path(str(stack.get("ownership_receipt", "")))
    try:
        if not cleanup_verification.has_ownership(project, invocation, receipt):
            pytest.fail("Docker cleanup refused without matching invocation ownership")
    except ValueError, RuntimeError:
        pytest.fail("Docker cleanup refused without matching invocation ownership")
    failed = False
    try:
        result = _docker(
            _docker_compose_arguments(stack, "down", "--volumes", "--remove-orphans")
        )
        failed = result.returncode != 0
    except OSError, subprocess.TimeoutExpired:
        failed = True
    try:
        if not cleanup_verification.cleanup_owned(project, invocation, receipt):
            failed = True
    except ValueError, RuntimeError:
        failed = True
    if failed:
        pytest.fail("Docker cleanup failed without exposing its diagnostics")


def test_health_sampling_counts_deadline_delay_during_repeated_response_stalls(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    health_requests = 0
    stalls = 0

    class StalledHealthServer(HTTPServer):
        request_queue_size = 128

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:
            nonlocal health_requests, stalls
            if self.path == "/v1/health":
                health_requests += 1
                if health_requests % 32 == 0:
                    stalls += 1
                    time.sleep(0.8)
            self.respond({"items": []})

        def do_POST(self) -> None:
            self.rfile.read(int(self.headers["Content-Length"]))
            self.respond({"state_accepted": True})

        def respond(self, data: dict[str, object]) -> None:
            body = json.dumps(data).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:
            pass

    def run_client_locally(
        arguments: list[str], *, input_data: str | None = None, timeout: float = 120
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, "-c", arguments[-1]],
            input=input_data,
            capture_output=True,
            text=True,
            check=False,
            timeout=min(timeout, 30),
        )

    monkeypatch.setitem(_qualify_live_http.__globals__, "_docker", run_client_locally)
    monkeypatch.setitem(
        _qualify_live_http.__globals__, "_QUALIFICATION_DURATION_SECONDS", 4
    )
    server = StalledHealthServer(("127.0.0.1", 0), Handler)
    server_thread = Thread(target=server.serve_forever)
    server_thread.start()
    try:
        report = _qualify_live_http(
            "local-client",
            f"http://127.0.0.1:{server.server_port}",
            "ingress-token",
            "operator-token",
        )
    finally:
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=5)

    assert not server_thread.is_alive()
    loaded = report["loaded_health"]
    assert isinstance(loaded, dict)
    assert loaded["probes"] >= 75
    assert loaded["status_counts"] == {"200": loaded["probes"]}
    assert stalls >= 3
    assert loaded["p95_ms"] > 250, loaded


def test_container_http_probe_sends_authentication_only_over_stdin(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    token = "probe-token-sentinel"
    calls: list[tuple[list[str], str | None]] = []

    def fake_docker(
        arguments: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        input_data = kwargs.get("input_data")
        assert input_data is None or isinstance(input_data, str)
        calls.append((arguments, input_data))
        return subprocess.CompletedProcess(
            ["docker", *arguments],
            0,
            stdout=json.dumps((200, base64.b64encode(b"{}").decode())),
        )

    monkeypatch.setitem(_container_http_response.__globals__, "_docker", fake_docker)

    assert _container_http_response(
        "container-id", "http://app/v1/metrics", token=token
    ) == (200, b"{}")
    assert len(calls) == 1
    arguments, input_data = calls[0]
    assert token not in json.dumps(arguments)
    assert input_data is not None and token in input_data


def test_mailpit_messages_treats_non_success_and_malformed_json_as_retryable(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    responses = iter(
        (
            (503, b"unavailable"),
            (200, b"not-json"),
            (200, json.dumps({"messages": [{"ID": "message-id"}]}).encode()),
        )
    )

    def fake_probe(*_args: object, **_kwargs: object) -> tuple[int, bytes]:
        return next(responses)

    monkeypatch.setitem(
        _mailpit_messages.__globals__, "_container_http_response", fake_probe
    )

    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") is None
    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") is None
    assert _mailpit_messages("mailpit", "http://mailpit/api/v1/messages") == [
        {"ID": "message-id"}
    ]


def test_compose_cleanup_attempts_all_resource_removal_after_down_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    project = "correlia-verify-cleanup-test"
    owned = {
        "container": {"orphan-one", "orphan-two"},
        "volume": {"orphan-volume"},
        "network": {"orphan-network"},
    }
    resources = {
        "container": {"developer-container"},
        "volume": {"developer-volume"},
        "network": {"developer-network"},
    }

    def fake_docker(
        arguments: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        if arguments[0] == "compose":
            return subprocess.CompletedProcess(["docker", *arguments], 1)
        assert (
            arguments == ["volume", "ls", "--quiet"]
            or arguments[-1] == f"label=com.docker.compose.project={project}"
            or arguments[-1] in set().union(*owned.values())
        )
        listing = {
            ("ps", "--all"): "container",
            ("volume", "ls"): "volume",
            ("network", "ls"): "network",
        }
        kind = listing.get(tuple(arguments[:2]))
        if kind:
            names = (
                resources[kind] & owned[kind]
                if "--filter" in arguments
                else resources[kind]
            )
            return subprocess.CompletedProcess(
                ["docker", *arguments],
                0,
                stdout="\n".join(sorted(names)),
            )
        removal = {
            ("rm", "--force"): "container",
            ("volume", "rm"): "volume",
            ("network", "rm"): "network",
        }
        kind = removal[tuple(arguments[:2])]
        resources[kind].remove(arguments[-1])
        return subprocess.CompletedProcess(["docker", *arguments], 0)

    monkeypatch.setitem(_compose_cleanup.__globals__, "_docker", fake_docker)
    monkeypatch.setattr(cleanup_verification, "_docker", fake_docker)
    invocation = uuid4().hex
    receipt = tmp_path / "ownership.json"
    cleanup_verification.acquire(project, invocation, receipt)
    for kind in resources:
        resources[kind].update(owned[kind])
    stack = {
        "project": project,
        "invocation": invocation,
        "ownership_receipt": receipt,
        "env_file": tmp_path / ".env",
        "override_file": tmp_path / "override.yaml",
    }

    with pytest.raises(pytest.fail.Exception, match="Docker cleanup failed"):
        _compose_cleanup(stack)
    assert resources == {
        "container": {"developer-container"},
        "volume": {"developer-volume"},
        "network": {"developer-network"},
    }
    cleanup_verification.cleanup(project)


@pytest.mark.parametrize("receipt_state", ["missing", "project", "invocation"])
def test_compose_cleanup_refuses_unowned_down(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, receipt_state: str
) -> None:
    def unexpected_docker(
        _arguments: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        pytest.fail("unowned cleanup must not reach Docker Compose or Docker")

    monkeypatch.setitem(_compose_cleanup.__globals__, "_docker", unexpected_docker)
    monkeypatch.setattr(cleanup_verification, "_docker", unexpected_docker)
    project = "correlia-verify-compose-gate"
    invocation = uuid4().hex
    receipt = tmp_path / "ownership.json"
    if receipt_state != "missing":
        receipt.write_text(
            json.dumps(
                {
                    "project": (
                        project
                        if receipt_state != "project"
                        else "correlia-verify-other"
                    ),
                    "invocation": (
                        invocation if receipt_state != "invocation" else uuid4().hex
                    ),
                }
            ),
            encoding="utf-8",
        )
    stack: dict[str, object] = {
        "project": project,
        "invocation": invocation,
        "ownership_receipt": receipt,
        "env_file": tmp_path / ".env",
        "override_file": tmp_path / "override.yaml",
    }

    with pytest.raises(pytest.fail.Exception, match="without matching invocation"):
        _compose_cleanup(stack)


def test_verification_cleanup_reports_residuals_but_attempts_other_resources(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    owned = {
        "container": {"stuck-container"},
        "volume": {"removable-volume"},
        "network": {"removable-network"},
    }

    def fake_docker(arguments: list[str]) -> subprocess.CompletedProcess[str]:
        kind = {
            ("ps", "--all"): "container",
            ("volume", "ls"): "volume",
            ("network", "ls"): "network",
        }.get(tuple(arguments[:2]))
        if kind:
            return subprocess.CompletedProcess(
                ["docker", *arguments], 0, stdout="\n".join(sorted(owned[kind]))
            )
        kind = {
            ("rm", "--force"): "container",
            ("volume", "rm"): "volume",
            ("network", "rm"): "network",
        }[tuple(arguments[:2])]
        if kind == "container":
            return subprocess.CompletedProcess(["docker", *arguments], 1)
        owned[kind].remove(arguments[-1])
        return subprocess.CompletedProcess(["docker", *arguments], 0)

    monkeypatch.setattr(cleanup_verification, "_docker", fake_docker)
    with pytest.raises(RuntimeError, match="Docker verification cleanup failed"):
        cleanup_verification.cleanup("correlia-verify-residual")
    assert owned == {
        "container": {"stuck-container"},
        "volume": set(),
        "network": set(),
    }


def test_verification_cleanup_rejects_unowned_project_before_docker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def unexpected_docker(_arguments: list[str]) -> subprocess.CompletedProcess[str]:
        pytest.fail("unowned project must not reach Docker")

    monkeypatch.setattr(cleanup_verification, "_docker", unexpected_docker)
    with pytest.raises(ValueError, match="invalid verification project"):
        cleanup_verification.cleanup("developer-project")


@pytest.fixture
def docker_compose_stack(tmp_path: Path) -> Iterator[dict[str, object]]:
    """Build the checked-in image and run one isolated Compose topology."""
    if not _docker_engine_available():
        pytest.skip(
            "Docker engine unavailable; cannot prove "
            f"{_DOCKER_UNAVAILABLE_CAPABILITIES}"
        )
    try:
        compose_version = _docker(["compose", "version"], timeout=5)
    except OSError, subprocess.TimeoutExpired:
        compose_version = None
    if compose_version is None or compose_version.returncode != 0:
        pytest.skip("Docker Compose unavailable; cannot run real deployment smoke")

    project = os.environ.get(
        "CORRELIA_VERIFICATION_PROJECT", f"correlia-verify-{uuid4().hex}"
    )
    invocation = os.environ.get("CORRELIA_VERIFICATION_INVOCATION")
    receipt_path = os.environ.get("CORRELIA_VERIFICATION_RECEIPT")
    try:
        cleanup_verification.validate_project(project)
        if invocation is not None or receipt_path is not None:
            if not invocation or not receipt_path:
                pytest.fail("incomplete verification invocation ownership")
            receipt = Path(receipt_path)
            if not cleanup_verification.has_ownership(project, invocation, receipt):
                pytest.fail("missing or mismatched verification invocation ownership")
        else:
            invocation = uuid4().hex
            receipt = tmp_path / "verification-ownership.json"
            cleanup_verification.acquire(project, invocation, receipt)
    except (ValueError, RuntimeError) as error:
        # A rejected namespace has no receipt and must never reach a finalizer.
        pytest.fail(str(error))
    suffix = uuid4().hex[:12]
    secrets = {
        "postgres_password": f"u7-postgres-{suffix}",
        "operator_token": f"u7-operator-{suffix}",
        "ingress_token": f"u7-ingress-{suffix}",
        "audit_key": f"u7-audit-{suffix}",
    }
    report_path = tmp_path / "migration-report.json"
    report_path.write_text(
        json.dumps(
            {
                "ok": True,
                "errors": [],
                "generated": {
                    "rules": "/private/rules.yaml",
                    "topology": "/private/topology.yaml",
                    "plugins": "/private/plugins.yaml",
                },
                "metrics_summary": {
                    "version": 1,
                    "outcome": "success",
                    "failure_code": "none",
                    "issue_count": 0,
                    "issues_truncated": False,
                    "completed_at": "2026-07-10T12:00:00+00:00",
                },
            }
        )
    )
    smoke_rules_path = tmp_path / "smoke-rules.yaml"
    smoke_rules_path.write_text(
        yaml.safe_dump(
            {
                "rules": [
                    {
                        "name": "docker-smoke-restart-threshold",
                        "priority": -1,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "^u5-window$",
                        },
                        "window": {
                            "duration_seconds": 60,
                            "group_by": ["host"],
                            "trigger_threshold": 2,
                        },
                        "output_summary": "Window alert on {host}",
                        "actions": [{"name": "create_incident", "plugin": "email-ops"}],
                    },
                    {
                        "name": "docker-smoke-capacity-threshold",
                        "priority": 0,
                        "match": {
                            "severities": ["CRITICAL"],
                            "host_pattern": "^u5-capacity$",
                        },
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host"],
                            "trigger_threshold": 100,
                        },
                        "output_summary": "Capacity alert on {host}",
                        "actions": [{"name": "create_incident", "plugin": "email-ops"}],
                    },
                    {
                        "name": "docker-smoke-threshold",
                        "priority": 1,
                        "match": {"severities": ["CRITICAL"], "host_pattern": ".+"},
                        "window": {
                            "duration_seconds": 300,
                            "group_by": ["host"],
                            "trigger_threshold": 1,
                        },
                        "output_summary": "Critical alert on {host}",
                        "actions": [{"name": "create_incident", "plugin": "email-ops"}],
                    },
                ]
            }
        )
    )
    environment_values = {
        "POSTGRES_DB": "correlia",
        "POSTGRES_USER": "correlia",
        "POSTGRES_PASSWORD": secrets["postgres_password"],
        "DATABASE_URL": (
            "postgresql+asyncpg://correlia:"
            f"{secrets['postgres_password']}@postgres:5432/correlia"
        ),
        "CORRELIA_ENVIRONMENT": "production",
        "CORRELIA_LOG_LEVEL": "INFO",
        "CORRELIA_RULES_PATH": "/app/config/rules.yaml",
        "CORRELIA_TOPOLOGY_PATH": "/app/config/topology.yaml",
        "CORRELIA_PLUGINS_PATH": "/app/config/plugins.yaml",
        "CORRELIA_API_AUTH_ENABLED": "true",
        "CORRELIA_OPERATOR_API_TOKEN": secrets["operator_token"],
        "CORRELIA_INGRESS_API_TOKEN": secrets["ingress_token"],
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": secrets["audit_key"],
        "CORRELIA_EXPOSE_READYZ": "false",
        "CORRELIA_EXPOSE_METRICS": "false",
    }
    env_file = tmp_path / ".env"
    env_file.write_text(
        "\n".join(f"{name}={value}" for name, value in environment_values.items())
        + "\n"
    )
    override_file = tmp_path / "compose.override.yaml"
    override_file.write_text(
        "\n".join(
            (
                "services:",
                "  correlia:",
                "    ports: !reset []",
                "    environment:",
                "      CORRELIA_MIGRATION_REPORT_PATH: /app/reports/migration-report.json",
                "      CORRELIA_RULES_PATH: /app/smoke/rules.yaml",
                "      CORRELIA_RATE_LIMIT_ENABLED: 'true'",
                f"      CORRELIA_RATE_LIMIT_REQUESTS_HEALTH: {_QUALIFICATION_HEALTH_QUOTA}",
                f"      CORRELIA_RATE_LIMIT_WINDOW_SECONDS_HEALTH: {_QUALIFICATION_WINDOW_SECONDS}",
                f"      CORRELIA_RATE_LIMIT_REQUESTS_INGRESS: {_QUALIFICATION_INGRESS_QUOTA}",
                f"      CORRELIA_RATE_LIMIT_WINDOW_SECONDS_INGRESS: {_QUALIFICATION_WINDOW_SECONDS}",
                f"      CORRELIA_RATE_LIMIT_REQUESTS_OPERATOR: {_QUALIFICATION_OPERATOR_QUOTA}",
                f"      CORRELIA_RATE_LIMIT_WINDOW_SECONDS_OPERATOR: {_QUALIFICATION_WINDOW_SECONDS}",
                "    volumes:",
                f"      - {report_path}:/app/reports/migration-report.json:ro",
                f"      - {smoke_rules_path}:/app/smoke/rules.yaml:ro",
                "  mailpit:",
                "    ports: !reset []",
                "",
            )
        )
    )
    stack: dict[str, object] = {
        "project": project,
        "invocation": invocation,
        "ownership_receipt": receipt,
        "env_file": env_file,
        "override_file": override_file,
        "report_path": report_path,
        "secrets": secrets,
        "environment": {**os.environ, **environment_values},
    }

    try:
        _require_docker_success(
            _docker_compose_arguments(stack, "up", "--build", "--detach", "--wait"),
            environment=stack["environment"],  # type: ignore[arg-type]
            timeout=300,
        )
        postgres_container = _require_docker_success(
            _docker_compose_arguments(stack, "ps", "--quiet", "postgres")
        ).stdout.strip()
        if not postgres_container:
            pytest.fail("Compose smoke did not create PostgreSQL")
        storage = _postgres_storage_identity(stack, postgres_container)
        stack["postgres_storage"] = storage
        _publish_qualification_report("Production PostgreSQL storage", storage)
    except BaseException:
        _compose_cleanup(stack)
        raise
    try:
        yield stack
    finally:
        _compose_cleanup(stack)


def _load_dotenv_example(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        assert separator and key
        values[key] = value
    return values


def _secret_interpolation_paths(
    value: object,
    *,
    path: str,
    secret_names: frozenset[str],
) -> list[str]:
    if isinstance(value, dict):
        paths: list[str] = []
        for key, nested_value in value.items():
            paths.extend(
                _secret_interpolation_paths(
                    nested_value,
                    path=f"{path}.{key}",
                    secret_names=secret_names,
                )
            )
        return paths
    if isinstance(value, list):
        paths = []
        for index, nested_value in enumerate(value):
            paths.extend(
                _secret_interpolation_paths(
                    nested_value,
                    path=f"{path}[{index}]",
                    secret_names=secret_names,
                )
            )
        return paths
    if isinstance(value, str) and any(
        f"${{{secret_name}" in value for secret_name in secret_names
    ):
        return [path]
    return []


def _dockerfile_instructions(text: str) -> list[tuple[str, str]]:
    instructions: list[tuple[str, str]] = []
    logical_line = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        logical_line = f"{logical_line} {line}".strip()
        if line.endswith("\\"):
            logical_line = logical_line[:-1].rstrip()
            continue
        instruction, _, arguments = logical_line.partition(" ")
        instructions.append((instruction.upper(), arguments))
        logical_line = ""
    assert not logical_line
    return instructions


def _dockerignore_patterns(text: str) -> set[str]:
    return {
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }


def _dockerignore_excludes(path: str, patterns: set[str]) -> bool:
    path_parts = path.split("/")
    for pattern in patterns:
        if pattern.endswith("/"):
            directory_pattern = pattern[:-1]
            if any(
                fnmatchcase("/".join(path_parts[:index]), directory_pattern)
                for index in range(1, len(path_parts) + 1)
            ):
                return True
        elif fnmatchcase(path, pattern):
            return True
    return False


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content)
    path.chmod(0o755)


def _run_controlled_entrypoint(
    tmp_path: Path,
    *,
    database_url: str | None,
    alembic_exit: int = 0,
    alembic_output: str = "",
    web_concurrency: str | None = None,
) -> tuple[subprocess.CompletedProcess[str], list[str], str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    event_log = tmp_path / "events.log"
    database_capture = tmp_path / "database-url.txt"

    _write_executable(
        bin_dir / "alembic",
        """#!/bin/sh
printf '%s\\n' migration >> "$EVENT_LOG"
printf '%s' "${DATABASE_URL-}" > "$DATABASE_CAPTURE"
printf '%s\\n' "$@" >> "$EVENT_LOG"
printf '%s\\n' "$ALEMBIC_OUTPUT"
printf '%s\\n' "$ALEMBIC_OUTPUT" >&2
exit "$ALEMBIC_EXIT"
""",
    )
    _write_executable(
        bin_dir / "uvicorn",
        """#!/bin/sh
printf '%s\\n' server >> "$EVENT_LOG"
printf '%s\\n' "$@" >> "$EVENT_LOG"
""",
    )

    environment = os.environ.copy()
    environment.update(
        {
            "PATH": f"{bin_dir}{os.pathsep}{environment['PATH']}",
            "EVENT_LOG": str(event_log),
            "DATABASE_CAPTURE": str(database_capture),
            "ALEMBIC_EXIT": str(alembic_exit),
            "ALEMBIC_OUTPUT": alembic_output,
        }
    )
    if database_url is None:
        environment.pop("DATABASE_URL", None)
    else:
        environment["DATABASE_URL"] = database_url
    if web_concurrency is not None:
        environment["WEB_CONCURRENCY"] = web_concurrency

    result = subprocess.run(
        [str(ENTRYPOINT_PATH)],
        cwd=tmp_path,
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )
    events = event_log.read_text().splitlines() if event_log.exists() else []
    captured_database_url = (
        database_capture.read_text() if database_capture.exists() else ""
    )
    return result, events, captured_database_url


@pytest.mark.posix
def test_entrypoint_migrates_with_inherited_database_url_before_one_factory_server(
    tmp_path: Path,
) -> None:
    database_url = "postgresql+asyncpg://test-user:test-password@db:5432/correlia"

    result, events, captured_database_url = _run_controlled_entrypoint(
        tmp_path,
        database_url=database_url,
        web_concurrency="17",
    )

    assert result.returncode == 0
    assert (
        "exec uvicorn app.main:create_app --factory --host 0.0.0.0 "
        "--port 8000 --workers 1 --no-access-log"
    ) in ENTRYPOINT_PATH.read_text()
    assert captured_database_url == database_url
    assert events == [
        "migration",
        "upgrade",
        "head",
        "server",
        "app.main:create_app",
        "--factory",
        "--host",
        "0.0.0.0",
        "--port",
        "8000",
        "--workers",
        "1",
        "--no-access-log",
    ]
    assert database_url not in events
    assert "--reload" not in events


@pytest.mark.posix
def test_entrypoint_propagates_migration_failure_with_diagnostics_before_server(
    tmp_path: Path,
) -> None:
    database_url = "postgresql+asyncpg://test-user:credential-sentinel@db:5432/correlia"
    injected_sentinel = "migration-error-sentinel"

    result, events, _ = _run_controlled_entrypoint(
        tmp_path,
        database_url=database_url,
        alembic_exit=37,
        alembic_output=injected_sentinel,
    )

    diagnostics = f"{result.stdout}\n{result.stderr}"
    assert result.returncode == 37
    assert events == ["migration", "upgrade", "head"]
    assert "server" not in events
    assert "downgrade" not in events
    assert "Database migration failed" in diagnostics
    assert injected_sentinel in result.stdout
    assert injected_sentinel in result.stderr
    assert database_url not in diagnostics


@pytest.mark.posix
def test_entrypoint_propagates_failed_migration_diagnostics_before_server(
    tmp_path: Path,
) -> None:
    migration_diagnostic = "migration-error-sentinel"

    result, events, _ = _run_controlled_entrypoint(
        tmp_path,
        database_url="postgresql+asyncpg://test-user:test-password@db:5432/correlia",
        alembic_exit=2,
        alembic_output=migration_diagnostic,
    )

    assert result.returncode == 2
    assert events == ["migration", "upgrade", "head"]
    assert "server" not in events
    assert migration_diagnostic in result.stdout
    assert migration_diagnostic in result.stderr


@pytest.mark.posix
def test_entrypoint_rejects_missing_database_url_before_migration_or_server(
    tmp_path: Path,
) -> None:
    result, events, _ = _run_controlled_entrypoint(tmp_path, database_url=None)

    assert result.returncode != 0
    assert events == []
    assert "Database configuration is required" in result.stderr


def test_dockerfile_defines_a_locked_production_only_narrow_non_root_runtime() -> None:
    dockerfile = DOCKERFILE_PATH.read_text()
    instructions = _dockerfile_instructions(dockerfile)
    copy_arguments = [
        arguments for instruction, arguments in instructions if instruction == "COPY"
    ]

    assert ("RUN", "uv sync --locked --no-dev --no-install-project") in instructions
    assert ("COPY", "pyproject.toml uv.lock ./") in instructions
    assert ("COPY", "--chown=correlia:correlia config ./config") in instructions
    assert instructions.index(
        ("COPY", "--chown=correlia:correlia config ./config")
    ) < instructions.index(("USER", "correlia"))
    assert all(arguments != ". ." for arguments in copy_arguments)
    assert all(instruction != "ADD" for instruction, _ in instructions)
    assert ("USER", "correlia") in instructions
    assert any(
        instruction == "RUN" and "useradd" in arguments and "correlia" in arguments
        for instruction, arguments in instructions
    )
    assert ("ENTRYPOINT", '["/app/scripts/container-entrypoint.sh"]') in instructions
    assert "DATABASE_URL" not in dockerfile
    assert "WEB_CONCURRENCY" not in dockerfile


def test_dockerignore_excludes_secrets_vcs_tool_state_caches_and_local_artifacts() -> (
    None
):
    patterns = _dockerignore_patterns(DOCKERIGNORE_PATH.read_text())

    excluded_paths = (
        ".env.production",
        ".git/config",
        ".claude/settings.json",
        ".coderabbit.yaml",
        ".planning/research/.cache/cache-entry.json",
        ".planning/graphs/.last-build-snapshot.json",
        ".last-build-snapshot.json",
        ".venv/bin/python",
        "__pycache__/main.cpython-314.pyc",
        ".pytest_cache/v/cache/nodeids",
        ".mypy_cache/3.14/cache.json",
        ".ruff_cache/check.json",
        "build/wheel",
        "dist/correlia.whl",
        "correlia.egg-info/PKG-INFO",
        "developer.pem",
        "private.key",
        "certificate.p12",
        "certificate.pfx",
        "local.db",
    )

    assert all(_dockerignore_excludes(path, patterns) for path in excluded_paths)


def test_compose_topology_keeps_dependencies_private_and_uses_health_ordering() -> None:
    compose = yaml.safe_load(COMPOSE_PATH.read_text())

    assert set(compose["services"]) == {"postgres", "correlia", "mailpit"}
    assert compose["services"]["mailpit"]["image"] == "axllent/mailpit:v1.26.1"
    assert compose["services"]["correlia"]["build"] == "."
    assert compose["services"]["correlia"]["deploy"] == {"replicas": 1}
    assert compose["services"]["correlia"]["read_only"] is True
    assert compose["services"]["correlia"]["volumes"] == ["./config:/app/config:ro"]
    assert compose["services"]["correlia"]["depends_on"] == {
        "postgres": {"condition": "service_healthy"},
        "mailpit": {"condition": "service_healthy"},
    }

    for service_name in ("postgres", "mailpit"):
        healthcheck = compose["services"][service_name]["healthcheck"]
        assert healthcheck["interval"] == "5s"
        assert healthcheck["timeout"] == "3s"
        assert healthcheck["retries"] == 12

    app_healthcheck = compose["services"]["correlia"]["healthcheck"]["test"]
    app_healthcheck_command = " ".join(app_healthcheck)
    assert "/v1/readyz" in app_healthcheck_command
    assert "/v1/health" not in app_healthcheck_command
    assert "CORRELIA_OPERATOR_API_TOKEN" in app_healthcheck_command
    assert "Authorization" in app_healthcheck_command
    assert "Bearer " in app_healthcheck_command
    assert "DATABASE_URL" not in app_healthcheck_command

    assert compose["networks"] == {
        "database": {"internal": True},
        "smtp": {"internal": True},
    }
    assert compose["services"]["postgres"]["networks"] == ["database"]
    assert compose["services"]["mailpit"]["networks"] == ["smtp"]
    assert compose["services"]["correlia"]["networks"] == ["database", "smtp"]
    assert compose["services"]["postgres"].get("ports") is None
    assert compose["services"]["mailpit"]["ports"] == ["127.0.0.1:8025:8025"]
    assert compose["services"]["correlia"]["ports"] == ["127.0.0.1:8000:8000"]


def test_compose_secret_references_are_limited_to_service_runtime_environment() -> None:
    compose = yaml.safe_load(COMPOSE_PATH.read_text())
    secret_names = frozenset(
        {
            "DATABASE_URL",
            "POSTGRES_PASSWORD",
            "CORRELIA_OPERATOR_API_TOKEN",
            "CORRELIA_INGRESS_API_TOKEN",
            "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
        }
    )
    expected_runtime_paths = {
        "services.postgres.environment.POSTGRES_PASSWORD",
        "services.correlia.environment.DATABASE_URL",
        "services.correlia.environment.CORRELIA_OPERATOR_API_TOKEN",
        "services.correlia.environment.CORRELIA_INGRESS_API_TOKEN",
        "services.correlia.environment.CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
    }
    runtime_paths: set[str] = set()
    prohibited_paths: list[str] = []

    for service_name, service in compose["services"].items():
        runtime_paths.update(
            _secret_interpolation_paths(
                service.get("environment", {}),
                path=f"services.{service_name}.environment",
                secret_names=secret_names,
            )
        )
        for field in ("build", "command", "entrypoint", "labels", "healthcheck"):
            prohibited_paths.extend(
                _secret_interpolation_paths(
                    service.get(field, {}),
                    path=f"services.{service_name}.{field}",
                    secret_names=secret_names,
                )
            )

    assert runtime_paths == expected_runtime_paths
    assert prohibited_paths == []


def test_environment_and_config_samples_construct_strict_runtime_configuration(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    example = _load_dotenv_example(ENV_EXAMPLE_PATH)
    required_settings_names = {
        "DATABASE_URL",
        "CORRELIA_ENVIRONMENT",
        "CORRELIA_LOG_LEVEL",
        "CORRELIA_RULES_PATH",
        "CORRELIA_TOPOLOGY_PATH",
        "CORRELIA_PLUGINS_PATH",
        "CORRELIA_API_AUTH_ENABLED",
        "CORRELIA_OPERATOR_API_TOKEN",
        "CORRELIA_INGRESS_API_TOKEN",
        "CORRELIA_EXPOSE_READYZ",
        "CORRELIA_EXPOSE_METRICS",
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
    }
    assert required_settings_names.issubset(example)
    assert all(
        example[name].startswith("replace-with-")
        for name in (
            "POSTGRES_PASSWORD",
            "CORRELIA_OPERATOR_API_TOKEN",
            "CORRELIA_INGRESS_API_TOKEN",
            "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY",
        )
    )

    settings_values = {
        **{
            key: value
            for key, value in example.items()
            if key == "DATABASE_URL" or key.startswith("CORRELIA_")
        },
        "DATABASE_URL": "postgresql+asyncpg://test:database-secret@postgres:5432/correlia",
        "CORRELIA_OPERATOR_API_TOKEN": "operator-secret",
        "CORRELIA_INGRESS_API_TOKEN": "ingress-secret",
        "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": "audit-secret",
    }
    for name, value in settings_values.items():
        monkeypatch.setenv(name, value)

    settings = Settings()

    assert settings.environment == "local"
    assert settings.api_auth_enabled is True
    assert settings.expose_readyz is False
    assert settings.expose_metrics is True
    assert settings.operator_api_token is not None
    assert settings.ingress_api_token is not None
    assert settings.operator_api_token.get_secret_value() != (
        settings.ingress_api_token.get_secret_value()
    )

    plugin_config = load_plugin_registry_config(CONFIG_DIRECTORY / "plugins.yaml")
    registry = load_plugin_registry(CONFIG_DIRECTORY / "plugins.yaml")
    rules = load_rules_config(
        CONFIG_DIRECTORY / "rules.yaml",
        known_plugins=frozenset(registry.names),
    )
    topology = load_topology_config(CONFIG_DIRECTORY / "topology.yaml")

    assert registry.names == ("email-ops",)
    assert len(rules.rules) == 1
    rule = rules.rules[0].definition
    assert rule.window.trigger_threshold == 1
    assert rule.match.tags == {"topology.datacenter": "dc1"}
    assert set(rule.window.group_by) == {"host", "topology.datacenter"}
    hostname_rule = topology.hostname_rules[0]
    datacenter_match = hostname_rule.pattern.fullmatch("dc1-app-web")
    assert datacenter_match is not None
    assert (
        datacenter_match.group(hostname_rule.tag_capture_groups["topology.datacenter"])
        == rule.match.tags["topology.datacenter"]
    )

    entry = plugin_config.outputs[0]
    assert entry.options["host"] == "mailpit"
    assert entry.options["port"] == 1025
    assert not {"username", "password", "token", "authorization", "dsn"} & set(
        entry.options
    )


@pytest.mark.deployment
def test_real_compose_smoke_proves_runtime_deployment_contract(
    docker_compose_stack: dict[str, object],
    tmp_path: Path,
) -> None:
    """Exercise the checked-in image and topology; the fixture always removes it."""
    stack = docker_compose_stack
    project = str(stack["project"])
    secrets = stack["secrets"]
    assert isinstance(secrets, dict)
    operator_token = str(secrets["operator_token"])
    ingress_token = str(secrets["ingress_token"])
    postgres_password = str(secrets["postgres_password"])
    audit_key = str(secrets["audit_key"])
    app_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "correlia")
    ).stdout.strip()
    postgres_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "postgres")
    ).stdout.strip()
    mailpit_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "mailpit")
    ).stdout.strip()
    if not app_container or not postgres_container or not mailpit_container:
        pytest.fail("Compose smoke did not create all required services")

    app_url = "http://127.0.0.1:8000"
    mailpit_url = "http://mailpit:8025"
    status, health_body = _wait_until(
        "public application health",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/health"
                )
            )[0]
            == 200
            else None
        ),
    )
    assert status == 200
    assert json.loads(health_body) == {"status": "ok"}

    invalid_token = "production-invalid-credential"
    for token in (invalid_token, operator_token, ingress_token):
        status, public_body = _container_http_response(
            app_container, f"{app_url}/v1/health", token=token
        )
        assert status == 200
        assert json.loads(public_body) == {"status": "ok"}

    def assert_role_denials(
        path: str,
        *,
        method: str = "GET",
        payload: dict[str, object] | None = None,
        wrong_role: str = ingress_token,
    ) -> None:
        for token in (None, invalid_token, wrong_role):
            status, denied_body = _container_http_response(
                app_container,
                f"{app_url}{path}",
                token=token,
                payload=payload,
                method=method,
                follow_redirects=False,
            )
            denial_diagnostics = denied_body.decode(errors="replace")
            for secret in (postgres_password, operator_token, ingress_token, audit_key):
                _assert_secret_absent(
                    denial_diagnostics, "production role denial", secret
                )
            assert status == 401
            assert json.loads(denied_body) == {"detail": "unauthorized"}

    for path in ("/v1/readyz", "/v1/metrics"):
        assert_role_denials(path)

    # Exercise absence before operator traffic, with fresh qualification quota.
    for path in ("/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"):
        for suffix in ("", "/"):
            for method in ("GET", "HEAD"):
                for token in (None, operator_token, ingress_token):
                    status, absent_body = _container_http_response(
                        app_container,
                        f"{app_url}{path}{suffix}",
                        token=token,
                        method=method,
                        follow_redirects=False,
                    )
                    assert status == 404
                    if method == "GET":
                        assert json.loads(absent_body) == {"detail": "Not Found"}
                    else:
                        assert absent_body == b""
    status, ready_body = _container_http_response(
        app_container, f"{app_url}/v1/readyz", token=operator_token
    )
    assert status == 200
    readiness = json.loads(ready_body)
    assert readiness["status"] == "ready"
    assert readiness["checks"]["database"] == "ready"
    status, metrics_body = _container_http_response(
        app_container, f"{app_url}/v1/metrics", token=operator_token
    )
    assert status == 200
    initial_metrics = metrics_body.decode()
    assert (
        _metric_value(
            initial_metrics,
            "correlia_vigilo_migration_report_status",
            {"status": "valid"},
        )
        == 1.0
    )
    metric_baselines = {
        "audit_writes": _metric_value(
            initial_metrics,
            "correlia_audit_writes_total",
            {"outcome": "success"},
            default=0,
        ),
        "events_accepted": _metric_value(
            initial_metrics,
            "correlia_events_accepted_total",
            {"event_type": "PROBLEM"},
            default=0,
        ),
        "matched_rules": _metric_value(
            initial_metrics, "correlia_matched_rules_total", default=0
        ),
        "incident_inserted": _metric_value(
            initial_metrics,
            "correlia_incident_effects_total",
            {"effect": "inserted"},
            default=0,
        ),
        "notification_submissions": _metric_value(
            initial_metrics,
            "correlia_notification_submissions_total",
            {"outcome": "accepted"},
            default=0,
        ),
        "notification_deliveries": _metric_value(
            initial_metrics,
            "correlia_notification_deliveries_total",
            {"category": "dispatched", "outcome": "success"},
            default=0,
        ),
        "compatibility_acknowledgements": _metric_value(
            initial_metrics,
            "correlia_compatibility_mutations_total",
            {"operation": "patch_acknowledge", "outcome": "success"},
            default=0,
        ),
    }

    migration_revision = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                "'SELECT version_num FROM alembic_version'"
            ),
        ]
    ).stdout.strip()
    image_head = _require_docker_success(
        [
            "run",
            "--rm",
            "--label",
            f"com.docker.compose.project={project}",
            "--entrypoint",
            "alembic",
            "correlia:local",
            "heads",
        ]
    ).stdout.split()[0]
    assert migration_revision == image_head

    app_inspection = _docker_json(["inspect", app_container])
    assert isinstance(app_inspection, list) and len(app_inspection) == 1
    app_state = app_inspection[0]
    assert isinstance(app_state, dict)
    config = app_state["Config"]
    host_config = app_state["HostConfig"]
    assert isinstance(config, dict) and isinstance(host_config, dict)
    assert config["User"] == "correlia"
    assert host_config["ReadonlyRootfs"] is True
    runtime_environment = "\n".join(config["Env"])
    for secret in (postgres_password, operator_token, ingress_token, audit_key):
        if secret not in runtime_environment:
            pytest.fail(
                "runtime secret was not injected exclusively into service environment"
            )
    safe_policy = {
        "CORRELIA_ENVIRONMENT": "production",
        "CORRELIA_API_AUTH_ENABLED": "true",
        "CORRELIA_EXPOSE_READYZ": "false",
        "CORRELIA_EXPOSE_METRICS": "false",
    }
    effective_policy, running, _, _ = _container_startup_policy_state(app_container)
    assert effective_policy == safe_policy
    assert running is True
    qualification_environment = {
        entry.partition("=")[0]: entry.partition("=")[2]
        for entry in config["Env"]
        if entry.partition("=")[0]
        in {
            "CORRELIA_RATE_LIMIT_ENABLED",
            "CORRELIA_RATE_LIMIT_REQUESTS_HEALTH",
            "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_HEALTH",
            "CORRELIA_RATE_LIMIT_REQUESTS_INGRESS",
            "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_INGRESS",
            "CORRELIA_RATE_LIMIT_REQUESTS_OPERATOR",
            "CORRELIA_RATE_LIMIT_WINDOW_SECONDS_OPERATOR",
        }
    }
    for setting, value in (
        ("RATE_LIMIT_ENABLED", "true"),
        ("RATE_LIMIT_REQUESTS_HEALTH", str(_QUALIFICATION_HEALTH_QUOTA)),
        ("RATE_LIMIT_WINDOW_SECONDS_HEALTH", str(_QUALIFICATION_WINDOW_SECONDS)),
        ("RATE_LIMIT_REQUESTS_INGRESS", str(_QUALIFICATION_INGRESS_QUOTA)),
        ("RATE_LIMIT_WINDOW_SECONDS_INGRESS", str(_QUALIFICATION_WINDOW_SECONDS)),
        ("RATE_LIMIT_REQUESTS_OPERATOR", str(_QUALIFICATION_OPERATOR_QUOTA)),
        ("RATE_LIMIT_WINDOW_SECONDS_OPERATOR", str(_QUALIFICATION_WINDOW_SECONDS)),
    ):
        assert qualification_environment[f"CORRELIA_{setting}"] == value
    command_surface = json.dumps(
        {
            "command": config.get("Cmd"),
            "entrypoint": config.get("Entrypoint"),
            "labels": config.get("Labels"),
            "healthcheck": config.get("Healthcheck"),
        },
        sort_keys=True,
    )
    image_surface = json.dumps(_docker_json(["image", "inspect", "correlia:local"]))
    history_surface = _require_docker_success(
        ["image", "history", "--no-trunc", "correlia:local"]
    ).stdout
    for secret in (postgres_password, operator_token, ingress_token, audit_key):
        _assert_secret_absent(command_surface, "container command surface", secret)
        _assert_secret_absent(image_surface, "image configuration", secret)
        _assert_secret_absent(history_surface, "image history", secret)

    processes = _require_docker_success(
        ["top", app_container, "-eo", "pid,user,args"]
    ).stdout.splitlines()
    uvicorn_processes = [line for line in processes if "uvicorn" in line]
    assert len(uvicorn_processes) == 1
    assert "--workers 1" in uvicorn_processes[0]
    assert "--no-access-log" in uvicorn_processes[0]
    assert "--reload" not in uvicorn_processes[0]
    pid_one_command = _require_docker_success(
        [
            "exec",
            app_container,
            "python",
            "-c",
            (
                "import sys; "
                "sys.stdout.buffer.write(open('/proc/1/cmdline', 'rb').read())"
            ),
        ]
    ).stdout.replace("\x00", " ")
    assert "uvicorn" in pid_one_command
    assert "app.main:create_app" in pid_one_command
    assert "--no-access-log" in pid_one_command
    assert int(app_state["State"]["Pid"]) > 0

    for path in (
        "/app/app/main.py",
        "/app/migrations",
        "/app/alembic.ini",
        "/app/scripts/container-entrypoint.sh",
    ):
        _require_docker_success(
            ["exec", "--user", "correlia", app_container, "test", "-r", path]
        )
    assert (
        _docker(
            [
                "exec",
                "--user",
                "correlia",
                app_container,
                "sh",
                "-c",
                "touch /correlia-rootfs-probe",
            ]
        ).returncode
        != 0
    )
    for path in ("/app/config/u7-write-probe", "/app/reports/migration-report.json"):
        assert (
            _docker(
                [
                    "exec",
                    "--user",
                    "correlia",
                    app_container,
                    "sh",
                    "-c",
                    f"printf x >> {path}",
                ]
            ).returncode
            != 0
        )
    report_path = stack["report_path"]
    assert isinstance(report_path, Path)
    report_checksum_before = _file_checksum(report_path)
    config_checksums_before = {
        path: _file_checksum(path) for path in CONFIG_DIRECTORY.glob("*.yaml")
    }

    # Keep this acknowledged incident outside startup expiry sweeps for the
    # entire finite smoke, without changing lifecycle policy or reseeding it.
    persistence_event_time = datetime.now(timezone.utc) + timedelta(days=1)
    payload = {
        "source_id": "icinga2:service:dc1-app-web:http",
        "host": "dc1-app-web",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": persistence_event_time.isoformat(),
        "ip_address": "192.0.2.10",
        "check_output": "HTTP 503",
        "tags": {"team.name": "platform", "topology.datacenter": "dc1"},
    }

    def policy_database_snapshot() -> str:
        return _require_docker_success(
            [
                "exec",
                postgres_container,
                "sh",
                "-c",
                (
                    'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                    '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                    '"SELECT (SELECT count(*) FROM incidents), '
                    "(SELECT count(*) FROM incident_events), "
                    "(SELECT count(*) FROM incidents "
                    "WHERE acknowledged_at IS NOT NULL), "
                    "(SELECT count(*) FROM incidents "
                    'WHERE closed_at IS NOT NULL)"'
                ),
            ]
        ).stdout.strip()

    before_denied_ingestion = policy_database_snapshot()
    assert before_denied_ingestion == "0|0|0|0"
    assert_role_denials(
        "/v1/icinga2/events",
        method="POST",
        payload=payload,
        wrong_role=operator_token,
    )
    assert policy_database_snapshot() == before_denied_ingestion

    status, ingestion_body = _container_http_response(
        app_container,
        f"{app_url}/v1/icinga2/events",
        token=ingress_token,
        payload=payload,
        method="POST",
    )
    assert status == 200
    ingestion = json.loads(ingestion_body)
    assert ingestion["threshold_crossed"] is True
    assert ingestion["notification_triggered"] is True
    incident_id = str(UUID(str(ingestion["incident_id"])))
    persisted_incident = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                f'"SELECT id, status FROM incidents WHERE id = '
                f"'{incident_id}'::uuid\""
            ),
        ]
    ).stdout.strip()
    before_denied_operators = policy_database_snapshot()
    for path in (
        "/v1/plugins",
        "/v1/rules",
        "/v1/topology",
        "/v1/incidents",
        f"/v1/incidents/{incident_id}",
        f"/v1/incident-events?source_id={payload['source_id']}",
    ):
        assert_role_denials(path)
    denied_mutations: tuple[tuple[str, str, dict[str, object] | None], ...] = (
        ("POST", "/ack", {"operator": "deployment-operator"}),
        (
            "POST",
            "/close",
            {"operator": "deployment-operator", "reason": "production role smoke"},
        ),
        ("PATCH", "", {"status": "ACKNOWLEDGED"}),
        ("PATCH", "", {"status": "CLOSED"}),
        ("DELETE", "", None),
    )
    for method, suffix, mutation_payload in denied_mutations:
        assert_role_denials(
            f"/v1/incidents/{incident_id}{suffix}",
            method=method,
            payload=mutation_payload,
        )
    assert policy_database_snapshot() == before_denied_operators

    status, plugins_body = _container_http_response(
        app_container, f"{app_url}/v1/plugins", token=operator_token
    )
    assert status == 200
    assert any(
        plugin["name"] == "email-ops" and plugin["ready"] is True
        for plugin in json.loads(plugins_body)
    )
    status, rules_body = _container_http_response(
        app_container, f"{app_url}/v1/rules", token=operator_token
    )
    assert status == 200
    assert {rule["name"] for rule in json.loads(rules_body)["rules"]} == {
        "docker-smoke-restart-threshold",
        "docker-smoke-capacity-threshold",
        "docker-smoke-threshold",
    }
    status, topology_body = _container_http_response(
        app_container, f"{app_url}/v1/topology", token=operator_token
    )
    assert status == 200
    assert {rule["id"] for rule in json.loads(topology_body)["rules"]} == {
        "sample-datacenter-hostname",
        "documentation-subnet",
    }
    status, incident_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{incident_id}",
        token=operator_token,
    )
    assert status == 200
    assert json.loads(incident_body)["id"] == incident_id
    assert json.loads(incident_body)["status"] == "OPEN"
    assert json.loads(incident_body)["acknowledgement"]["acknowledged_at"] is None
    status, audit_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incident-events?source_id={payload['source_id']}",
        token=operator_token,
    )
    assert status == 200
    audit_page = json.loads(audit_body)
    assert audit_page["total"] == 1
    assert audit_page["items"][0]["incident_ids"] == [incident_id]

    assert persisted_incident == f"{incident_id}|OPEN"
    status, incidents_body = _container_http_response(
        app_container, f"{app_url}/v1/incidents", token=operator_token
    )
    assert status == 200
    assert any(
        item["id"] == incident_id for item in json.loads(incidents_body)["items"]
    )
    status, acknowledged_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{incident_id}",
        token=operator_token,
        payload={"status": "ACKNOWLEDGED"},
        method="PATCH",
    )
    assert status == 200
    acknowledgement = json.loads(acknowledged_body)["acknowledgement"]
    assert acknowledgement["acknowledged_by"] == "vigilo-compat"
    assert acknowledgement["acknowledged_at"] is not None

    expected_subject = (
        "[Correlia] [CRITICAL] docker-smoke-threshold: Critical alert on dc1-app-web"
    )

    def expected_smtp_message() -> tuple[dict[str, object], str] | None:
        messages = _mailpit_messages(app_container, f"{mailpit_url}/api/v1/messages")
        if messages is None:
            return None
        for message in messages:
            if message.get("Subject") != expected_subject or message.get("To") != [
                {"Name": "", "Address": "ops@example.test"}
            ]:
                continue
            message_id = message.get("ID")
            if not isinstance(message_id, str):
                continue
            status, message_body = _container_http_response(
                app_container, f"{mailpit_url}/api/v1/message/{message_id}"
            )
            if status != 200:
                continue
            try:
                message_text = str(json.loads(message_body)["Text"])
            except KeyError, TypeError, json.JSONDecodeError:
                continue
            if (
                f"Incident ID: {incident_id}" in message_text
                and "Rule: docker-smoke-threshold" in message_text
                and "Affected hosts: dc1-app-web" in message_text
            ):
                return message, message_text
        return None

    message, message_text = _wait_until(
        "expected SMTP notification after threshold crossing", expected_smtp_message
    )
    assert message["Subject"] == expected_subject
    assert message["To"] == [{"Name": "", "Address": "ops@example.test"}]
    assert f"Incident ID: {incident_id}" in message_text
    assert "Rule: docker-smoke-threshold" in message_text
    assert "Affected hosts: dc1-app-web" in message_text

    def runtime_metric_deltas() -> str | None:
        status, metrics_body = _container_http_response(
            app_container, f"{app_url}/v1/metrics", token=operator_token
        )
        if status != 200:
            return None
        candidate = metrics_body.decode()
        expected_deltas = (
            (
                "audit_writes",
                "correlia_audit_writes_total",
                {"outcome": "success"},
            ),
            (
                "events_accepted",
                "correlia_events_accepted_total",
                {"event_type": "PROBLEM"},
            ),
            ("matched_rules", "correlia_matched_rules_total", None),
            (
                "incident_inserted",
                "correlia_incident_effects_total",
                {"effect": "inserted"},
            ),
            (
                "notification_submissions",
                "correlia_notification_submissions_total",
                {"outcome": "accepted"},
            ),
            (
                "notification_deliveries",
                "correlia_notification_deliveries_total",
                {"category": "dispatched", "outcome": "success"},
            ),
            (
                "compatibility_acknowledgements",
                "correlia_compatibility_mutations_total",
                {"operation": "patch_acknowledge", "outcome": "success"},
            ),
        )
        if all(
            _metric_value(candidate, metric_name, labels, default=0)
            == metric_baselines[baseline_name] + 1
            for baseline_name, metric_name, labels in expected_deltas
        ):
            return candidate
        return None

    runtime_metrics = _wait_until(
        "concrete operational metric deltas", runtime_metric_deltas
    )
    assert isinstance(runtime_metrics, str)
    assert (
        _metric_value(
            runtime_metrics,
            "correlia_vigilo_migration_report_status",
            {"status": "valid"},
        )
        == 1.0
    )
    for forbidden in (
        postgres_password,
        operator_token,
        ingress_token,
        audit_key,
        "dc1-app-web",
        "service=http",
        "icinga2:service:dc1-app-web:http",
    ):
        _assert_secret_absent(runtime_metrics, "runtime metrics", forbidden)

    # One standalone function qualification in the full gate; it appends its
    # JSON to GITHUB_STEP_SUMMARY even if a budget fails.
    function_run = subprocess.run(
        [sys.executable, str(PROJECT_ROOT / "scripts" / "qualify_audit_bounds.py")],
        cwd=PROJECT_ROOT,
        capture_output=True,
        text=True,
        check=False,
        timeout=180,
    )
    if not function_run.stdout:
        pytest.fail("function qualification did not produce a JSON report")
    try:
        function_report = json.loads(function_run.stdout)
    except json.JSONDecodeError:
        pytest.fail("function qualification returned invalid JSON")
    print("Audit function qualification: " + function_run.stdout, flush=True)
    assert function_report["environment"]["python"] == "3.14.7"

    live_report = _qualify_live_http(
        app_container, app_url, ingress_token, operator_token
    )
    sql_report = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                '"SELECT json_build_object('
                "'accepted_rows', count(*), "
                "'version2_rows', count(*) FILTER "
                "(WHERE redaction_version = 2), "
                "'bounded_raw_rows', count(*) FILTER "
                "(WHERE raw_payload_stored_byte_length <= 65536 "
                "AND raw_payload_stored_byte_length <= raw_payload_original_byte_length "
                "AND raw_payload_hmac IS NOT NULL), "
                "'boundary_rows', count(*) FILTER "
                "(WHERE source_id = 'u4-qual-boundary' "
                "AND normalized_event -> 'tags' ->> 'topology.datacenter' = 'u4' "
                "AND (SELECT count(*) FROM jsonb_object_keys("
                "normalized_event -> 'tags')) = 128 "
                "AND length(normalized_event ->> 'message') = 4096), "
                "'rejected_rows', count(*) FILTER "
                "(WHERE source_id = 'u4-qual-over-limit'), "
                "'boundary_tags', (SELECT normalized_event -> 'tags' "
                "FROM incident_events WHERE source_id = 'u4-qual-boundary' "
                "LIMIT 1)) "
                "FROM incident_events WHERE source_id LIKE 'u4-qual-%'\""
            ),
        ]
    ).stdout.strip()
    try:
        persisted = json.loads(sql_report)
    except json.JSONDecodeError:
        pytest.fail("qualification audit-row query returned invalid JSON")
    persisted_boundary_tags = persisted.pop("boundary_tags", None)
    live_report["persisted_final_tags_equal_input"] = (
        persisted_boundary_tags == exact_tag_bytes(topology_collision=True)
    )
    live_report["persisted_audit_outcomes"] = persisted
    live_report["revision"] = function_report["environment"]["revision"]
    live_report["function_fixture_corpus_sha256"] = function_report["provenance"][
        "fixture_corpus_sha256"
    ]
    _publish_qualification_report("Audit live HTTP qualification (#7/#8)", live_report)
    offered = live_report["ingress_offered"]
    assert isinstance(offered, int) and offered > 0
    assert live_report["successful_ingress_responses"] == offered
    assert live_report["ingress_response_statuses"] == {"200": offered}
    assert live_report["health_overlapping_workload"] >= 100
    assert live_report["observed_ingress_workload_seconds"] >= 10
    loaded = live_report["loaded_health"]
    idle = live_report["idle_health"]
    assert isinstance(loaded, dict) and isinstance(idle, dict)
    assert idle["probes"] >= 35
    assert idle["status_counts"] == {"200": idle["probes"]}
    assert loaded["status_counts"] == {"200": loaded["probes"]}
    assert loaded["p95_ms"] <= 250
    assert loaded["max_ms"] <= 1_000
    assert live_report["topology_boundary_contract"]
    assert live_report["over_limit_safe_422"]
    assert live_report["over_limit_latency_ms"] <= 250
    assert live_report["operator_audit_projection_contract"]
    assert live_report["persisted_final_tags_equal_input"]
    assert persisted == {
        "accepted_rows": offered + 1,
        "version2_rows": offered + 1,
        "bounded_raw_rows": offered + 1,
        "boundary_rows": 1,
        "rejected_rows": 0,
    }
    assert function_report["passed"] and function_run.returncode == 0
    boundary_subject = (
        "[Correlia] [CRITICAL] docker-smoke-threshold: "
        "Critical alert on u4-app-boundary"
    )
    _wait_until(
        "qualification boundary SMTP notification",
        lambda: any(
            message.get("Subject") == boundary_subject
            for message in (
                _mailpit_messages(app_container, f"{mailpit_url}/api/v1/messages") or []
            )
        ),
    )
    # These narrowly matched rules leave the existing threshold-1 smoke and
    # qualification metric baselines unchanged. All events are future-dated
    # relative to the wall clock so the expiration worker cannot remove them.
    window_end = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(
        minutes=10
    )
    window_sources = (
        "u5-window-first",
        "u5-window-second",
        "u5-window-first",
        "u5-window-late",
        "u5-window-outside",
        "u5-window-pruned",
    )
    window_times = (
        window_end,
        window_end - timedelta(seconds=20),
        window_end,
        window_end - timedelta(seconds=40),
        window_end - timedelta(seconds=61),
        window_end + timedelta(seconds=61),
    )

    def post_threshold_event(
        *,
        host: str,
        source_id: str,
        event_time: datetime,
    ) -> dict[str, object]:
        status, response_body = _container_http_response(
            app_container,
            f"{app_url}/v1/icinga2/events",
            token=ingress_token,
            payload={
                "source_id": source_id,
                "host": host,
                "service": "probe",
                "state": "CRITICAL",
                "state_type": "HARD",
                "timestamp": event_time.isoformat(),
                "check_output": "Threshold smoke",
                "tags": {},
            },
            method="POST",
        )
        assert status == 200
        response = json.loads(response_body)
        assert response["state_accepted"] is True
        assert (
            response["threshold_decision"]
            == response["rule_decision"]["threshold_decision"]
        )
        return response

    # These real mutations run after the existing metric-delta qualification.
    # Each close path starts with its own incident and proves retained storage.
    authorized_closures: tuple[tuple[str, str, str, dict[str, object] | None], ...] = (
        (
            "explicit",
            "POST",
            "/close",
            {"operator": "deployment-operator", "reason": "production role smoke"},
        ),
        ("patch", "PATCH", "", {"status": "CLOSED"}),
        ("delete", "DELETE", "", None),
    )
    for label, close_method, close_suffix, close_payload in authorized_closures:
        mutation_ingestion = post_threshold_event(
            host=f"u4-production-{label}",
            source_id=f"u4-production-{label}",
            event_time=window_end,
        )
        mutation_incident_id = str(UUID(str(mutation_ingestion["incident_id"])))
        mutation_path = f"{app_url}/v1/incidents/{mutation_incident_id}"
        if label == "explicit":
            status, explicit_ack_body = _container_http_response(
                app_container,
                f"{mutation_path}/ack",
                token=operator_token,
                payload={"operator": "deployment-operator"},
                method="POST",
            )
            assert status == 200
            explicit_ack = json.loads(explicit_ack_body)
            assert explicit_ack["status"] == "OPEN"
            assert explicit_ack["acknowledgement"]["acknowledged_by"] == (
                "deployment-operator"
            )
            assert explicit_ack["acknowledgement"]["acknowledged_at"] is not None
        status, closed_body = _container_http_response(
            app_container,
            f"{mutation_path}{close_suffix}",
            token=operator_token,
            payload=close_payload,
            method=close_method,
        )
        assert status == 200
        closed = json.loads(closed_body)
        assert closed["id"] == mutation_incident_id
        assert closed["status"] == "CLOSED"
        assert closed["closed_at"] is not None
        notes = closed["decision_context"]["notes"]
        assert notes["lifecycle.operator"] == (
            "deployment-operator" if label == "explicit" else "vigilo-compat"
        )
        assert notes["lifecycle.detail"] == (
            "production role smoke" if label == "explicit" else "vigilo-compat"
        )
        status, stored_closed_body = _container_http_response(
            app_container, mutation_path, token=operator_token
        )
        assert status == 200
        stored_closed = json.loads(stored_closed_body)
        assert stored_closed["id"] == mutation_incident_id
        assert stored_closed["status"] == "CLOSED"
        assert stored_closed["closed_at"] == closed["closed_at"]
        assert stored_closed["decision_context"]["notes"] == notes

    first_window = post_threshold_event(
        host="u5-window", source_id=window_sources[0], event_time=window_times[0]
    )
    window_incident_id = str(UUID(str(first_window["incident_id"])))
    status, before_restart_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{window_incident_id}",
        token=operator_token,
    )
    assert status == 200
    before_restart = json.loads(before_restart_body)
    assert before_restart["window_state"]["counted_count"] == 1
    assert set(before_restart["window_state"]["counted_fingerprint_timestamps"]) == {
        first_window["fingerprint"]
    }
    assert before_restart["threshold_crossed"] is False

    # Restart only the application, preserving PostgreSQL and the mounted rules.
    _require_docker_success(
        _docker_compose_arguments(stack, "restart", "correlia"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    assert (
        _require_docker_success(
            _docker_compose_arguments(stack, "ps", "--quiet", "postgres")
        ).stdout.strip()
        == postgres_container
    )
    _wait_until(
        "public application health after threshold restart",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/health"
                )
            )[0]
            == 200
            else None
        ),
    )
    _wait_until(
        "application readiness after threshold restart",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/readyz", token=operator_token
                )
            )[0]
            == 200
            else None
        ),
    )
    window_responses = [first_window]
    for source_id, event_time in zip(window_sources[1:], window_times[1:]):
        window_responses.append(
            post_threshold_event(
                host="u5-window", source_id=source_id, event_time=event_time
            )
        )

    window_fingerprints = [body["fingerprint"] for body in window_responses]
    assert window_fingerprints[0] == window_fingerprints[2]
    assert len(set(window_fingerprints)) == 5
    expected_window_counts = (1, 2, 2, 3, 3, 1)
    expected_window_crossings = (False, True, True, True, True, False)
    expected_monotone_crossings = (False, True, True, True, True, True)
    expected_reasons = (
        "below_threshold",
        None,
        "replay",
        "already_notified",
        "already_notified",
        "already_notified",
    )
    expected_retained = (
        {window_fingerprints[0]},
        {window_fingerprints[0], window_fingerprints[1]},
        {window_fingerprints[0], window_fingerprints[1]},
        {window_fingerprints[0], window_fingerprints[1], window_fingerprints[3]},
        {window_fingerprints[0], window_fingerprints[1], window_fingerprints[3]},
        {window_fingerprints[5]},
    )
    window_audits: list[dict[str, object]] = []
    for index, body in enumerate(window_responses):
        threshold = body["threshold_decision"]
        assert body["matched_rules"] == ["docker-smoke-restart-threshold"]
        assert body["incident_id"] == window_incident_id
        assert body["group_key"] == "host=u5-window"
        assert threshold["threshold"] == 2
        assert threshold["rule_name"] == "docker-smoke-restart-threshold"
        assert threshold["group_key"] == body["group_key"]
        expected_end = window_times[5] if index == 5 else window_end
        assert datetime.fromisoformat(threshold["window_end"]) == expected_end
        assert datetime.fromisoformat(threshold["window_start"]) == (
            expected_end - timedelta(seconds=60)
        )
        assert threshold["counted"] == expected_window_counts[index]
        assert set(threshold["counted_fingerprints"]) == expected_retained[index]
        assert threshold["crossed"] is expected_window_crossings[index]
        assert body["threshold_crossed"] is expected_monotone_crossings[index]
        assert body["notification_count"] == int(index == 1)
        assert body["notification_triggered"] is (index == 1)
        assert body["no_dispatch_reason"] == expected_reasons[index]
        assert body["incident_effects"] == (
            {"inserted": 1, "updated": 0}
            if index == 0
            else {"inserted": 0, "updated": 1}
        )
        if index == 2:
            assert any(
                "replay" in reason for reason in threshold["replay_or_skip_reasons"]
            )
        if index == 4:
            assert any(
                "outside" in reason for reason in threshold["replay_or_skip_reasons"]
            )

        # The audit endpoint returns a separate, committed snapshot for each
        # request. Replay shares a source id and fingerprint with event one.
        status, audit_body = _container_http_response(
            app_container,
            f"{app_url}/v1/incident-events?source_id={window_sources[index]}",
            token=operator_token,
        )
        assert status == 200
        audit_page = json.loads(audit_body)
        assert audit_page["total"] == (2 if index in (0, 2) else 1)
        if index == 0:
            audit = next(
                item
                for item in audit_page["items"]
                if item["decision_summary"]["replay"] is False
            )
        elif index == 2:
            audit = next(
                item
                for item in audit_page["items"]
                if item["decision_summary"]["replay"] is True
            )
        else:
            audit = audit_page["items"][0]
        assert audit["source_id"] == body["source_id"]
        assert audit["fingerprint"] == body["fingerprint"]
        assert audit["incident_ids"] == [window_incident_id]
        summary = audit["decision_summary"]
        assert summary["decision_kind"] == "problem"
        assert summary["rule_name"] == "docker-smoke-restart-threshold"
        assert summary["group_key"] == body["group_key"]
        assert summary["incident_effect"] == ("inserted" if index == 0 else "updated")
        assert summary["counted_count"] == threshold["counted"]
        assert summary["threshold_count"] == threshold["threshold"]
        assert summary["threshold_crossed"] is body["threshold_crossed"]
        assert summary["replay"] is (index == 2)
        assert summary["first_threshold_transition"] is (index == 1)
        assert summary["no_dispatch_reason"] == body["no_dispatch_reason"]
        assert summary["notification_intent"] == (
            "dispatch_planned" if index == 1 else "no_dispatch"
        )
        window_audits.append(summary)
    assert (
        sum(audit["first_threshold_transition"] is True for audit in window_audits) == 1
    )
    status, window_detail_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{window_incident_id}",
        token=operator_token,
    )
    assert status == 200
    window_detail = json.loads(window_detail_body)
    window_state = window_detail["window_state"]
    assert window_detail["status"] == "OPEN"
    assert window_detail["event_count"] == 4
    assert window_detail["threshold_crossed"] is True
    assert window_state["threshold_count"] == 2
    assert window_state["window_seconds"] == 60
    assert window_state["counted_count"] == 1
    assert window_state["max_size"] == 100
    assert set(window_state["counted_fingerprint_timestamps"]) == {
        window_fingerprints[5]
    }
    assert datetime.fromisoformat(window_state["window_started_at"]) == (
        window_times[5] - timedelta(seconds=60)
    )
    assert datetime.fromisoformat(window_state["window_ended_at"]) == window_times[5]

    capacity_time = window_end
    capacity_incident_id: str | None = None
    capacity_fingerprints: set[str] = set()
    for index in range(1, 101):
        response = post_threshold_event(
            host="u5-capacity",
            source_id=f"u5-capacity-{index:03}",
            event_time=capacity_time,
        )
        threshold = response["threshold_decision"]
        if capacity_incident_id is None:
            capacity_incident_id = str(UUID(str(response["incident_id"])))
        assert response["incident_id"] == capacity_incident_id
        assert response["matched_rules"] == ["docker-smoke-capacity-threshold"]
        assert response["group_key"] == "host=u5-capacity"
        assert threshold["threshold"] == 100
        assert threshold["rule_name"] == "docker-smoke-capacity-threshold"
        assert threshold["group_key"] == response["group_key"]
        assert datetime.fromisoformat(threshold["window_start"]) == (
            capacity_time - timedelta(seconds=300)
        )
        assert datetime.fromisoformat(threshold["window_end"]) == capacity_time
        capacity_fingerprints.add(response["fingerprint"])
        assert len(capacity_fingerprints) == index
        assert threshold["counted"] == index
        assert set(threshold["counted_fingerprints"]) == capacity_fingerprints
        assert threshold["crossed"] is (index == 100)
        assert response["threshold_crossed"] is (index == 100)
        assert response["notification_count"] == int(index == 100)
        assert response["notification_triggered"] is (index == 100)
        assert response["no_dispatch_reason"] == (
            None if index == 100 else "below_threshold"
        )

    assert capacity_incident_id is not None
    status, capacity_detail_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incidents/{capacity_incident_id}",
        token=operator_token,
    )
    assert status == 200
    capacity_detail = json.loads(capacity_detail_body)
    capacity_state = capacity_detail["window_state"]
    assert capacity_detail["status"] == "OPEN"
    assert capacity_detail["event_count"] == 100
    assert capacity_detail["threshold_crossed"] is True
    assert capacity_state["threshold_count"] == 100
    assert capacity_state["counted_count"] == 100
    assert capacity_state["max_size"] == 100
    assert len(capacity_state["counted_fingerprint_timestamps"]) == 100
    assert (
        set(capacity_state["counted_fingerprint_timestamps"]) == capacity_fingerprints
    )
    for index, crossed in ((99, False), (100, True)):
        status, capacity_audit_body = _container_http_response(
            app_container,
            f"{app_url}/v1/incident-events?source_id=u5-capacity-{index:03}",
            token=operator_token,
        )
        assert status == 200
        capacity_page = json.loads(capacity_audit_body)
        assert capacity_page["total"] == 1
        capacity_summary = capacity_page["items"][0]["decision_summary"]
        assert capacity_summary["threshold_count"] == 100
        assert capacity_summary["counted_count"] == index
        assert capacity_summary["threshold_crossed"] is crossed
        assert capacity_summary["first_threshold_transition"] is crossed
        assert capacity_summary["replay"] is False
        assert capacity_summary["notification_intent"] == (
            "dispatch_planned" if crossed else "no_dispatch"
        )

    threshold_report: dict[str, object] = {
        "schema_version": 1,
        "threshold_2_restart": {
            "request_window_counts": list(expected_window_counts),
            "window_duration_seconds": 60,
            "initial_window_start": (window_end - timedelta(seconds=60)).isoformat(),
            "initial_window_end": window_end.isoformat(),
            "pruned_window_start": (
                window_times[5] - timedelta(seconds=60)
            ).isoformat(),
            "pruned_window_end": window_times[5].isoformat(),
            "first_transition_count": 1,
            "accepted_notification_submissions": 1,
            "audit_snapshots": len(window_audits),
            "retained_after_pruning": 1,
        },
        "threshold_100_capacity": {
            "eligible_distinct_events": 100,
            "count_before_crossing": 99,
            "crossing_count": 100,
            "retained_fingerprints": len(capacity_fingerprints),
        },
    }

    _require_docker_success(["stop", "--time", "1", postgres_container])
    try:
        status, outage_health = _container_http_response(
            app_container, f"{app_url}/v1/health"
        )
        assert status == 200
        assert json.loads(outage_health) == {"status": "ok"}
        for path in ("/v1/readyz", "/v1/metrics"):
            assert_role_denials(path)
        status, readiness_diagnostics = _wait_until(
            "readiness to report runtime database loss",
            lambda: (
                response
                if (
                    response := _container_http_response(
                        app_container, f"{app_url}/v1/readyz", token=operator_token
                    )
                )[0]
                == 503
                else None
            ),
        )
        assert status == 503
        diagnostics = readiness_diagnostics.decode()
        for secret in (postgres_password, operator_token, ingress_token, audit_key):
            _assert_secret_absent(diagnostics, "readiness diagnostics", secret)
        outage_readiness = json.loads(readiness_diagnostics)
        assert outage_readiness["detail"] == "not ready"
        assert outage_readiness["checks"]["database"] == "not_ready"
    finally:
        _require_docker_success(["start", postgres_container])
    _wait_until(
        "readiness after database recovery",
        lambda: (
            response
            if (
                response := _container_http_response(
                    app_container, f"{app_url}/v1/readyz", token=operator_token
                )
            )[0]
            == 200
            else None
        ),
    )

    _require_docker_success(["kill", "--signal", "SIGTERM", app_container])
    stopped_app = _wait_until(
        "Uvicorn signal handoff",
        lambda: (
            (inspection if not inspection[0]["State"]["Running"] else None)
            if (inspection := _docker_json(["inspect", app_container]))
            else None
        ),
    )
    assert isinstance(stopped_app, list) and len(stopped_app) == 1
    assert stopped_app[0]["State"]["ExitCode"] == 0
    _require_docker_success(
        _docker_compose_arguments(stack, "up", "--detach", "--wait", "correlia"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    migration_revision_after_restart = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                "'SELECT version_num FROM alembic_version'"
            ),
        ]
    ).stdout.strip()
    assert migration_revision_after_restart == migration_revision
    app_container = _require_docker_success(
        _docker_compose_arguments(stack, "ps", "--quiet", "correlia")
    ).stdout.strip()
    status, persisted_body = _container_http_response(
        app_container, f"{app_url}/v1/incidents/{incident_id}", token=operator_token
    )
    assert status == 200
    persisted_read = json.loads(persisted_body)
    assert persisted_read["id"] == incident_id
    assert persisted_read["status"] == "OPEN"
    assert persisted_read["acknowledgement"] == acknowledgement

    invocation = str(stack["invocation"])
    ownership_receipt = stack["ownership_receipt"]
    assert isinstance(ownership_receipt, Path)
    production_storage = stack["postgres_storage"]
    assert isinstance(production_storage, dict)
    database_volume = str(production_storage["name"])

    def volume_identity(name: str) -> dict[str, object]:
        identity = _docker_json(
            [
                "volume",
                "inspect",
                "--format",
                '{"name":{{json .Name}},"created_at":{{json .CreatedAt}},'
                '"labels":{{json .Labels}}}',
                name,
            ]
        )
        assert isinstance(identity, dict)
        assert identity["name"] == name
        return identity

    retained_volume = volume_identity(database_volume)

    def postgres_json(query: str) -> object:
        result = _require_docker_success(
            [
                "exec",
                postgres_container,
                "sh",
                "-c",
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -At '
                '-v ON_ERROR_STOP=1 -c "$1"',
                "sh",
                query,
            ]
        )
        try:
            return json.loads(result.stdout)
        except json.JSONDecodeError:
            pytest.fail("persistence SQL probe returned invalid JSON")

    def refresh_ready_services(operation: str) -> None:
        nonlocal app_container, postgres_container, mailpit_container
        containers: dict[str, str] = {}
        for service in ("correlia", "postgres", "mailpit"):
            container = _require_docker_success(
                _docker_compose_arguments(stack, "ps", "--quiet", service)
            ).stdout.strip()
            if not container:
                pytest.fail(f"{operation} did not recover {service}")
            identity = _docker_json(["inspect", "--format", "{{json .Id}}", container])
            assert isinstance(identity, str)
            containers[service] = identity
        app_container = containers["correlia"]
        postgres_container = containers["postgres"]
        mailpit_container = containers["mailpit"]
        _wait_until(
            f"PostgreSQL health after {operation}",
            lambda: (
                _docker_json(
                    [
                        "inspect",
                        "--format",
                        "{{json .State.Health.Status}}",
                        postgres_container,
                    ]
                )
                == "healthy"
            ),
            timeout=60,
        )
        status, ready_body = _wait_until(
            f"authenticated database readiness after {operation}",
            lambda: (
                response
                if (
                    response := _container_http_response(
                        app_container, f"{app_url}/v1/readyz", token=operator_token
                    )
                )[0]
                == 200
                else None
            ),
            timeout=60,
        )
        assert status == 200
        readiness = json.loads(ready_body)
        assert readiness["status"] == "ready"
        assert readiness["checks"]["database"] == "ready"
        status, health_body = _container_http_response(
            app_container, f"{app_url}/v1/health"
        )
        assert status == 200
        assert json.loads(health_body) == {"status": "ok"}

    audit_summary_keys = (
        "decision_kind",
        "rule_name",
        "group_key",
        "incident_effect",
        "counted_count",
        "threshold_count",
        "threshold_crossed",
        "replay",
        "first_threshold_transition",
        "no_dispatch_reason",
        "notification_intent",
    )
    sql_summary = ", ".join(
        f"'{key}', decision_summary -> '{key}'" for key in audit_summary_keys
    )

    def persistence_baseline_read() -> dict[str, object]:
        # Only authenticated GETs and SQL SELECTs belong in this proof segment.
        status, detail_body = _container_http_response(
            app_container,
            f"{app_url}/v1/incidents/{incident_id}",
            token=operator_token,
        )
        assert status == 200
        detail = json.loads(detail_body)
        selected_incident = {
            key: detail[key]
            for key in (
                "id",
                "status",
                "acknowledgement",
                "rule_name",
                "group_key",
                "event_count",
                "threshold_crossed",
                "start_time",
                "last_update_time",
                "closed_at",
            )
        }
        assert selected_incident["id"] == incident_id
        assert selected_incident["status"] == "OPEN"
        assert selected_incident["acknowledgement"] == acknowledgement
        status, audit_body = _container_http_response(
            app_container,
            f"{app_url}/v1/incident-events?source_id={payload['source_id']}",
            token=operator_token,
        )
        assert status == 200
        audit_page = json.loads(audit_body)
        assert audit_page["total"] == 1
        selected_audits = [
            {
                "id": str(UUID(item["id"])),
                "source_id": item["source_id"],
                "fingerprint": item["fingerprint"],
                "incident_ids": item["incident_ids"],
                "incident_effect": item["incident_effect"],
                "decision_summary": {
                    key: item["decision_summary"][key] for key in audit_summary_keys
                },
            }
            for item in audit_page["items"]
        ]
        assert len(selected_audits) == 1
        assert selected_audits[0]["source_id"] == payload["source_id"]
        assert selected_audits[0]["incident_ids"] == [incident_id]
        assert selected_audits[0]["fingerprint"] == ingestion["fingerprint"]
        sql_state = postgres_json(
            "SELECT json_build_object("
            "'revision', (SELECT version_num FROM alembic_version), "
            "'incident', (SELECT json_build_object("
            "'id', id, 'status', status, 'acknowledged_at', acknowledged_at, "
            "'acknowledged_by', acknowledged_by, 'event_count', event_count, "
            "'threshold_crossed', threshold_crossed, 'start_time', start_time, "
            "'last_update_time', last_update_time, 'closed_at', closed_at, "
            "'window_state', window_state, 'decision_context', decision_context) "
            f"FROM incidents WHERE id = '{incident_id}'::uuid), "
            "'audits', (SELECT coalesce(jsonb_agg(jsonb_build_object("
            "'id', id, 'source_id', source_id, 'fingerprint', fingerprint, "
            "'incident_ids', incident_ids, 'incident_effect', incident_effect, "
            f"'decision_summary', jsonb_build_object({sql_summary})) "
            "ORDER BY id), '[]'::jsonb) FROM incident_events "
            f"WHERE source_id = '{payload['source_id']}'))"
        )
        assert isinstance(sql_state, dict)
        assert sql_state["revision"] == migration_revision
        assert sql_state["audits"] == selected_audits
        sql_incident = sql_state["incident"]
        assert isinstance(sql_incident, dict)
        assert sql_incident["id"] == incident_id
        assert sql_incident["status"] == selected_incident["status"]
        assert sql_incident["acknowledged_by"] == acknowledgement["acknowledged_by"]
        assert datetime.fromisoformat(sql_incident["acknowledged_at"]) == (
            datetime.fromisoformat(acknowledgement["acknowledged_at"])
        )
        assert datetime.fromisoformat(sql_incident["last_update_time"]) == (
            persistence_event_time
        )
        return {
            "incident": selected_incident,
            "audits": selected_audits,
            "sql": sql_state,
        }

    durable_baseline = persistence_baseline_read()
    preservation_evidence: list[dict[str, object]] = []

    def prove_preservation(
        operation: str, previous_postgres: str, *, same_container: bool
    ) -> None:
        refresh_ready_services(operation)
        assert (postgres_container == previous_postgres) is same_container
        storage = _postgres_storage_identity(stack, postgres_container)
        assert storage == production_storage
        assert volume_identity(database_volume) == retained_volume
        observed_baseline = persistence_baseline_read()
        assert observed_baseline == durable_baseline
        preservation_evidence.append(
            {
                "operation": operation,
                "postgres_container_before": previous_postgres,
                "postgres_container_after": postgres_container,
                "app_container": app_container,
                "mailpit_container": mailpit_container,
                "storage": storage,
                "volume_created_at": retained_volume["created_at"],
                "postgres_health": "healthy",
                "authenticated_database_ready": True,
                "read_only_baseline": observed_baseline,
            }
        )

    previous_postgres = postgres_container
    _require_docker_success(
        _docker_compose_arguments(stack, "stop", "--timeout", "1"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    for container in (app_container, postgres_container, mailpit_container):
        assert (
            _docker_json(["inspect", "--format", "{{json .State.Running}}", container])
            is False
        )
    # Compose v2 has no start --wait flag; the preservation probe below waits
    # for authenticated readiness before comparing the retained data.
    _require_docker_success(
        _docker_compose_arguments(stack, "start"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    prove_preservation("full stop/start", previous_postgres, same_container=True)

    previous_postgres = postgres_container
    _require_docker_success(
        _docker_compose_arguments(stack, "down", "--remove-orphans"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    assert volume_identity(database_volume) == retained_volume
    _require_docker_success(
        _docker_compose_arguments(stack, "up", "--detach", "--no-build", "--wait"),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    prove_preservation("ordinary down/up", previous_postgres, same_container=False)
    preservation_evidence[-1]["volume_retained_while_down"] = True

    previous_postgres = postgres_container
    _require_docker_success(
        _docker_compose_arguments(
            stack,
            "up",
            "--detach",
            "--no-build",
            "--force-recreate",
            "--no-deps",
            "--wait",
            "postgres",
        ),
        environment=stack["environment"],  # type: ignore[arg-type]
    )
    prove_preservation(
        "PostgreSQL force recreation", previous_postgres, same_container=False
    )

    # This is a separate write after every preservation proof, never a reseed.
    accepted_source_id = "u2-persistence-after-preservation"
    accepted_write = post_threshold_event(
        host="u2-persistence-after-preservation",
        source_id=accepted_source_id,
        event_time=persistence_event_time,
    )
    accepted_incident_id = str(UUID(str(accepted_write["incident_id"])))
    assert accepted_incident_id != incident_id
    status, accepted_audit_body = _container_http_response(
        app_container,
        f"{app_url}/v1/incident-events?source_id={accepted_source_id}",
        token=operator_token,
    )
    assert status == 200
    accepted_audit_page = json.loads(accepted_audit_body)
    assert accepted_audit_page["total"] == 1
    accepted_audit_id = str(UUID(accepted_audit_page["items"][0]["id"]))
    accepted_sql = postgres_json(
        "SELECT json_build_object("
        "'incident_id', incidents.id, 'status', incidents.status, "
        "'audit_id', incident_events.id, 'source_id', source_id, "
        "'incident_ids', incident_ids, 'incident_effect', incident_effect) "
        "FROM incidents JOIN incident_events "
        "ON incident_events.incident_ids @> jsonb_build_array(incidents.id::text) "
        f"WHERE incidents.id = '{accepted_incident_id}'::uuid "
        f"AND source_id = '{accepted_source_id}'"
    )
    assert accepted_sql == {
        "incident_id": accepted_incident_id,
        "status": "OPEN",
        "audit_id": accepted_audit_id,
        "source_id": accepted_source_id,
        "incident_ids": [accepted_incident_id],
        "incident_effect": "inserted",
    }
    assert persistence_baseline_read() == durable_baseline
    _publish_qualification_report(
        "Local PostgreSQL preservation qualification",
        {
            "schema_version": 1,
            "project": project,
            "preservation_operations": preservation_evidence,
            "separate_accepted_write": accepted_sql,
        },
    )

    # Reuse the built service and healthy migrated database, never a second stack.
    # Compose process overrides must defeat an intact, safe --env-file.
    env_file = stack["env_file"]
    assert isinstance(env_file, Path)
    policy_environment = _load_dotenv_example(env_file)
    policy_suffix = uuid4().hex
    policy_environment.update(
        {
            "CORRELIA_OPERATOR_API_TOKEN": f"u4-policy-operator-{policy_suffix}",
            "CORRELIA_INGRESS_API_TOKEN": f"u4-policy-ingress-{policy_suffix}",
            "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY": f"u4-policy-audit-{policy_suffix}",
        }
    )
    lower_policy = {name: policy_environment[name] for name in safe_policy}
    assert lower_policy == safe_policy
    policy_env_file = tmp_path / "production-policy-safe.env"
    policy_env_file.write_text(
        "\n".join(f"{name}={value}" for name, value in policy_environment.items())
        + "\n"
    )
    policy_env_checksum = _file_checksum(policy_env_file)
    local_defaults = {
        name: value
        for name, value in policy_environment.items()
        if name != "CORRELIA_EXPOSE_METRICS"
    }
    local_defaults["CORRELIA_ENVIRONMENT"] = "local"
    local_defaults_file = tmp_path / "production-policy-local-defaults.env"
    local_defaults_file.write_text(
        "\n".join(f"{name}={value}" for name, value in local_defaults.items()) + "\n"
    )
    policy_secrets = (
        postgres_password,
        operator_token,
        ingress_token,
        audit_key,
        policy_environment["DATABASE_URL"],
        policy_environment["CORRELIA_OPERATOR_API_TOKEN"],
        policy_environment["CORRELIA_INGRESS_API_TOKEN"],
        policy_environment["CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY"],
    )
    policy_rejections: list[dict[str, object]] = []
    for label, setting, unsafe_value, required_value, uses_local_default in (
        (
            "auth-disabled",
            "CORRELIA_API_AUTH_ENABLED",
            "false",
            "api_auth_enabled=true",
            False,
        ),
        (
            "public-readiness",
            "CORRELIA_EXPOSE_READYZ",
            "true",
            "expose_readyz=false",
            False,
        ),
        (
            "public-metrics",
            "CORRELIA_EXPOSE_METRICS",
            "true",
            "expose_metrics=false",
            False,
        ),
        (
            "production-with-local-metrics-default",
            "CORRELIA_ENVIRONMENT",
            "production",
            "expose_metrics=false",
            True,
        ),
    ):
        status, healthy_database_body = _container_http_response(
            app_container, f"{app_url}/v1/readyz", token=operator_token
        )
        assert status == 200
        assert json.loads(healthy_database_body)["checks"]["database"] == "ready"
        probe_environment = {**os.environ, **policy_environment}
        probe_environment[setting] = unsafe_value
        expected_policy = {**safe_policy, setting: unsafe_value}
        probe_stack = {**stack, "env_file": policy_env_file}
        if uses_local_default:
            # No metrics value remains in either interpolation source; the
            # checked-in Compose local default, true, is the effective input.
            probe_environment.pop("CORRELIA_EXPOSE_METRICS", None)
            probe_stack["env_file"] = local_defaults_file
            expected_policy["CORRELIA_EXPOSE_METRICS"] = "true"
        policy_container = f"{project}-policy-{label}-{uuid4().hex[:8]}"
        try:
            try:
                policy_run = _docker(
                    _docker_compose_arguments(
                        probe_stack,
                        "run",
                        "--no-deps",
                        "--name",
                        policy_container,
                        "correlia",
                    ),
                    environment=probe_environment,
                    timeout=90,
                )
            except OSError, subprocess.TimeoutExpired:
                pytest.fail(
                    "production policy probe did not reach a bounded startup result",
                    pytrace=False,
                )
            policy_logs = _require_docker_success(["logs", policy_container])
            healthcheck_logs = _require_docker_success(
                [
                    "inspect",
                    "--format",
                    "{{with .State.Health}}{{range .Log}}{{println .Output}}{{end}}{{end}}",
                    policy_container,
                ]
            )
            surfaces = (
                policy_run.stdout,
                policy_run.stderr,
                policy_logs.stdout,
                policy_logs.stderr,
                healthcheck_logs.stdout,
                healthcheck_logs.stderr,
            )
            for surface in surfaces:
                for secret in policy_secrets:
                    _assert_secret_absent(
                        surface, "production policy startup diagnostics", secret
                    )
            if policy_run.returncode == 0:
                pytest.fail("unsafe production startup unexpectedly succeeded")
            effective_policy, running, exit_code, container_status = (
                _container_startup_policy_state(policy_container)
            )
            assert effective_policy == expected_policy
            assert running is False
            assert container_status == "exited"
            assert exit_code != 0
            diagnostics = "\n".join(surfaces)
            if f"production requires: {required_value}" not in diagnostics:
                pytest.fail("startup did not report the expected production policy")
            if "Database migration failed" in diagnostics:
                pytest.fail("migration failure is not production policy rejection")
            if any(
                marker in diagnostics
                for marker in ("Application startup complete", "Uvicorn running on")
            ):
                pytest.fail("unsafe production startup reached a serving lifecycle")
            policy_rejections.append(
                {
                    "scenario": label,
                    "effective_policy": effective_policy,
                    "running": running,
                    "state": container_status,
                    "exit_code": exit_code,
                    "policy_requirement": required_value,
                    "diagnostics_secret_free": True,
                }
            )
        finally:
            _require_docker_success(["rm", "--force", policy_container])
    assert _file_checksum(policy_env_file) == policy_env_checksum
    migration_revision_after_policy_probes = _require_docker_success(
        [
            "exec",
            postgres_container,
            "sh",
            "-c",
            (
                'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 '
                '-U "$POSTGRES_USER" -d "$POSTGRES_DB" -Atc '
                "'SELECT version_num FROM alembic_version'"
            ),
        ]
    ).stdout.strip()
    assert migration_revision_after_policy_probes == image_head
    _publish_qualification_report(
        "Production startup policy qualification",
        {
            "schema_version": 1,
            "healthy_migrated_database": True,
            "safe_lower_precedence_env_file_unchanged": True,
            "policy_rejections": policy_rejections,
        },
    )

    migration_failure_name = f"{project}-migration-failure"
    migration_failure_secret = f"migration-failure-{uuid4().hex}"
    migration_failure_dsn = (
        "postgresql+asyncpg://correlia:"
        f"{migration_failure_secret}@postgres:5432/correlia"
    )
    migration_failure_env = tmp_path / "migration-failure.env"
    migration_failure_env.write_text(f"DATABASE_URL={migration_failure_dsn}\n")
    try:
        migration_failure = _docker(
            [
                "run",
                "--name",
                migration_failure_name,
                "--label",
                f"com.docker.compose.project={project}",
                "--network",
                f"{project}_database",
                "--env-file",
                str(migration_failure_env),
                "correlia:local",
            ],
            timeout=60,
        )
        assert migration_failure.returncode != 0
        migration_diagnostics = (
            f"{migration_failure.stdout}\n{migration_failure.stderr}"
        )
        assert "Database migration failed" in migration_diagnostics
        assert "downgrade" not in migration_diagnostics
        for secret in (
            postgres_password,
            operator_token,
            ingress_token,
            audit_key,
            migration_failure_secret,
            migration_failure_dsn,
        ):
            _assert_secret_absent(
                migration_diagnostics, "migration failure diagnostics", secret
            )
    finally:
        _require_docker_success(["rm", "--force", migration_failure_name])

    invalid_config = tmp_path / "invalid-config"
    shutil.copytree(CONFIG_DIRECTORY, invalid_config)
    invalid_plugin_sentinel = f"u7-invalid-plugin-{uuid4().hex}"
    invalid_plugins = yaml.safe_load((invalid_config / "plugins.yaml").read_text())
    invalid_plugins["outputs"][0]["class_path"] = (
        f"app.plugins.outputs.{invalid_plugin_sentinel}.MissingPlugin"
    )
    (invalid_config / "plugins.yaml").write_text(yaml.safe_dump(invalid_plugins))
    invalid_plugin_name = f"{project}-invalid-plugin"
    try:
        invalid_plugin = _docker(
            [
                "run",
                "--name",
                invalid_plugin_name,
                "--label",
                f"com.docker.compose.project={project}",
                "--network",
                f"{project}_database",
                "--volume",
                f"{invalid_config}:/app/config:ro",
                "--env-file",
                str(env_file),
                "correlia:local",
            ],
            timeout=90,
        )
        assert invalid_plugin.returncode != 0
        invalid_diagnostics = f"{invalid_plugin.stdout}\n{invalid_plugin.stderr}"
        invalid_logs = _require_docker_success(["logs", invalid_plugin_name])
        for surface in (invalid_diagnostics, invalid_logs.stdout, invalid_logs.stderr):
            _assert_secret_absent(
                surface,
                "invalid plugin startup diagnostics",
                invalid_plugin_sentinel,
            )
            for secret in (postgres_password, operator_token, ingress_token, audit_key):
                _assert_secret_absent(
                    surface, "invalid plugin startup diagnostics", secret
                )
        plugin_events = [
            json.loads(line)
            for line in f"{invalid_logs.stdout}\n{invalid_logs.stderr}".splitlines()
            if line.startswith("{")
        ]
        expected_plugin_event = {
            "event": "plugin_load",
            "outcome": "failure",
            "category": "email",
            "failure_code": "module_or_class",
            "entry_position": 1,
        }
        assert any(
            expected_plugin_event.items() <= event.items() for event in plugin_events
        )
        invalid_inspection = _docker_json(["inspect", invalid_plugin_name])
        assert isinstance(invalid_inspection, list) and len(invalid_inspection) == 1
        assert invalid_inspection[0]["State"]["ExitCode"] != 0
    finally:
        _require_docker_success(["rm", "--force", invalid_plugin_name])

    invalid_threshold_config = tmp_path / "invalid-threshold-config"
    shutil.copytree(CONFIG_DIRECTORY, invalid_threshold_config)
    invalid_rules_path = invalid_threshold_config / "rules.yaml"
    invalid_rules = yaml.safe_load(invalid_rules_path.read_text())
    invalid_rules["rules"][0]["window"]["trigger_threshold"] = 101
    invalid_rules_path.write_text(yaml.safe_dump(invalid_rules))
    invalid_threshold_name = f"{project}-invalid-threshold"
    try:
        invalid_threshold = _docker(
            [
                "run",
                "--name",
                invalid_threshold_name,
                "--label",
                f"com.docker.compose.project={project}",
                "--network",
                f"{project}_database",
                "--volume",
                f"{invalid_threshold_config}:/app/config:ro",
                "--env-file",
                str(env_file),
                "correlia:local",
            ],
            timeout=90,
        )
        assert invalid_threshold.returncode != 0
        invalid_threshold_logs = _require_docker_success(
            ["logs", invalid_threshold_name]
        )
        for surface in (
            invalid_threshold.stdout,
            invalid_threshold.stderr,
            invalid_threshold_logs.stdout,
            invalid_threshold_logs.stderr,
        ):
            for secret in (postgres_password, operator_token, ingress_token, audit_key):
                _assert_secret_absent(
                    surface, "invalid threshold startup diagnostics", secret
                )
        threshold_diagnostics = (
            f"{invalid_threshold.stdout}\n{invalid_threshold.stderr}\n"
            f"{invalid_threshold_logs.stdout}\n{invalid_threshold_logs.stderr}"
        )
        assert "rules.0.window.trigger_threshold" in threshold_diagnostics
        assert "less_than_equal" in threshold_diagnostics
        assert "100" in threshold_diagnostics
        threshold_inspection = _docker_json(["inspect", invalid_threshold_name])
        assert isinstance(threshold_inspection, list) and len(threshold_inspection) == 1
        assert threshold_inspection[0]["State"]["Running"] is False
        assert threshold_inspection[0]["State"]["ExitCode"] != 0
    finally:
        _require_docker_success(["rm", "--force", invalid_threshold_name])

    # All original-data-dependent scenarios are complete. Acquire a distinct
    # disposable namespace for the unrelated-project sentinel, not another stack.
    sentinel_project = f"correlia-verify-{uuid4().hex}"
    sentinel_invocation = uuid4().hex
    sentinel_receipt = tmp_path / "persistence-sentinel-ownership.json"
    sentinel_volume = cleanup_verification.postgres_data_volume(sentinel_project)
    sentinel_marker = f"preserve-{uuid4().hex}"
    cleanup_verification.acquire(
        sentinel_project, sentinel_invocation, sentinel_receipt
    )
    try:
        _require_docker_success(
            [
                "volume",
                "create",
                "--label",
                f"com.docker.compose.project={sentinel_project}",
                "--label",
                "com.docker.compose.volume=postgres-data",
                sentinel_volume,
            ]
        )
        sentinel_identity = volume_identity(sentinel_volume)
        _require_docker_success(
            [
                "run",
                "--rm",
                "--label",
                f"com.docker.compose.project={sentinel_project}",
                "--user",
                "0",
                "--volume",
                f"{sentinel_volume}:/sentinel",
                "--entrypoint",
                "sh",
                "correlia:local",
                "-c",
                'printf "%s" "$1" > /sentinel/persistence-sentinel',
                "sh",
                sentinel_marker,
            ]
        )

        # Revalidate the exact original receipt before intentional data deletion.
        assert stack["ownership_receipt"] == ownership_receipt
        assert stack["invocation"] == invocation
        assert cleanup_verification.has_ownership(
            project, invocation, ownership_receipt
        )
        previous_postgres = postgres_container
        _compose_cleanup(stack)
        remaining_volumes = _require_docker_success(
            ["volume", "ls", "--quiet"]
        ).stdout.split()
        assert database_volume not in remaining_volumes
        assert sentinel_volume in remaining_volumes
        assert volume_identity(sentinel_volume) == sentinel_identity

        _require_docker_success(
            _docker_compose_arguments(stack, "up", "--detach", "--no-build", "--wait"),
            environment=stack["environment"],  # type: ignore[arg-type]
        )
        refresh_ready_services("owned destructive reset")
        assert postgres_container != previous_postgres
        fresh_storage = _postgres_storage_identity(stack, postgres_container)
        assert fresh_storage == production_storage
        fresh_sql = postgres_json(
            "SELECT json_build_object("
            "'revision', (SELECT version_num FROM alembic_version), "
            "'incidents', (SELECT count(*) FROM incidents), "
            "'audits', (SELECT count(*) FROM incident_events))"
        )
        assert fresh_sql == {
            "revision": image_head,
            "incidents": 0,
            "audits": 0,
        }
        for erased_incident_id in (incident_id, accepted_incident_id):
            status, _ = _container_http_response(
                app_container,
                f"{app_url}/v1/incidents/{erased_incident_id}",
                token=operator_token,
            )
            assert status == 404
        for path in (
            "/v1/incidents",
            "/v1/incident-events",
            f"/v1/incident-events?source_id={payload['source_id']}",
            f"/v1/incident-events?source_id={accepted_source_id}",
        ):
            status, empty_body = _container_http_response(
                app_container, f"{app_url}{path}", token=operator_token
            )
            assert status == 200
            empty_page = json.loads(empty_body)
            assert empty_page["total"] == 0
            assert empty_page["items"] == []

        assert volume_identity(sentinel_volume) == sentinel_identity
        retained_marker = _require_docker_success(
            [
                "run",
                "--rm",
                "--label",
                f"com.docker.compose.project={sentinel_project}",
                "--user",
                "0",
                "--volume",
                f"{sentinel_volume}:/sentinel:ro",
                "--entrypoint",
                "cat",
                "correlia:local",
                "/sentinel/persistence-sentinel",
            ]
        ).stdout
        assert retained_marker == sentinel_marker
        _publish_qualification_report(
            "Local PostgreSQL destructive reset qualification",
            {
                "schema_version": 1,
                "operation": "owned down with volume deletion/fresh up",
                "project": project,
                "ownership_receipt_matched": True,
                "postgres_container_before": previous_postgres,
                "postgres_container_after": postgres_container,
                "app_container": app_container,
                "mailpit_container": mailpit_container,
                "removed_volume": database_volume,
                "volume_absent_before_fresh_startup": True,
                "fresh_storage": fresh_storage,
                "postgres_health": "healthy",
                "authenticated_database_ready": True,
                "erased_incident_ids": [incident_id, accepted_incident_id],
                "erased_baseline_audits": durable_baseline["audits"],
                "fresh_sql": fresh_sql,
                "unrelated_project_sentinel": sentinel_identity,
                "sentinel_content_unchanged": True,
            },
        )
    finally:
        if not cleanup_verification.cleanup_owned(
            sentinel_project, sentinel_invocation, sentinel_receipt
        ):
            pytest.fail("sentinel cleanup refused without invocation ownership")

    from _local_postgres_migration_rehearsal import rehearse_local_postgres_migration

    rehearse_local_postgres_migration(stack, tmp_path)

    assert _file_checksum(report_path) == report_checksum_before
    assert {
        path: _file_checksum(path) for path in CONFIG_DIRECTORY.glob("*.yaml")
    } == config_checksums_before
    threshold_report["threshold_101_startup"] = {
        "rejected_before_serving": True,
        "validation_field": "rules[0].window.trigger_threshold",
        "supported_maximum": 100,
        "diagnostics_secret_free": True,
    }
    _publish_qualification_report(
        "Durable threshold runtime qualification", threshold_report
    )
