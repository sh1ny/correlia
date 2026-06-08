from typing import cast

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config.settings import Settings
from app.processing.ingress import Icinga2DecisionProcessor


def get_app_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)


def get_sessionmaker(request: Request) -> async_sessionmaker[AsyncSession]:
    return cast(async_sessionmaker[AsyncSession], request.app.state.sessionmaker)


def get_icinga2_processor(request: Request) -> Icinga2DecisionProcessor:
    return cast(Icinga2DecisionProcessor, request.app.state.icinga2_processor)