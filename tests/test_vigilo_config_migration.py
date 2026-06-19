from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest
import yaml

# Import helper functions from the migration script for narrowly focused
# transform assertions.  The script arranges for app.* imports to work.
from scripts.migrate_vigilo_config import (
    UNSUPPORTED_FIELD_CATALOG_CODES,
    _promote,
    _rewrite_group_by,
    _rewrite_match_tags,
    _rewrite_summary,
    _to_correlia_tag_key,
    _transform_plugins,
    _transform_rules,
    _transform_topology,
)
import scripts.migrate_vigilo_config

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "vigilo"
SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "migrate_vigilo_config.py"


def _fixture_path(name: str) -> Path:
    return FIXTURES / name


def _run_cli(
    *,
    rules: str | None = None,
    topology: str | None = None,
    plugins: str | None = None,
    out_dir: str | None = None,
    report_path: str | None = None,
    extra_args: list[str] | None = None,
) -> subprocess.CompletedProcess[str]:
    args = [sys.executable, str(SCRIPT)]
    if rules is not None:
        args.extend(["--rules", rules])
    if topology is not None:
        args.extend(["--topology", topology])
    if plugins is not None:
        args.extend(["--plugins", plugins])
    if out_dir is not None:
        args.extend(["--out-dir", out_dir])
    if report_path is not None:
        args.extend(["--report-path", report_path])
    if extra_args:
        args.extend(extra_args)
    return subprocess.run(args, capture_output=True, text=True)


# ---------------------------------------------------------------------------
# Valid migration behavior
# ---------------------------------------------------------------------------


