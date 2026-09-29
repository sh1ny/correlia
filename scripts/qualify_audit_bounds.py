"""Repeatable function-level audit cap qualification; run from the repository root.

Historical cases reconstruct only the recorded counts and canonical byte lengths.
Their original content, generator, machine and repetitions are unavailable; the
recorded old timings are evidence from the issue, not timings of these cases.
"""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
from dataclasses import dataclass
from time import perf_counter_ns
from typing import Any

# Direct invocation (`python scripts/qualify_audit_bounds.py`) starts with
# scripts/, not the repository root, on sys.path.
ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from app.domain.events import (  # noqa: E402
    EVENT_TAG_MAX_BYTES,
    EVENT_TAG_MAX_ENTRIES,
    EVENT_TAG_MAX_KEY_BYTES,
    EventTagValidationError,
    validate_event_tags,
)
from app.persistence.audit import canonical_json_bytes, redact_payload  # noqa: E402
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload  # noqa: E402

BODY_CEILING = 1_048_576
DEFAULT_RAW_CAP = 65_536
MINIMUM_RAW_CAP = 1_024
MEASURED_CALLS = 30
WARMUP_CALLS = 3
P95_BUDGET_MS = 250.0
GROWTH_LIMIT = 3.0
GROWTH_DENOMINATOR_FLOOR_MS = 20.0
_HMAC_KEY = "qualification-synthetic-not-a-deployment-secret"
HISTORICAL_LENGTHS = {1000: 15_181, 5000: 75_181, 10000: 150_181}
HISTORICAL_TIMINGS_SECONDS = {1000: 0.0108, 5000: 3.5014, 10000: 46.4278}


@dataclass(frozen=True)
class AuditFixture:
    name: str
    payload: dict[str, Any]
    parameters: dict[str, object]
    ingress_permitted: bool

    @property
    def canonical_bytes(self) -> bytes:
        return canonical_json_bytes(self.payload)

    @property
    def digest(self) -> str:
        return hashlib.sha256(self.canonical_bytes).hexdigest()


def _model_dump(*, tags: dict[str, str], **overrides: object) -> dict[str, Any]:
    payload: dict[str, object] = {
        "source_id": "q",
        "host": "q",
        "service": None,
        "state": "DOWN",
        "state_type": "HARD",
        "timestamp": "2026-09-29T00:00:00+00:00",
        "check_output": "x",
        "ip_address": None,
        "tags": tags,
    }
    payload.update(overrides)
    return Icinga2WebhookPayload.model_validate(payload).model_dump(mode="json")


def exact_tag_bytes(*, topology_collision: bool = False) -> dict[str, str]:
    """A 128-key permitted object of exactly 16,384 canonical UTF-8 bytes."""
    tags = {f"k{index:03}": "x" for index in range(EVENT_TAG_MAX_ENTRIES)}
    if topology_collision:
        tags.pop("k127")
        tags["topology.datacenter"] = "u4"
    remaining = EVENT_TAG_MAX_BYTES - len(canonical_json_bytes(tags))
    adjustable = sorted(key for key in tags if key != "topology.datacenter")
    quotient, remainder = divmod(remaining, len(adjustable))
    for index, key in enumerate(adjustable):
        tags[key] += "x" * (quotient + (index < remainder))
    validate_event_tags(tags)
    assert len(canonical_json_bytes(tags)) == EVENT_TAG_MAX_BYTES
    return tags


def _historical_fixture(count: int, expected_bytes: int) -> AuditFixture:
    # Eight-character keys, one-character values: 15 bytes per extra entry.
    # Calibrate a short *permitted* scalar, not a fictional accepted tag map.
    tags = {f"k{index:07}": "x" for index in range(count)}
    payload = _model_dump(tags={})
    payload["tags"] = tags  # historical pre-limit ingress shape, direct redactor only
    unpadded = len(canonical_json_bytes(payload))
    padding = expected_bytes - unpadded
    if padding < 0:
        raise AssertionError("historical reconstruction needs a shorter base payload")
    # Replacing null by a JSON string costs -2 bytes at equal character count.
    if padding:
        payload["ip_address"] = "a" * (padding + 2)
    assert len(canonical_json_bytes(payload)) == expected_bytes
    return AuditFixture(
        name=f"historical_reconstructed_{count}",
        payload=payload,
        parameters={
            "kind": "reconstructed_not_original",
            "tag_count": count,
            "tag_key_format": "k%07d",
            "tag_value": "x",
            "ip_padding_characters": len(payload["ip_address"] or ""),
            "target_canonical_bytes": expected_bytes,
            "original_issue_seconds_not_comparable": HISTORICAL_TIMINGS_SECONDS[count],
        },
        ingress_permitted=False,
    )


