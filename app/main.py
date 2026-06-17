from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, Request, status
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.routers.config_status import router as config_status_router
from app.api.routers.health import build_router as build_health_router
from app.api.routers.incidents import router as incidents_router
from app.api.routers.ingress import router as ingress_router
from app.api.routers.metrics import build_router as build_metrics_router
from app.api.routers.plugins import router as plugins_router
from app.config.rules import CompiledRuleConfig, load_rules_config
from app.config.settings import Settings, get_settings
from app.config.topology import CompiledTopologyConfig, load_topology_config
from app.persistence.database import create_engine, create_sessionmaker
from app.plugins.loader import PluginRegistry, load_plugin_registry
from app.processing.ingress import Icinga2DecisionProcessor, build_icinga2_processor
from app.processing.notification_dispatcher import NotificationDispatcher
from app.processing.lifecycle import expire_stale_batch
from app.processing.lifecycle_worker import LifecycleWorker
from app.processing.logging import configure_json_logging
from app.processing.task_runner import AsyncIOTaskRunner, TaskRunner


def _safe_validation_errors(exc: RequestValidationError) -> list[dict[str, Any]]:
    return [
        {
            "loc": error.get("loc", ()),
            "msg": error.get("msg", "invalid request"),
            "type": error.get("type", "value_error"),
        }
        for error in exc.errors()
    ]


async def request_validation_exception_handler(
    _request: Request,
    exc: Exception,
) -> JSONResponse:
    if not isinstance(exc, RequestValidationError):
        raise exc
    return JSONResponse(
        status_code=status.HTTP_422_UNPROCESSABLE_CONTENT,
        content={"detail": _safe_validation_errors(exc)},
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if not hasattr(app.state, "settings"):
        app.state.settings = get_settings()
    configure_json_logging(app.state.settings.log_level)

    engine = getattr(app.state, "engine", None)
    if not hasattr(app.state, "sessionmaker"):
        engine = create_engine(app.state.settings)
        app.state.engine = engine
        app.state.sessionmaker = create_sessionmaker(engine)

    if not hasattr(app.state, "plugin_registry"):
        plugins_path = getattr(app.state.settings, "plugins_path", None)
        app.state.plugin_registry = (
            load_plugin_registry(plugins_path)
            if plugins_path is not None
            else PluginRegistry((), "")
        )

    if not hasattr(app.state, "rules_config"):
        rules_path = getattr(app.state.settings, "rules_path", None)
        app.state.rules_config = (
            load_rules_config(
                rules_path,
                known_plugins=frozenset(app.state.plugin_registry.names),
            )
            if rules_path is not None
            else CompiledRuleConfig((), "")
        )

    if not hasattr(app.state, "topology_config"):
        topology_path = getattr(app.state.settings, "topology_path", None)
        app.state.topology_config = (
            load_topology_config(topology_path)
            if topology_path is not None
            else CompiledTopologyConfig((), ())
        )

    if not hasattr(app.state, "task_runner"):
        app.state.task_runner = AsyncIOTaskRunner()

    if "notify" not in getattr(app.state.task_runner, "registered_task_names", ()):
        dispatcher = NotificationDispatcher(
            app.state.sessionmaker,
            app.state.plugin_registry,
        )
        app.state.task_runner.register("notify", dispatcher.process)

    if not hasattr(app.state, "icinga2_processor"):
        topology_path = getattr(app.state.settings, "topology_path", None)
        rules_path = getattr(app.state.settings, "rules_path", None)
        app.state.icinga2_processor = build_icinga2_processor(
            topology_path=topology_path,
            rules_path=rules_path,
            sessionmaker=app.state.sessionmaker,
            task_runner=app.state.task_runner,
            plugin_registry=app.state.plugin_registry,
        )

    if not hasattr(app.state, "lifecycle_worker"):
        app.state.lifecycle_worker = LifecycleWorker(
            sessionmaker=app.state.sessionmaker,
            interval_seconds=app.state.settings.lifecycle_scan_interval_seconds,
            batch_size=app.state.settings.lifecycle_batch_size,
            sweep=expire_stale_batch,
        )
    await app.state.lifecycle_worker.start()

    try:
        yield
    finally:
        lifecycle_worker = getattr(app.state, "lifecycle_worker", None)
        if lifecycle_worker is not None:
            await lifecycle_worker.stop()
        task_runner = getattr(app.state, "task_runner", None)
        if task_runner is not None:
            await task_runner.drain()
        engine = getattr(app.state, "engine", None)
        if engine is not None:
            await engine.dispose()


def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
    icinga2_processor: Icinga2DecisionProcessor | None = None,
    task_runner: TaskRunner | None = None,
    plugin_registry: PluginRegistry | None = None,
    lifecycle_worker: LifecycleWorker | None = None,
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)
    app.add_exception_handler(RequestValidationError, request_validation_exception_handler)

    if settings is not None:
        app.state.settings = settings
        configure_json_logging(settings.log_level)

    effective_settings = settings if settings is not None else getattr(
        app.state, "settings", get_settings()
    )

    if sessionmaker is not None:
        app.state.sessionmaker = sessionmaker
    if icinga2_processor is not None:
        app.state.icinga2_processor = icinga2_processor
    if task_runner is not None:
        app.state.task_runner = task_runner
    if plugin_registry is not None:
        app.state.plugin_registry = plugin_registry
    if lifecycle_worker is not None:
        app.state.lifecycle_worker = lifecycle_worker

    health_router = build_health_router(
        protect_readyz=not effective_settings.expose_readyz and effective_settings.api_auth_enabled
    )
    metrics_router = build_metrics_router(
        protect_metrics=not effective_settings.expose_metrics and effective_settings.api_auth_enabled
    )

    app.include_router(health_router)
    app.include_router(ingress_router)
    app.include_router(plugins_router)
    app.include_router(config_status_router)
    app.include_router(incidents_router)
    app.include_router(metrics_router)
    return app