def test_cli_generates_files(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"
    report_path = tmp_path / "report.json"
    result = _run_cli(
        rules=str(_fixture_path("rules_valid.yaml")),
        topology=str(_fixture_path("topology_valid.yaml")),
        plugins=str(_fixture_path("plugins_valid.yaml")),
        out_dir=str(out_dir),
        report_path=str(report_path),
    )
    assert result.returncode == 0, result.stderr
    assert (out_dir / "rules.yaml").exists()
    assert (out_dir / "topology.yaml").exists()
    assert (out_dir / "plugins.yaml").exists()
    report = json.loads(report_path.read_text())
    assert report["ok"] is True
    assert report["errors"] == []
    assert report["generated"] == {
        "rules": str(out_dir / "rules.yaml"),
        "topology": str(out_dir / "topology.yaml"),
        "plugins": str(out_dir / "plugins.yaml"),
    }


def test_migrate_rules() -> None:
    raw = yaml.safe_load(_fixture_path("rules_valid.yaml").read_text())
    migrated = _transform_rules(raw["rules"])
    rules = migrated["rules"]
    assert len(rules) == 3

    # Vigilo higher-first priority is inverted to Correlia ascending ranks.
    assert rules[0]["name"] == "DC-Level Outage Aggregator"
    assert rules[0]["priority"] == 1
    assert rules[1]["name"] == "Host Alert Aggregator"
    assert rules[1]["priority"] == 2
    assert rules[2]["name"] == "Service Event Tracker"
    assert rules[2]["priority"] == 3

    # match.severity is renamed to match.severities.
    assert rules[0]["match"]["severities"] == ["CRITICAL", "WARNING"]
    assert "severity" not in rules[0]["match"]

    # Host/service fnmatch patterns are translated to anchored regex.
    assert re.compile(rules[0]["match"]["host_pattern"]).match("web-01")
    assert rules[2]["match"]["service_pattern"] is not None
    assert re.compile(rules[2]["match"]["service_pattern"]).match("http")

    # Action strings become objects with create_incident name.
    assert rules[0]["actions"] == [{"name": "create_incident", "plugin": "email-ops"}]

    # Summary placeholders are rewritten.
    assert rules[0]["output_summary"] == "Major outage detected in Datacenter {topology.datacenter}"


def test_migrate_rules_prefixes_match_tags_keys() -> None:
    raw = yaml.safe_load(_fixture_path("rules_valid.yaml").read_text())
    migrated = _transform_rules(raw["rules"])
    rule = migrated["rules"][0]
    assert rule["match"]["tags"] == {
        "topology.datacenter": ".+",
        "topology.environment": "production",
    }


def test_migrate_rules_prefixes_group_by_topology_keys() -> None:
    raw = yaml.safe_load(_fixture_path("rules_valid.yaml").read_text())
    migrated = _transform_rules(raw["rules"])
    rule = migrated["rules"][0]
    assert "topology.datacenter" in rule["window"]["group_by"]


def test_migrate_rules_accepts_known_normalized_group_by_fields() -> None:
    raw = yaml.safe_load(_fixture_path("rules_valid.yaml").read_text())
    migrated = _transform_rules(raw["rules"])
    rule = migrated["rules"][0]
    assert "host" in rule["window"]["group_by"]


def test_migrate_topology() -> None:
    raw = yaml.safe_load(_fixture_path("topology_valid.yaml").read_text())
    migrated = _transform_topology(raw["topology_rules"])

    hostname_rules = migrated["hostname_rules"]
    subnet_rules = migrated["subnet_rules"]

    # Capture-group hostname rules emit tag_capture_groups.
    assert hostname_rules[0]["tag_capture_groups"] == {"topology.datacenter": 1}
    assert hostname_rules[0]["tags"] == {}

    # Literal-only hostname rules preserve tags and omit tag_capture_groups.
    literal_rule = hostname_rules[2]
    assert literal_rule["tags"] == {
        "topology.environment": "production",
        "topology.role": "web",
    }
    assert "tag_capture_groups" not in literal_rule

    # Subnet rules emit literal tags only.
    assert subnet_rules[0]["tags"] == {"topology.datacenter": "prm1"}
    assert "tag_capture_groups" not in subnet_rules[0]


def test_migrate_email_plugin() -> None:
    raw = yaml.safe_load(_fixture_path("plugins_valid.yaml").read_text())
    migrated = _transform_plugins(raw)
    outputs = migrated["outputs"]
    assert len(outputs) == 1
    out = outputs[0]
    assert out["name"] == "email-ops"
    assert out["plugin_type"] == "email"
    assert out["class_path"] == "app.plugins.outputs.email.SmtpOutputPlugin"
    assert out["options"]["host"] == "smtp.example.com"
    assert out["options"]["port"] == 587
    assert out["options"]["from_address"] == "vigilo@example.com"
    assert out["options"]["to_addresses"] == ["ops@example.com"]
    assert out["options"]["subject_prefix"] == "[Correlia]"
    assert out["options"]["start_tls"] is True


def test_transform_plugins_rejects_placeholder_in_allowed_options() -> None:
    raw = yaml.safe_load(_fixture_path("plugins_valid.yaml").read_text())
    raw["outputs"]["email-ops"]["config"]["use_tls"] = {"env": "TLS"}
    with pytest.raises(ValueError, match="unsupported placeholder syntax"):
        _transform_plugins(raw)


# ---------------------------------------------------------------------------
# Transform helpers
# ---------------------------------------------------------------------------


def test_to_correlia_tag_key_prefixes_valid_bare_keys() -> None:
    assert _to_correlia_tag_key("datacenter") == "topology.datacenter"
    assert _to_correlia_tag_key("already.prefixed") == "topology.already.prefixed"


def test_to_correlia_tag_key_rejects_invalid_keys() -> None:
    assert _to_correlia_tag_key("Bad Key") is None
    assert _to_correlia_tag_key("") is None


def test_rewrite_match_tags_prefixes_and_rejects() -> None:
    prefixed, issues = _rewrite_match_tags({"datacenter": ".+", "Bad Key": "x"})
    assert prefixed == {"topology.datacenter": ".+"}
    assert len(issues) == 1
    assert issues[0].code == "invalid_topology_tag_key"


def test_rewrite_summary_rewrites_bare_topology_placeholders() -> None:
    rewritten, issues = _rewrite_summary("Outage in {datacenter}")
    assert rewritten == "Outage in {topology.datacenter}"
    assert issues == []


def test_rewrite_summary_preserves_normalized_fields() -> None:
    rewritten, issues = _rewrite_summary("Alert on {host}")
    assert rewritten == "Alert on {host}"
    assert issues == []


def test_rewrite_group_by_preserves_normalized_fields() -> None:
    rewritten, issues = _rewrite_group_by(["host", "service"])
    assert rewritten == ["host", "service"]
    assert issues == []


def test_rewrite_group_by_prefixes_topology_keys() -> None:
    rewritten, issues = _rewrite_group_by(["datacenter"])
    assert rewritten == ["topology.datacenter"]
    assert issues == []


def test_rewrite_group_by_rejects_rule_name() -> None:
    rewritten, issues = _rewrite_group_by(["rule_name"])
    assert rewritten == []
    assert len(issues) == 1
    assert issues[0].code == "unsupported_group_by"


# ---------------------------------------------------------------------------
# Unsupported-field catalog
# ---------------------------------------------------------------------------

UNSUPPORTED_FIELD_CASES: list[tuple[str, str, str]] = [
    ("rules_min_hosts.yaml", "unsupported_rule_min_hosts", "CFG-06"),
    ("rules_is_dc_level.yaml", "unsupported_rule_is_dc_level", "CFG-06"),
    ("rules_missing_severity.yaml", "invalid_rule_severity", "CFG-06"),
    ("rules_non_list_severity.yaml", "invalid_rule_severity", "CFG-06"),
    ("rules_empty_severity.yaml", "invalid_rule_severity", "CFG-06"),
    ("rules_missing_priority.yaml", "invalid_rule_priority", "CFG-06"),
    ("rules_non_int_priority.yaml", "invalid_rule_priority", "CFG-06"),
    ("rules_duplicate_priority.yaml", "duplicate_rule_priority", "CFG-06"),
    ("rules_empty_actions.yaml", "empty_actions", "CFG-06"),
    ("rules_non_string_action.yaml", "invalid_action_entry", "CFG-06"),
    ("rules_with_wildcard_star.yaml", "unsupported_tag_wildcard", "CFG-06"),
    ("rules_with_wildcard_question.yaml", "unsupported_tag_wildcard", "CFG-06"),
    ("rules_with_wildcard_bracket_open.yaml", "unsupported_tag_wildcard", "CFG-06"),
    ("rules_with_wildcard_bracket_close.yaml", "unsupported_tag_wildcard", "CFG-06"),
    ("rules_with_bad_tag_key.yaml", "invalid_topology_tag_key", "CFG-06"),
    ("rules_with_bad_group_by.yaml", "unsupported_group_by", "CFG-06"),
    ("rules_with_rule_name_group_by.yaml", "unsupported_group_by", "CFG-06"),
    ("rules_with_bad_summary_placeholder.yaml", "unsupported_summary_placeholder", "CFG-06"),
    ("topology_capture_group_missing_target.yaml", "missing_topology_target_tag", "CFG-06"),
    ("topology_hostname_missing_tags.yaml", "unsupported_hostname_topology", "CFG-06"),
    ("topology_subnet_missing_cidr.yaml", "missing_subnet_field", "CFG-06"),
    ("topology_subnet_missing_value.yaml", "missing_subnet_field", "CFG-06"),
    ("topology_subnet_missing_target_tag.yaml", "missing_subnet_field", "CFG-06"),
    ("topology_bad_tag_name.yaml", "invalid_topology_tag_key", "CFG-06"),
    ("plugins_with_task_runner_section.yaml", "unsupported_plugin_section", "CFG-06"),
    ("plugins_with_inputs_section.yaml", "unsupported_plugin_section", "CFG-06"),
    ("plugins_with_llm_section.yaml", "unsupported_plugin_section", "CFG-06"),
    ("plugins_with_enrichers_section.yaml", "unsupported_plugin_section", "CFG-06"),
    ("plugins_with_processor_section.yaml", "unsupported_plugin_section", "CFG-06"),
    ("plugins_with_non_email_output.yaml", "unsupported_plugin_type", "CFG-06"),
    ("plugins_with_unmappable_class_path.yaml", "unsupported_plugin_class", "CFG-06"),
    ("plugins_with_smtp_username.yaml", "plaintext_smtp_credentials", "CFG-06"),
    ("plugins_with_smtp_password.yaml", "plaintext_smtp_credentials", "CFG-06"),
    ("plugins_with_username_credential.yaml", "plaintext_smtp_credentials", "CFG-06"),
    ("plugins_with_password_credential.yaml", "plaintext_smtp_credentials", "CFG-06"),
    ("plugins_with_credentials.yaml", "plaintext_smtp_credentials", "CFG-06"),
    ("plugins_with_unknown_email_option.yaml", "unsupported_plugin_option", "CFG-06"),
    ("plugins_with_placeholder_option.yaml", "unsupported_plugin_option", "CFG-06"),
    ("plugins_with_unknown_section.yaml", "unsupported_plugin_section", "CFG-06"),
]


def _run_migration_expect_issue(
    *,
    rules: str = "rules_valid.yaml",
    topology: str = "topology_valid.yaml",
    plugins: str = "plugins_valid.yaml",
    expected_code: str,
    expected_requirement: str,
    tmp_path: Path,
) -> dict[str, Any]:
    out_dir = tmp_path / "out"
    report_path = tmp_path / "report.json"
    result = _run_cli(
        rules=str(_fixture_path(rules)),
        topology=str(_fixture_path(topology)),
        plugins=str(_fixture_path(plugins)),
        out_dir=str(out_dir),
        report_path=str(report_path),
    )
    assert result.returncode != 0, result.stdout
    assert not (out_dir / "rules.yaml").exists()
    report = json.loads(report_path.read_text())
    assert report["ok"] is False
    assert report["generated"] is None
    matching = [e for e in report["errors"] if e["code"] == expected_code]
    assert matching, f"expected code {expected_code} in {report['errors']}"
    assert all(e["requirement"] == expected_requirement for e in matching)
    return report


@pytest.mark.parametrize("fixture, code, requirement", UNSUPPORTED_FIELD_CASES)
def test_unsupported_fields_fail(
    fixture: str, code: str, requirement: str, tmp_path: Path
) -> None:
    domain = fixture.split("_", 1)[0]
    kwargs: dict[str, str] = {
        "rules": "rules_valid.yaml",
        "topology": "topology_valid.yaml",
        "plugins": "plugins_valid.yaml",
    }
    if domain == "rules":
        kwargs["rules"] = fixture
    elif domain == "topology":
        kwargs["topology"] = fixture
    elif domain == "plugins":
        kwargs["plugins"] = fixture
    else:
        raise AssertionError(f"unknown fixture domain: {domain}")
    _run_migration_expect_issue(
        **kwargs, expected_code=code, expected_requirement=requirement, tmp_path=tmp_path
    )


def test_unsupported_field_catalog_table_complete() -> None:
    expected_codes = {
        code for _fixture, code, _requirement in UNSUPPORTED_FIELD_CASES
    }
    missing = expected_codes - UNSUPPORTED_FIELD_CATALOG_CODES
    assert not missing, f"catalog codes missing from script: {missing}"


def test_action_plugin_must_exist_in_outputs(tmp_path: Path) -> None:
    report = _run_migration_expect_issue(
        rules="rules_valid.yaml",
        topology="topology_valid.yaml",
        plugins="plugins_with_no_outputs.yaml",
        expected_code="unknown_action_plugin",
        expected_requirement="CFG-06",
        tmp_path=tmp_path,
    )
    errors = [e for e in report["errors"] if e["code"] == "unknown_action_plugin"]
    assert any("email-ops" in e["message"] for e in errors)

def test_plugin_option_placeholders_fail_before_output(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"
    report_path = tmp_path / "report.json"
    result = _run_cli(
        rules=str(_fixture_path("rules_valid.yaml")),
        topology=str(_fixture_path("topology_valid.yaml")),
        plugins=str(_fixture_path("plugins_with_placeholder_option.yaml")),
        out_dir=str(out_dir),
        report_path=str(report_path),
    )
    assert result.returncode != 0, result.stdout
    report = json.loads(report_path.read_text())
    assert report["ok"] is False
    assert report["generated"] is None
    assert not (out_dir / "plugins.yaml").exists()
    errors = [e for e in report["errors"] if e["code"] == "unsupported_plugin_option"]
    assert len(errors) >= 4, f"expected at least four unsupported_plugin_option errors, got {errors}"
    assert all(e["requirement"] == "CFG-06" for e in errors)
    locations = {e["location"] for e in errors}
    assert any("config.smtp_host" in loc for loc in locations)
    assert any("config.from_address" in loc for loc in locations)
    assert any("config.to_addresses[1]" in loc for loc in locations)
    assert any("config.subject_prefix" in loc for loc in locations)

# ---------------------------------------------------------------------------
# Multi-input aggregation
# ---------------------------------------------------------------------------


def test_report_aggregates_issues_across_inputs_and_domains(tmp_path: Path) -> None:
    report = _run_migration_expect_issue(
        rules="rules_min_hosts.yaml",
        topology="topology_subnet_missing_cidr.yaml",
        plugins="plugins_with_smtp_username.yaml",
        expected_code="unsupported_rule_min_hosts",
        expected_requirement="CFG-06",
        tmp_path=tmp_path,
    )
    codes = {e["code"] for e in report["errors"]}
    assert "unsupported_rule_min_hosts" in codes
    assert "missing_subnet_field" in codes
    assert "plaintext_smtp_credentials" in codes
    domains = {e["domain"] for e in report["errors"]}
    assert domains >= {"rules", "topology", "plugins"}


# ---------------------------------------------------------------------------
# Invalid input paths
# ---------------------------------------------------------------------------

INVALID_INPUT_PATH_CASES: list[tuple[str, str, str]] = [
    ("rules", "directory", "rules_directory"),
    ("rules", "glob", "rules_glob"),
    ("rules", "missing", "rules_missing"),
    ("rules", "non_yaml", "rules_non_yaml"),
    ("topology", "directory", "topology_directory"),
    ("topology", "glob", "topology_glob"),
    ("topology", "missing", "topology_missing"),
    ("topology", "non_yaml", "topology_non_yaml"),
    ("plugins", "directory", "plugins_directory"),
    ("plugins", "glob", "plugins_glob"),
    ("plugins", "missing", "plugins_missing"),
    ("plugins", "non_yaml", "plugins_non_yaml"),
]


def _build_bad_path(tmp_path: Path, flag: str, shape: str) -> str:
    if shape == "directory":
        d = tmp_path / f"{flag}_dir"
        d.mkdir()
        return str(d)
    if shape == "glob":
        return str(tmp_path / f"{flag}*.yaml")
    if shape == "missing":
        return str(tmp_path / f"{flag}_missing.yaml")
    if shape == "non_yaml":
        p = tmp_path / f"{flag}.txt"
        p.write_text("not yaml")
        return str(p)
    raise ValueError(shape)


@pytest.mark.parametrize("flag, shape, _case", INVALID_INPUT_PATH_CASES)
def test_invalid_input_paths_fail_before_output(
    flag: str, shape: str, _case: str, tmp_path: Path
) -> None:
    bad_path = _build_bad_path(tmp_path, flag, shape)
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    report_path = tmp_path / "report.json"
    kwargs: dict[str, str] = {
        "rules": str(_fixture_path("rules_valid.yaml")),
        "topology": str(_fixture_path("topology_valid.yaml")),
        "plugins": str(_fixture_path("plugins_valid.yaml")),
        "out_dir": str(out_dir),
        "report_path": str(report_path),
    }
    kwargs[f"{flag}"] = bad_path
    result = _run_cli(**kwargs)
    assert result.returncode != 0, result.stdout
    report = json.loads(report_path.read_text())
    assert report["ok"] is False
    assert report["generated"] is None
    matching = [e for e in report["errors"] if e["code"] == "invalid_input_path"]
    assert matching, f"expected invalid_input_path in {report['errors']}"
    assert all(e["requirement"] == "CFG-06" for e in matching)
    assert any(flag in e["location"] for e in matching)
    # No partial output should be promoted.
    assert not list(out_dir.iterdir())


# ---------------------------------------------------------------------------
# Duplicate flags and report shape
# ---------------------------------------------------------------------------


def test_duplicate_single_path_flags_fail_before_output(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    report_path = tmp_path / "report.json"
    result = _run_cli(
        rules=str(_fixture_path("rules_valid.yaml")),
        topology=str(_fixture_path("topology_valid.yaml")),
        plugins=str(_fixture_path("plugins_valid.yaml")),
        out_dir=str(out_dir),
        report_path=str(report_path),
        extra_args=["--rules", str(_fixture_path("rules_valid.yaml"))],
    )
    assert result.returncode != 0, result.stdout
    report = json.loads(report_path.read_text())
    assert report["ok"] is False
    assert report["generated"] is None
    assert any(e["code"] == "duplicate_flag" for e in report["errors"])
    assert not list(out_dir.iterdir())


def test_report_shape(tmp_path: Path) -> None:
    report = _run_migration_expect_issue(
        rules="rules_empty_actions.yaml",
        expected_code="empty_actions",
        expected_requirement="CFG-06",
        tmp_path=tmp_path,
    )
    assert set(report.keys()) == {"ok", "errors", "generated"}
    for error in report["errors"]:
        assert set(error.keys()) >= {"domain", "location", "code", "message", "requirement"}
        assert error["code"]
        assert error["requirement"]


# ---------------------------------------------------------------------------
# Loader round-trip and atomic failure
# ---------------------------------------------------------------------------


def test_generated_files_load_and_instantiate(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"
    result = _run_cli(
        rules=str(_fixture_path("rules_valid.yaml")),
        topology=str(_fixture_path("topology_valid.yaml")),
        plugins=str(_fixture_path("plugins_valid.yaml")),
        out_dir=str(out_dir),
    )
    assert result.returncode == 0, result.stderr

    from app.config.plugins import load_plugin_registry_config
    from app.config.rules import load_rules_config
    from app.config.topology import load_topology_config
    from app.plugins.loader import load_plugin_registry

    load_plugin_registry_config(out_dir / "plugins.yaml")
    plugin_registry = load_plugin_registry(out_dir / "plugins.yaml")
    assert plugin_registry.names == ("email-ops",)

    rules_config = load_rules_config(
        out_dir / "rules.yaml",
        known_plugins=frozenset(plugin_registry.names),
    )
    assert len(rules_config.rules) == 3

    topology_config = load_topology_config(out_dir / "topology.yaml")
    assert len(topology_config.hostname_rules) == 3
    assert len(topology_config.subnet_rules) == 3


def test_validation_failure_leaves_existing_out_dir_untouched(tmp_path: Path) -> None:
    out_dir = tmp_path / "out"
    out_dir.mkdir()
    existing = out_dir / "existing.txt"
    existing.write_text("preserve me")
    result = _run_cli(
        rules=str(_fixture_path("rules_empty_actions.yaml")),
        topology=str(_fixture_path("topology_valid.yaml")),
        plugins=str(_fixture_path("plugins_valid.yaml")),
        out_dir=str(out_dir),
    )
    assert result.returncode != 0
    assert existing.read_text() == "preserve me"
    assert not (out_dir / "rules.yaml").exists()

def test_promote_rolls_back_new_files_on_mid_promotion_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    staging = tmp_path / "staging"
    staging.mkdir()
    (staging / "rules.yaml").write_text("rules: []")
    (staging / "topology.yaml").write_text("hostname_rules: []\nsubnet_rules: []")
    (staging / "plugins.yaml").write_text("outputs: []")
    out_dir = tmp_path / "out"
    out_dir.mkdir()

    real_replace = scripts.migrate_vigilo_config.os.replace
    call_count = 0

    def fake_replace(src: str, dst: str) -> None:
        nonlocal call_count
        call_count += 1
        if call_count > 1:
            raise OSError("simulated mid-promotion failure")
        real_replace(src, dst)

    monkeypatch.setattr(
        scripts.migrate_vigilo_config.os, "replace", fake_replace
    )

    with pytest.raises(OSError):
        _promote(staging, out_dir)

    assert not (out_dir / "rules.yaml").exists()
    assert not (out_dir / "topology.yaml").exists()
    assert not (out_dir / "plugins.yaml").exists()

def test_promote_does_not_create_out_dir_on_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    staging = tmp_path / "staging"
    staging.mkdir()
    (staging / "rules.yaml").write_text("rules: []")
    (staging / "topology.yaml").write_text("hostname_rules: []\nsubnet_rules: []")
    (staging / "plugins.yaml").write_text("outputs: []")
    out_dir = tmp_path / "out"
    assert not out_dir.exists()

    def fake_replace(src: str, dst: str) -> None:
        raise OSError("simulated first-promotion failure")

    monkeypatch.setattr(
        scripts.migrate_vigilo_config.os, "replace", fake_replace
    )

    with pytest.raises(OSError):
        _promote(staging, out_dir)

    assert not out_dir.exists()


def test_promote_removes_new_out_dir_on_mkdtemp_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Regression for the narrow D-14 path where tempfile.mkdtemp raises after
    _promote creates a missing --out-dir.
    """
    staging = tmp_path / "staging"
    staging.mkdir()
    (staging / "rules.yaml").write_text("rules: []")
    (staging / "topology.yaml").write_text("hostname_rules: []\nsubnet_rules: []")
    (staging / "plugins.yaml").write_text("outputs: []")
    out_dir = tmp_path / "out"
    assert not out_dir.exists()

    def fake_mkdtemp(*args: Any, **kwargs: Any) -> str:
        raise OSError("simulated mkdtemp failure")

    monkeypatch.setattr(
        scripts.migrate_vigilo_config.tempfile, "mkdtemp", fake_mkdtemp
    )

    with pytest.raises(OSError):
        _promote(staging, out_dir)

    assert not out_dir.exists()