def make_corpus() -> tuple[AuditFixture, ...]:
    historical = tuple(
        _historical_fixture(count, size) for count, size in HISTORICAL_LENGTHS.items()
    )
    permitted = (
        AuditFixture(
            "count_128",
            _model_dump(tags={f"k{i:03}": "x" for i in range(128)}),
            {"tag_count": 128, "tag_value": "x"},
            True,
        ),
        AuditFixture(
            "max_key_64",
            _model_dump(tags={f"k{i:03}" + "a" * 60: "x" for i in range(128)}),
            {"tag_count": 128, "key_length_bytes": EVENT_TAG_MAX_KEY_BYTES},
            True,
        ),
        AuditFixture(
            "exact_tag_bytes_16384",
            _model_dump(tags=exact_tag_bytes()),
            {"tag_count": 128, "tag_canonical_bytes": EVENT_TAG_MAX_BYTES},
            True,
        ),
        AuditFixture(
            "four_byte_unicode",
            _model_dump(tags={f"k{i:03}": "🧪" * 20 for i in range(128)}),
            {"tag_count": 128, "unicode_codepoint_bytes": 4, "value_length": 20},
            True,
        ),
        AuditFixture(
            "escape_heavy",
            _model_dump(
                tags={
                    f"k{i:03}": (chr(10) + chr(34) + chr(92) + chr(9)) * 12
                    for i in range(128)
                }
            ),
            {
                "tag_count": 128,
                "value_pattern": "newline/quote/backslash/tab repeated 12",
            },
            True,
        ),
        AuditFixture(
            "redaction_expansion",
            _model_dump(tags={f"k{i:03}": "token" for i in range(128)}),
            {"tag_count": 128, "value": "token", "expected_redacted_paths": 128},
            True,
        ),
        AuditFixture(
            "message_4096",
            _model_dump(tags={"kind": "qualification"}, check_output="x" * 4096),
            {"check_output_characters": 4096},
            True,
        ),
    )
    near_body = _model_dump(tags={"kind": "qualification"}, ip_address="x")
    target = BODY_CEILING - 512  # headroom for HTTP's non-compact JSON encoding
    ip_length = target - len(canonical_json_bytes(near_body)) + 1
    near_body["ip_address"] = "x" * ip_length
    assert len(canonical_json_bytes(near_body)) == target
    return (
        *historical,
        *permitted,
        AuditFixture(
            "near_1mib_body",
            near_body,
            {
                "field": "ip_address",
                "ip_address_characters": ip_length,
                "target_canonical_body_bytes": target,
                "body_ceiling_bytes": BODY_CEILING,
            },
            True,
        ),
    )


def _cpu_model() -> str:
    name = platform.processor() or platform.uname().processor
    if name:
        return name
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.startswith(("model name\t:", "Hardware\t:")):
                return line.partition(":")[2].strip()
    except OSError:
        pass
    return "unknown"


def _revision() -> dict[str, object]:
    def git(*args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *args],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )

    try:
        head = git("rev-parse", "HEAD")
        status = git("status", "--porcelain", "--untracked-files=all")
    except OSError, subprocess.TimeoutExpired:
        return {"commit": None, "working_tree": "unknown"}
    if head.returncode or status.returncode:
        return {"commit": None, "working_tree": "unknown"}
    # Do not publish filenames from the checkout in machine-readable evidence.
    return {
        "commit": head.stdout.strip(),
        "working_tree": "dirty" if status.stdout else "clean",
    }


def _percentile_95(values: list[float]) -> float:
    ordered = sorted(values)
    position = 0.95 * (len(ordered) - 1)
    lower = int(position)
    return ordered[lower] + (
        ordered[min(lower + 1, len(ordered) - 1)] - ordered[lower]
    ) * (position - lower)


