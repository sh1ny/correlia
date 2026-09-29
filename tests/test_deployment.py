"""Always-run deployment artifact and controlled entrypoint contract tests."""

from __future__ import annotations

from collections.abc import Iterator
from fnmatch import fnmatchcase
from http.server import BaseHTTPRequestHandler, HTTPServer
import base64
from datetime import datetime, timezone
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
) -> tuple[int, bytes]:
    script = """
import base64
import json
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

url, method, token, payload = json.loads(sys.stdin.read())
data = json.dumps(payload).encode() if payload is not None else None
headers = {"Content-Type": "application/json"} if data is not None else {}
if token:
    headers["Authorization"] = f"Bearer {token}"
request = Request(url, data=data, headers=headers, method=method)
try:
    with urlopen(request, timeout=2) as response:
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
        input_data=json.dumps((url, method, token, payload)),
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


def _compose_cleanup(stack: dict[str, object]) -> None:
    failed = False
    try:
        result = _docker(
            _docker_compose_arguments(stack, "down", "--volumes", "--remove-orphans")
        )
        failed = result.returncode != 0
    except OSError, subprocess.TimeoutExpired:
        failed = True
    try:
        cleanup_verification.cleanup(str(stack["project"]))
    except RuntimeError:
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
        "container": owned["container"] | {"developer-container"},
        "volume": owned["volume"] | {"developer-volume"},
        "network": owned["network"] | {"developer-network"},
    }

    def fake_docker(
        arguments: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        if arguments[0] == "compose":
            return subprocess.CompletedProcess(["docker", *arguments], 1)
        assert arguments[-1] == f"label=com.docker.compose.project={project}" or (
            arguments[-1] in set().union(*owned.values())
        )
        listing = {
            ("ps", "--all"): "container",
            ("volume", "ls"): "volume",
            ("network", "ls"): "network",
        }
        kind = listing.get(tuple(arguments[:2]))
        if kind:
            return subprocess.CompletedProcess(
                ["docker", *arguments],
                0,
                stdout="\n".join(sorted(resources[kind] & owned[kind])),
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
    stack = {
        "project": project,
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

    project = os.environ.setdefault(
        "CORRELIA_VERIFICATION_PROJECT", f"correlia-verify-{uuid4().hex}"
    )
    try:
        cleanup_verification.validate_project(project)
    except ValueError:
        pytest.fail("invalid verification project identifier")
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
                    }
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
        "CORRELIA_ENVIRONMENT": "test",
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
                "    volumes:",
                f"      - {report_path}:/app/reports/migration-report.json:ro",
                f"      - {smoke_rules_path}:/app/smoke/rules.yaml:ro",
                "  mailpit:",
                "    ports: !reset []",
                "  postgres:",
                "    volumes:",
                "      - verification-data:/var/lib/postgresql/data",
                "volumes:",
                "  verification-data: {}",
                "",
            )
        )
    )
    stack: dict[str, object] = {
        "project": project,
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

    assert settings.api_auth_enabled is True
    assert settings.expose_readyz is False
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

    status, _ = _container_http_response(app_container, f"{app_url}/v1/readyz")
    assert status == 401
    status, _ = _container_http_response(
        app_container, f"{app_url}/v1/readyz", token="wrong-token"
    )
    assert status == 401
    status, ready_body = _container_http_response(
        app_container, f"{app_url}/v1/readyz", token=operator_token
    )
    assert status == 200
    assert json.loads(ready_body)["status"] == "ready"

    status, _ = _container_http_response(app_container, f"{app_url}/v1/metrics")
    assert status == 401
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
    for setting, value in (
        ("RATE_LIMIT_ENABLED", "true"),
        ("RATE_LIMIT_REQUESTS_HEALTH", str(_QUALIFICATION_HEALTH_QUOTA)),
        ("RATE_LIMIT_WINDOW_SECONDS_HEALTH", str(_QUALIFICATION_WINDOW_SECONDS)),
        ("RATE_LIMIT_REQUESTS_INGRESS", str(_QUALIFICATION_INGRESS_QUOTA)),
        ("RATE_LIMIT_WINDOW_SECONDS_INGRESS", str(_QUALIFICATION_WINDOW_SECONDS)),
    ):
        assert f"CORRELIA_{setting}={value}" in config["Env"]
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

    payload = {
        "source_id": "icinga2:service:dc1-app-web:http",
        "host": "dc1-app-web",
        "service": "http",
        "state": "CRITICAL",
        "state_type": "HARD",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ip_address": "192.0.2.10",
        "check_output": "HTTP 503",
        "tags": {"team.name": "platform", "topology.datacenter": "dc1"},
    }
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
    _require_docker_success(["stop", "--time", "1", postgres_container])
    try:
        status, _ = _container_http_response(app_container, f"{app_url}/v1/health")
        assert status == 200
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
    env_file = stack["env_file"]
    assert isinstance(env_file, Path)
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

    assert _file_checksum(report_path) == report_checksum_before
    assert {
        path: _file_checksum(path) for path in CONFIG_DIRECTORY.glob("*.yaml")
    } == config_checksums_before
