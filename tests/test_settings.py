from pathlib import Path

import pytest
from pydantic import ValidationError
from sqlalchemy.sql.elements import TextClause

from app.config.settings import Settings
from app.persistence.database import check_database_ready


VALID_DATABASE_URL = "postgresql+asyncpg://user:pass@localhost:5432/correlia"


def test_valid_database_url_and_defaults() -> None:
    settings = Settings(DATABASE_URL=VALID_DATABASE_URL)

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
        ({"DATABASE_URL": VALID_DATABASE_URL, "environment": "staging"}, "literal_error"),
        ({"DATABASE_URL": VALID_DATABASE_URL, "log_level": "TRACE"}, "literal_error"),
        ({"DATABASE_URL": VALID_DATABASE_URL, "unexpected": "value"}, "extra_forbidden"),
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
