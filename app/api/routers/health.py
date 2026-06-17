import logging
from typing import Annotated, Any

from fastapi import APIRouter, Depends, Request, Security, status
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_app_settings, get_sessionmaker
from app.api.security import require_operator_token
from app.config.settings import Settings
from app.persistence.database import check_database_ready
from app.processing.logging import safe_log_extra

logger = logging.getLogger(__name__)


def build_router(protect_readyz: bool = False) -> APIRouter:
    readyz_dependencies: list[Any] = [Security(require_operator_token)] if protect_readyz else []
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
        checks: dict[str, str] = {}
        checks["database"] = await _database_check(sessionmaker)
        checks["settings"] = "ready" if settings is not None else "not_ready"
        checks["rules_config"] = _configured_state_check(
            configured=getattr(settings, "rules_path", None) is not None,
            value=getattr(request.app.state, "rules_config", None),
        )
        checks["topology_config"] = _configured_state_check(
            configured=getattr(settings, "topology_path", None) is not None,
            value=getattr(request.app.state, "topology_config", None),
        )
        plugin_registry = getattr(request.app.state, "plugin_registry", None)
        checks["plugin_registry"] = "ready" if plugin_registry is not None else "not_ready"
        checks["plugins"] = _plugins_check(plugin_registry)
        lifecycle_worker = getattr(request.app.state, "lifecycle_worker", None)
        checks["lifecycle_worker"] = (
            "ready" if getattr(lifecycle_worker, "healthy", False) is True else "not_ready"
        )

        failed = [name for name, check_status in checks.items() if check_status != "ready"]
        for name in failed:
            logger.warning(
                "readiness dependency failed",
                extra=safe_log_extra(event="readiness_failed", category=name),
            )
        if failed:
            return JSONResponse(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                content={"detail": "not ready", "checks": checks},
            )
        return {"status": "ready", "checks": checks}

    return router


router = build_router()


async def _database_check(sessionmaker: async_sessionmaker[AsyncSession]) -> str:
    try:
        await check_database_ready(sessionmaker)
    except Exception as exc:
        logger.warning(
            "readiness database check failed",
            extra=safe_log_extra(
                event="readiness_failed",
                category="database",
                exception_type=type(exc).__name__,
            ),
        )
        return "not_ready"
    return "ready"


def _configured_state_check(*, configured: bool, value: object | None) -> str:
    if not configured:
        return "ready"
    return "ready" if value is not None else "not_ready"


def _plugins_check(plugin_registry: Any | None) -> str:
    if plugin_registry is None:
        return "not_ready"
    try:
        rows = plugin_registry.list_plugins()
    except Exception as exc:
        logger.warning(
            "readiness plugin check failed",
            extra=safe_log_extra(
                event="readiness_failed",
                category="plugins",
                exception_type=type(exc).__name__,
            ),
        )
        return "not_ready"
    for row in rows:
        if row.get("ready") is not True:
            return "not_ready"
    return "ready"
