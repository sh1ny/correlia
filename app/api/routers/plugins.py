from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends

from app.api.deps import get_plugin_registry
from app.plugins.loader import PluginRegistry

router = APIRouter()


@router.get("/plugins")
async def list_plugins(
    plugin_registry: Annotated[PluginRegistry, Depends(get_plugin_registry)],
) -> tuple[dict[str, object], ...]:
    return plugin_registry.list_plugins()
