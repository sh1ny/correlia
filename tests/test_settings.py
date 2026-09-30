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
        Settings(
            operator_api_token="operator-secret",
            ingress_api_token="ingress-secret",
            audit_raw_payload_hmac_key="audit-secret",
            **kwargs,
        )

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


@pytest.mark.parametrize("source", ["constructor", "environment"])
@pytest.mark.parametrize("api_auth_enabled", [False, True])
@pytest.mark.parametrize("expose_readyz", [False, True])
@pytest.mark.parametrize("expose_metrics", [False, True])
def test_production_auth_and_exposure_policy(
    monkeypatch: pytest.MonkeyPatch,
    source: str,
    api_auth_enabled: bool,
    expose_readyz: bool,
    expose_metrics: bool,
) -> None:
    def construct() -> Settings:
        if source == "environment":
            monkeypatch.setenv("DATABASE_URL", VALID_DATABASE_URL)
            monkeypatch.setenv("CORRELIA_ENVIRONMENT", "production")
            monkeypatch.setenv("CORRELIA_OPERATOR_API_TOKEN", "operator-secret")
            monkeypatch.setenv("CORRELIA_INGRESS_API_TOKEN", "ingress-secret")
            monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "audit-secret")
            monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", str(api_auth_enabled))
            monkeypatch.setenv("CORRELIA_EXPOSE_READYZ", str(expose_readyz))
            monkeypatch.setenv("CORRELIA_EXPOSE_METRICS", str(expose_metrics))
            return Settings()  # type: ignore[call-arg]
        return Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment="production",
            api_auth_enabled=api_auth_enabled,
            expose_readyz=expose_readyz,
            expose_metrics=expose_metrics,
            operator_api_token="operator-secret",
            ingress_api_token="ingress-secret",
            audit_raw_payload_hmac_key="audit-secret",
        )

    if api_auth_enabled and not expose_readyz and not expose_metrics:
        settings = construct()
        assert settings.api_auth_enabled is True
        assert settings.expose_readyz is False
        assert settings.expose_metrics is False
        return

    with pytest.raises(ValidationError) as exc_info:
        construct()
    message = str(exc_info.value)
    assert "production" in message
    for field, unsafe in (
        ("api_auth_enabled", not api_auth_enabled),
        ("expose_readyz", expose_readyz),
        ("expose_metrics", expose_metrics),
    ):
        if unsafe:
            assert field in message


@pytest.mark.parametrize("source", ["constructor", "environment"])
@pytest.mark.parametrize(
    "omitted_fields",
    [
        ("expose_readyz", "expose_metrics"),
        ("expose_readyz",),
        ("expose_metrics",),
    ],
)
def test_production_rejects_omitted_public_exposure_defaults(
    monkeypatch: pytest.MonkeyPatch, source: str, omitted_fields: tuple[str, ...]
) -> None:
    exposure = {
        field: False
        for field in ("expose_readyz", "expose_metrics")
        if field not in omitted_fields
    }
    with pytest.raises(ValidationError) as exc_info:
        if source == "environment":
            monkeypatch.setenv("DATABASE_URL", VALID_DATABASE_URL)
            monkeypatch.setenv("CORRELIA_ENVIRONMENT", "production")
            monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", "true")
            monkeypatch.setenv("CORRELIA_OPERATOR_API_TOKEN", "operator-secret")
            monkeypatch.setenv("CORRELIA_INGRESS_API_TOKEN", "ingress-secret")
            monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "audit-secret")
            for field in omitted_fields:
                monkeypatch.delenv(f"CORRELIA_{field.upper()}", raising=False)
            for field in exposure:
                monkeypatch.setenv(f"CORRELIA_{field.upper()}", "false")
            Settings()  # type: ignore[call-arg]
        else:
            Settings(
                DATABASE_URL=VALID_DATABASE_URL,
                environment="production",
                api_auth_enabled=True,
                operator_api_token="operator-secret",
                ingress_api_token="ingress-secret",
                audit_raw_payload_hmac_key="audit-secret",
                **exposure,
            )
    message = str(exc_info.value)
    for field in omitted_fields:
        assert field in message


@pytest.mark.parametrize("source", ["constructor", "environment"])
@pytest.mark.parametrize("environment", [None, "local", "test"])
@pytest.mark.parametrize("expose_readyz", [False, True])
@pytest.mark.parametrize("expose_metrics", [False, True])
def test_nonproduction_auth_disabled_exposure_combinations(
    monkeypatch: pytest.MonkeyPatch,
    source: str,
    environment: str | None,
    expose_readyz: bool,
    expose_metrics: bool,
) -> None:
    if source == "environment":
        monkeypatch.setenv("DATABASE_URL", VALID_DATABASE_URL)
        monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", "false")
        monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "audit-secret")
        monkeypatch.setenv("CORRELIA_EXPOSE_READYZ", str(expose_readyz))
        monkeypatch.setenv("CORRELIA_EXPOSE_METRICS", str(expose_metrics))
        if environment is not None:
            monkeypatch.setenv("CORRELIA_ENVIRONMENT", environment)
        settings = Settings()  # type: ignore[call-arg]
    else:
        environment_input = {} if environment is None else {"environment": environment}
        settings = Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            api_auth_enabled=False,
            expose_readyz=expose_readyz,
            expose_metrics=expose_metrics,
            audit_raw_payload_hmac_key="audit-secret",
            **environment_input,
        )
    assert settings.environment == (environment or "local")
    assert settings.api_auth_enabled is False
    assert settings.operator_api_token is None
    assert settings.ingress_api_token is None
    assert settings.expose_readyz is expose_readyz
    assert settings.expose_metrics is expose_metrics


