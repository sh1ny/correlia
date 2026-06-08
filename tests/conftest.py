from collections.abc import Iterator

import pytest


_SETTINGS_ENV_KEYS = (
    "DATABASE_URL",
    "CORRELIA_DATABASE_URL",
    "CORRELIA_ENVIRONMENT",
    "CORRELIA_LOG_LEVEL",
    "CORRELIA_RULES_PATH",
    "CORRELIA_TOPOLOGY_PATH",
    "CORRELIA_PLUGINS_PATH",
)


@pytest.fixture(autouse=True)
def clean_settings_env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    for key in _SETTINGS_ENV_KEYS:
        monkeypatch.delenv(key, raising=False)
    yield
