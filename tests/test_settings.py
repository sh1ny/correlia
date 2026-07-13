from pathlib import Path

import pytest
from pydantic import ValidationError
from sqlalchemy.sql.elements import TextClause

from app.config.settings import Settings
from app.persistence.database import check_database_ready


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


def test_valid_database_url_and_defaults() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="operator",
        ingress_api_token="ingress",
        audit_raw_payload_hmac_key="audit-secret",
    )

    assert str(settings.database_url).startswith(VALID_DATABASE_URL)
    assert settings.environment == "local"
    assert settings.log_level == "INFO"
    assert settings.rules_path is None
    assert settings.topology_path is None
    assert settings.plugins_path is None


def test_settings_model_config_contract() -> None:
    assert Settings.model_config["extra"] == "forbid"
    assert Settings.model_config["env_prefix"] == "CORRELIA_"
    assert Settings.model_fields["database_url"].validation_alias == "DATABASE_URL"


@pytest.mark.parametrize(
    ("kwargs", "expected_error"),
    [
        ({}, "missing"),
        ({"DATABASE_URL": "not-a-postgres-url"}, "url_parsing"),
        (
            {"DATABASE_URL": VALID_DATABASE_URL, "environment": "staging"},
            "literal_error",
        ),
        ({"DATABASE_URL": VALID_DATABASE_URL, "log_level": "TRACE"}, "literal_error"),
        (
            {"DATABASE_URL": VALID_DATABASE_URL, "unexpected": "value"},
            "extra_forbidden",
        ),
    ],
)
def test_invalid_settings_raise_explicit_validation_errors(
    kwargs: dict[str, str], expected_error: str
) -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(**kwargs)

    error_types = {error["type"] for error in exc_info.value.errors()}
    assert expected_error in error_types


class RecordingSession:
    def __init__(self) -> None:
        self.executed_sql: list[str] = []

    async def __aenter__(self) -> "RecordingSession":
        return self

    async def __aexit__(self, exc_type: object, exc: object, tb: object) -> None:
        return None

    async def execute(self, statement: TextClause) -> None:
        self.executed_sql.append(statement.text)


async def test_check_database_ready_executes_fixed_select_one() -> None:
    session = RecordingSession()

    def sessionmaker() -> RecordingSession:
        return session

    await check_database_ready(sessionmaker)  # type: ignore[arg-type]

    assert session.executed_sql == ["select 1"]


class FailingSession:
    def __init__(self, failure: RuntimeError) -> None:
        self.failure = failure

    async def __aenter__(self) -> "FailingSession":
        return self

    async def __aexit__(self, exc_type: object, exc: object, tb: object) -> None:
        return None

    async def execute(self, statement: TextClause) -> None:
        raise self.failure


async def test_check_database_ready_raises_original_connectivity_failure() -> None:
    failure = RuntimeError("database unavailable")

    def sessionmaker() -> FailingSession:
        return FailingSession(failure)

    with pytest.raises(RuntimeError) as exc_info:
        await check_database_ready(sessionmaker)  # type: ignore[arg-type]

    assert exc_info.value is failure


def test_makefile_targets_are_uv_wrappers() -> None:
    makefile = Path("Makefile").read_text()

    for target in ("test", "lint", "typecheck", "run"):
        marker = f"{target}:\n\tuv run "
        assert marker in makefile


# Phase 5 security-settings tests


def test_auth_enabled_requires_both_tokens() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL, audit_raw_payload_hmac_key="audit-secret"
        )
    errors = exc_info.value.errors()
    assert any(err["type"] == "value_error" for err in errors)
    message = " ".join(str(err.get("msg", "")) for err in errors)
    assert "operator_api_token" in message
    assert "ingress_api_token" in message


def test_auth_enabled_requires_non_empty_tokens() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="",
            ingress_api_token="",
            audit_raw_payload_hmac_key="audit-secret",
        )
    errors = exc_info.value.errors()
    assert any(err["type"] == "value_error" for err in errors)


def test_auth_enabled_requires_distinct_operator_and_ingress_tokens() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="shared-secret",
            ingress_api_token="shared-secret",
            audit_raw_payload_hmac_key="audit-secret",
        )
    message = " ".join(str(err.get("msg", "")) for err in exc_info.value.errors())
    assert "distinct operator_api_token and ingress_api_token" in message


def test_tokens_stored_as_secret_str() -> None:
    from pydantic import SecretStr

    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="operator-secret",
        ingress_api_token="ingress-secret",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert isinstance(settings.operator_api_token, SecretStr)
    assert settings.operator_api_token.get_secret_value() == "operator-secret"
    assert settings.ingress_api_token.get_secret_value() == "ingress-secret"