def qualify() -> dict[str, object]:
    cases = make_corpus()
    outcomes: list[dict[str, object]] = []
    failures: list[str] = []
    medians: dict[tuple[str, int], float] = {}
    for fixture in cases:
        # Normalization and constraint checks are intentionally outside timing.
        if fixture.ingress_permitted:
            Icinga2WebhookPayload.model_validate(fixture.payload)
            validate_event_tags(fixture.payload["tags"])
            assert len(fixture.canonical_bytes) <= BODY_CEILING
        else:
            try:
                validate_event_tags(fixture.payload["tags"])
            except EventTagValidationError:
                pass
            else:
                raise AssertionError("historical map unexpectedly accepted")
        for cap in (DEFAULT_RAW_CAP, MINIMUM_RAW_CAP):
            for _ in range(WARMUP_CALLS):
                redact_payload(fixture.payload, max_bytes=cap, hmac_key=_HMAC_KEY)
            samples_ms: list[float] = []
            result = None
            for _ in range(MEASURED_CALLS):
                started = perf_counter_ns()
                result = redact_payload(
                    fixture.payload, max_bytes=cap, hmac_key=_HMAC_KEY
                )
                samples_ms.append((perf_counter_ns() - started) / 1_000_000)
            assert result is not None
            stored = canonical_json_bytes(result.payload)
            assert result.original_byte_length == len(fixture.canonical_bytes)
            assert result.stored_byte_length == len(stored)
            assert result.stored_byte_length <= min(cap, result.original_byte_length)
            assert result.redaction_version == 2
            median = statistics.median(samples_ms)
            p95 = _percentile_95(samples_ms)
            medians[(fixture.name, cap)] = median
            outcomes.append(
                {
                    "family": fixture.name,
                    "ingress_permitted": fixture.ingress_permitted,
                    "generator_parameters": fixture.parameters,
                    "fixture_sha256": fixture.digest,
                    "tag_count": len(fixture.payload["tags"]),
                    "tag_canonical_bytes": len(
                        canonical_json_bytes(fixture.payload["tags"])
                    ),
                    "body_canonical_bytes": len(fixture.canonical_bytes),
                    "raw_cap_bytes": cap,
                    "warmup_calls": WARMUP_CALLS,
                    "measured_calls": len(samples_ms),
                    "original_bytes": result.original_byte_length,
                    "stored_bytes": result.stored_byte_length,
                    "truncated": result.truncated,
                    "redacted_path_count": result.redacted_path_count,
                    "redaction_version": result.redaction_version,
                    "median_ms": round(median, 4),
                    "p95_ms": round(p95, 4),
                    "max_ms": round(max(samples_ms), 4),
                }
            )
            if p95 > P95_BUDGET_MS:
                failures.append(f"{fixture.name} at {cap} bytes exceeded p95 budget")
    growth = {}
    for cap in (DEFAULT_RAW_CAP, MINIMUM_RAW_CAP):
        first = medians[("historical_reconstructed_5000", cap)]
        second = medians[("historical_reconstructed_10000", cap)]
        ratio = second / max(first, GROWTH_DENOMINATOR_FLOOR_MS)
        growth[str(cap)] = round(ratio, 4)
        if ratio > GROWTH_LIMIT:
            failures.append(
                f"historical 5k-to-10k median growth exceeded at {cap} bytes"
            )
    corpus_digest = hashlib.sha256(
        canonical_json_bytes(
            [[case.name, case.digest, case.parameters] for case in cases]
        )
    ).hexdigest()
    return {
        "schema_version": 1,
        "qualification": "function_only_not_live_http",
        "provenance": {
            "historical_fixture_status": "reconstructed count and byte shapes only; original generator, content, hardware and repetitions unavailable",
            "historical_old_measurements_seconds": HISTORICAL_TIMINGS_SECONDS,
            "old_vs_new_precise_speedup_claim": False,
            "fixture_corpus_sha256": corpus_digest,
        },
        "environment": {
            "cpu": _cpu_model(),
            "os": platform.platform(),
            "python": platform.python_version(),
            "revision": _revision(),
            "default_raw_cap_bytes": DEFAULT_RAW_CAP,
            "minimum_raw_cap_bytes": MINIMUM_RAW_CAP,
            "ingress_body_ceiling_bytes": BODY_CEILING,
        },
        "budget": {
            "p95_ms": P95_BUDGET_MS,
            "growth_limit": GROWTH_LIMIT,
            "growth_denominator_floor_ms": GROWTH_DENOMINATOR_FLOOR_MS,
        },
        "median_growth_5k_to_10k_by_cap": growth,
        "cases": outcomes,
        "passed": not failures,
        "failures": failures,
    }


def main() -> int:
    report = qualify()
    document = json.dumps(report, sort_keys=True, ensure_ascii=False)
    print(document)
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as summary:
            summary.write("\n### Audit redactor function qualification (#7)\n\n")
            summary.write("```json\n" + document + "\n```\n")
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