@pytest.mark.parametrize("source", ["constructor", "environment"])
@pytest.mark.parametrize("environment", [None, "local", "test"])
def test_nonproduction_keeps_public_exposure_defaults(
    monkeypatch: pytest.MonkeyPatch, source: str, environment: str | None
) -> None:
    if source == "environment":
        monkeypatch.setenv("DATABASE_URL", VALID_DATABASE_URL)
        monkeypatch.setenv("CORRELIA_API_AUTH_ENABLED", "false")
        monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "audit-secret")
        if environment is not None:
            monkeypatch.setenv("CORRELIA_ENVIRONMENT", environment)
        settings = Settings()  # type: ignore[call-arg]
    else:
        environment_input = {} if environment is None else {"environment": environment}
        settings = Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            api_auth_enabled=False,
            audit_raw_payload_hmac_key="audit-secret",
            **environment_input,
        )
    assert settings.environment == (environment or "local")
    assert settings.expose_readyz is True
    assert settings.expose_metrics is True


def test_unknown_environment_from_process_environment_is_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", VALID_DATABASE_URL)
    monkeypatch.setenv("CORRELIA_ENVIRONMENT", "staging")
    monkeypatch.setenv("CORRELIA_OPERATOR_API_TOKEN", "operator-secret")
    monkeypatch.setenv("CORRELIA_INGRESS_API_TOKEN", "ingress-secret")
    monkeypatch.setenv("CORRELIA_AUDIT_RAW_PAYLOAD_HMAC_KEY", "audit-secret")
    with pytest.raises(ValidationError) as exc_info:
        Settings()  # type: ignore[call-arg]
    assert any(
        error["loc"] == ("environment",) and error["type"] == "literal_error"
        for error in exc_info.value.errors()
    )


@pytest.mark.parametrize(
    ("credentials", "expected_fields"),
    [
        (
            {"operator_api_token": None, "ingress_api_token": None},
            ("operator_api_token", "ingress_api_token"),
        ),
        ({"operator_api_token": None}, ("operator_api_token",)),
        ({"ingress_api_token": None}, ("ingress_api_token",)),
        ({"operator_api_token": ""}, ("operator_api_token",)),
        ({"operator_api_token": "   "}, ("operator_api_token",)),
        ({"ingress_api_token": ""}, ("ingress_api_token",)),
        ({"ingress_api_token": "   "}, ("ingress_api_token",)),
        (
            {"operator_api_token": "shared-secret", "ingress_api_token": "shared-secret"},
            ("operator_api_token", "ingress_api_token"),
        ),
        ({"audit_raw_payload_hmac_key": None}, ("audit_raw_payload_hmac_key",)),
        ({"audit_raw_payload_hmac_key": ""}, ("audit_raw_payload_hmac_key",)),
        ({"audit_raw_payload_hmac_key": "   "}, ("audit_raw_payload_hmac_key",)),
        (
            {"audit_raw_payload_hmac_key": "operator-secret"},
            ("audit_raw_payload_hmac_key", "operator_api_token"),
        ),
        (
            {"audit_raw_payload_hmac_key": "ingress-secret"},
            ("audit_raw_payload_hmac_key", "ingress_api_token"),
        ),
    ],
)
def test_safe_production_still_requires_valid_separate_credentials(
    credentials: dict[str, str | None], expected_fields: tuple[str, ...]
) -> None:
    values: dict[str, str | None] = {
        "operator_api_token": "operator-secret",
        "ingress_api_token": "ingress-secret",
        "audit_raw_payload_hmac_key": "audit-secret",
    }
    values.update(credentials)
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment="production",
            api_auth_enabled=True,
            expose_readyz=False,
            expose_metrics=False,
            **{field: value for field, value in values.items() if value is not None},
        )
    message = str(exc_info.value)
    for field in expected_fields:
        assert field in message


@pytest.mark.parametrize(
    ("api_auth_enabled", "expose_readyz", "expose_metrics", "expected_field"),
    [
        (False, False, False, "api_auth_enabled"),
        (True, True, False, "expose_readyz"),
        (True, False, True, "expose_metrics"),
    ],
)
def test_production_policy_diagnostics_hide_supplied_secrets(
    api_auth_enabled: bool,
    expose_readyz: bool,
    expose_metrics: bool,
    expected_field: str,
) -> None:
    database_secret = "disposable-database-sentinel"
    operator_secret = "disposable-operator-sentinel"
    ingress_secret = "disposable-ingress-sentinel"
    audit_secret = "disposable-audit-sentinel"
    database_url = f"postgresql+asyncpg://user:{database_secret}@localhost:5432/correlia"
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=database_url,
            environment="production",
            api_auth_enabled=api_auth_enabled,
            expose_readyz=expose_readyz,
            expose_metrics=expose_metrics,
            operator_api_token=operator_secret,
            ingress_api_token=ingress_secret,
            audit_raw_payload_hmac_key=audit_secret,
        )
    message = str(exc_info.value)
    assert "production" in message
    assert expected_field in message
    for sentinel in (
        database_url,
        database_secret,
        operator_secret,
        ingress_secret,
        audit_secret,
    ):
        assert sentinel not in message


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
    assert "operator_api_token" in message
    assert "ingress_api_token" in message


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
    with pytest.raises(ValidationError) as exc_info:
        Settings(
            DATABASE_URL=VALID_DATABASE_URL,
            environment=environment,  # type: ignore[arg-type]
            expose_readyz=False,
            expose_metrics=False,
            audit_raw_payload_hmac_key="audit-secret",
        )
    message = str(exc_info.value)
    assert "operator_api_token" in message
    assert "ingress_api_token" in message


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