@pytest.mark.parametrize("environment", ["local", "test", "production"])
def test_token_validation_has_no_environment_bypass(environment: str) -> None:
    with pytest.raises(ValidationError):
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment=environment,  # type: ignore[arg-type]
            audit_raw_payload_hmac_key="audit-secret",
        )


def test_auth_can_be_disabled_without_tokens() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        api_auth_enabled=False,
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert settings.operator_api_token is None
    assert settings.ingress_api_token is None


def test_default_max_body_bytes_is_one_mebibyte() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="op",
        ingress_api_token="in",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert settings.max_body_bytes == 1_048_576


def test_route_class_rate_limit_defaults() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="op",
        ingress_api_token="in",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert settings.rate_limit_enabled is True
    assert settings.rate_limit_requests_operator == 60
    assert settings.rate_limit_window_seconds_operator == 60
    assert settings.rate_limit_requests_ingress == 120
    assert settings.rate_limit_window_seconds_ingress == 60
    assert settings.rate_limit_requests_metrics == 30
    assert settings.rate_limit_window_seconds_metrics == 60
    assert settings.rate_limit_requests_readyz == 60
    assert settings.rate_limit_window_seconds_readyz == 60
    assert settings.rate_limit_requests_health == 120
    assert settings.rate_limit_window_seconds_health == 60
    assert settings.rate_limit_sweep_interval_seconds == 60


def test_settings_env_keys_cover_security_fields() -> None:
    from tests.conftest import _SETTINGS_ENV_KEYS

    expected_prefixes = {
        "CORRELIA_API_AUTH_ENABLED",
        "CORRELIA_OPERATOR_API_TOKEN",
        "CORRELIA_INGRESS_API_TOKEN",
        "CORRELIA_EXPOSE_READYZ",
        "CORRELIA_EXPOSE_METRICS",
        "CORRELIA_MIGRATION_REPORT_PATH",
        "CORRELIA_MAX_BODY_BYTES",
        "CORRELIA_RATE_LIMIT_ENABLED",
        "CORRELIA_RATE_LIMIT_REQUESTS_OPERATOR",
        "CORRELIA_RATE_LIMIT_SWEEP_INTERVAL_SECONDS",
    }
    assert expected_prefixes.issubset(set(_SETTINGS_ENV_KEYS))


# Phase 7 audit-settings tests


def test_audit_hmac_key_is_required() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="operator-secret",
            ingress_api_token="ingress-secret",
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message


def test_audit_hmac_key_is_required_even_when_auth_disabled() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            api_auth_enabled=False,
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message


def test_audit_hmac_key_must_be_non_empty() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="operator-secret",
            ingress_api_token="ingress-secret",
            audit_raw_payload_hmac_key="   ",
        )
    errors = exc_info.value.errors()
    assert any(err["type"] == "value_error" for err in errors)


def test_audit_hmac_key_must_differ_from_operator_token() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="shared-secret",
            ingress_api_token="ingress-secret",
            audit_raw_payload_hmac_key="shared-secret",
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message


def test_audit_hmac_key_must_differ_from_ingress_token() -> None:
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            operator_api_token="operator-secret",
            ingress_api_token="shared-secret",
            audit_raw_payload_hmac_key="shared-secret",
        )
    message = str(exc_info.value)
    assert "audit_raw_payload_hmac_key" in message


def test_audit_hmac_key_stored_as_secret_str() -> None:
    from pydantic import SecretStr

    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="operator-secret",
        ingress_api_token="ingress-secret",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert isinstance(settings.audit_raw_payload_hmac_key, SecretStr)
    assert settings.audit_raw_payload_hmac_key.get_secret_value() == "audit-secret"


def test_audit_raw_payload_max_bytes_default() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="operator-secret",
        ingress_api_token="ingress-secret",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert settings.audit_raw_payload_max_bytes == 65_536


def test_audit_raw_payload_max_bytes_bounds() -> None:
    for bad in (0, 1_023, 1_048_577):
        with pytest.raises(ValidationError):
            Settings(
                DATABASE_URL=VALID_DATABASE_URL,
                operator_api_token="operator-secret",
                ingress_api_token="ingress-secret",
                audit_raw_payload_hmac_key="audit-secret",
                audit_raw_payload_max_bytes=bad,
            )


def test_audit_env_keys_covered_by_conftest_cleanup() -> None:
    from tests.conftest import _SETTINGS_ENV_KEYS

    assert "CORRELIA_AUDIT_RAW_PAYLOAD_MAX_BYTES" in _SETTINGS_ENV_KEYS
    assert "CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY" in _SETTINGS_ENV_KEYS


def test_migration_report_projection_is_disabled_when_path_is_unset() -> None:
    settings = Settings(
        DATABASE_URL=VALID_DATABASE_URL,
        operator_api_token="operator",
        ingress_api_token="ingress",
        audit_raw_payload_hmac_key="audit-secret",
    )
    assert settings.migration_report_path is None
