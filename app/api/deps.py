from typing import cast

from fastapi import Request
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker
from app.config.rules import CompiledRuleConfig
from app.config.topology import CompiledTopologyConfig

from app.config.settings import Settings
from app.plugins.loader import PluginRegistry
from app.processing.lifecycle_worker import LifecycleWorker
from app.processing.task_runner import TaskRunner
from app.processing.ingress import Icinga2DecisionProcessor


def get_app_settings(request: Request) -> Settings:
    return cast(Settings, request.app.state.settings)


def get_sessionmaker(request: Request) -> async_sessionmaker[AsyncSession]:
    return cast(async_sessionmaker[AsyncSession], request.app.state.sessionmaker)


def get_icinga2_processor(request: Request) -> Icinga2DecisionProcessor:
    return cast(Icinga2DecisionProcessor, request.app.state.icinga2_processor)


def get_task_runner(request: Request) -> TaskRunner:
    return cast(TaskRunner, request.app.state.task_runner)


def get_plugin_registry(request: Request) -> PluginRegistry:
    return cast(PluginRegistry, request.app.state.plugin_registry)


def get_rules_config(request: Request) -> CompiledRuleConfig:
    return cast(CompiledRuleConfig, request.app.state.rules_config)


def get_topology_config(request: Request) -> CompiledTopologyConfig:
    return cast(CompiledTopologyConfig, request.app.state.topology_config)


def get_lifecycle_worker(request: Request) -> LifecycleWorker:
    return cast(LifecycleWorker, request.app.state.lifecycle_worker)
