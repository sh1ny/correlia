import logging
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Request, Security, status
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_app_settings, get_sessionmaker
from app.api.security import require_operator_token
from app.config.settings import Settings
from app.persistence.database import check_database_ready
from app.processing.logging import operational_log_extra
from app.processing.metrics import (
    OUTPUT_PLUGIN_CATEGORIES,
    READINESS_DEPENDENCIES,
    READINESS_STATES,
    record_readiness_evaluation,
)

logger = logging.getLogger(__name__)

_READINESS_DEPENDENCY_KEYS = tuple(sorted(READINESS_DEPENDENCIES))
_OUTPUT_PLUGIN_CATEGORY_KEYS = tuple(sorted(OUTPUT_PLUGIN_CATEGORIES))
_READINESS_CHECK_KEYS = _READINESS_DEPENDENCY_KEYS + _OUTPUT_PLUGIN_CATEGORY_KEYS


def build_router(protect_readyz: bool = False) -> APIRouter:
    readyz_dependencies: list[Any] = (
        [Security(require_operator_token)] if protect_readyz else []
    )
    router = APIRouter(prefix="/v1")

    @router.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @router.get("/readyz", response_model=None, dependencies=readyz_dependencies)
    async def readyz(
        request: Request,
        settings: Annotated[Settings, Depends(get_app_settings)],
        sessionmaker: Annotated[
            async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
        ],
    ) -> Any:
        dependency_checks = await _dependency_checks(request, settings, sessionmaker)
        plugin_checks = _plugin_category_checks(
            getattr(request.app.state, "plugin_registry", None)
        )
        dependency_checks["plugins"] = _plugins_check(plugin_checks)
        checks = {**dependency_checks, **plugin_checks}
        record_readiness_evaluation(dependency_checks, plugin_checks)
        _record_readiness_transitions(request, checks)

        if any(checks[name] == "not_ready" for name in _READINESS_CHECK_KEYS):
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={"detail": "not ready", "checks": checks},
            )
        return {"status": "ready", "checks": checks}

    return router


router = build_router()


async def _dependency_checks(
    request: Request,
    settings: Settings,
    sessionmaker: async_sessionmaker[AsyncSession],
) -> dict[str, str]:
    plugin_registry = getattr(request.app.state, "plugin_registry", None)
    lifecycle_worker = getattr(request.app.state, "lifecycle_worker", None)
    return {
        "database": await _database_check(sessionmaker),
        "settings": "ready" if settings is not None else "not_ready",
        "rules_config": _configured_state_check(
            configured=getattr(settings, "rules_path", None) is not None,
            value=getattr(request.app.state, "rules_config", None),
        ),
        "topology_config": _configured_state_check(
            configured=getattr(settings, "topology_path", None) is not None,
            value=getattr(request.app.state, "topology_config", None),
        ),
        "plugin_registry": "ready" if plugin_registry is not None else "not_ready",
        "plugins": "not_ready",
        "lifecycle_worker": (
            "ready"
            if getattr(lifecycle_worker, "healthy", False) is True
            else "not_ready"
        ),
    }


async def _database_check(sessionmaker: async_sessionmaker[AsyncSession]) -> str:
    try:
        await check_database_ready(sessionmaker)
    except Exception:
        return "not_ready"
    return "ready"


def _configured_state_check(*, configured: bool, value: object | None) -> str:
    return "not_ready" if configured and value is None else "ready"


def _plugin_category_checks(plugin_registry: Any | None) -> dict[str, str]:
    if plugin_registry is None:
        return {category: "not_ready" for category in _OUTPUT_PLUGIN_CATEGORY_KEYS}
    try:
        reported_states = plugin_registry.readiness_states()
        if not isinstance(reported_states, dict):
            raise TypeError
        checks: dict[str, str] = {}
        for category in _OUTPUT_PLUGIN_CATEGORY_KEYS:
            state = reported_states.get(category)
            checks[category] = (
                state
                if isinstance(state, str) and state in READINESS_STATES
                else "not_ready"
            )
        return checks
    except Exception:
        return {category: "not_ready" for category in _OUTPUT_PLUGIN_CATEGORY_KEYS}


def _plugins_check(plugin_checks: dict[str, str]) -> str:
    return "not_ready" if "not_ready" in plugin_checks.values() else "ready"


def _record_readiness_transitions(request: Request, checks: dict[str, str]) -> None:
    snapshot = tuple((category, checks[category]) for category in _READINESS_CHECK_KEYS)
    previous = getattr(request.app.state, "readiness_log_snapshot", None)
    if previous == snapshot:
        return
    request.app.state.readiness_log_snapshot = snapshot

    if previous is None:
        initial_failures = tuple(
            (category, state_value)
            for category, state_value in snapshot
            if state_value == "not_ready"
        )
        if initial_failures:
            for category, state_value in initial_failures:
                _log_readiness_state(category, state_value)
        else:
            _log_readiness_state("aggregate", "ready")
        return

    previous_states = dict(previous)
    for category, state_value in snapshot:
        if previous_states.get(category) != state_value:
            _log_readiness_state(category, state_value)


def _log_readiness_state(category: str, state_value: str) -> None:
    logger.log(
        logging.WARNING if state_value == "not_ready" else logging.INFO,
        "readiness state changed",
        extra=operational_log_extra(
            event="readiness",
            category=category,
            state=state_value,
        ),
    )
