from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.routers.health import router as health_router
from app.api.routers.ingress import router as ingress_router
from app.config.settings import Settings, get_settings
from app.persistence.database import create_engine, create_sessionmaker
from app.processing.ingress import Icinga2DecisionProcessor, build_icinga2_processor


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    if not hasattr(app.state, "settings"):
        app.state.settings = get_settings()

    engine = getattr(app.state, "engine", None)
    if not hasattr(app.state, "sessionmaker"):
        engine = create_engine(app.state.settings)
        app.state.engine = engine
        app.state.sessionmaker = create_sessionmaker(engine)

    if not hasattr(app.state, "icinga2_processor"):
        app.state.icinga2_processor = build_icinga2_processor()

    try:
        yield
    finally:
        engine = getattr(app.state, "engine", None)
        if engine is not None:
            await engine.dispose()


def create_app(
    settings: Settings | None = None,
    sessionmaker: async_sessionmaker[AsyncSession] | None = None,
    icinga2_processor: Icinga2DecisionProcessor | None = None,
) -> FastAPI:
    app = FastAPI(lifespan=lifespan)

    if settings is not None:
        app.state.settings = settings
    if sessionmaker is not None:
        app.state.sessionmaker = sessionmaker
    if icinga2_processor is not None:
        app.state.icinga2_processor = icinga2_processor

    app.include_router(health_router)
    app.include_router(ingress_router)
    return app