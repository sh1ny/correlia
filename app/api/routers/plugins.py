from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, Security

from app.api.security import require_operator_token

from app.api.deps import get_plugin_registry
from app.plugins.loader import PluginRegistry

router = APIRouter(prefix="/v1", dependencies=[Security(require_operator_token)])


@router.get("/plugins")
async def list_plugins(
    plugin_registry: Annotated[PluginRegistry, Depends(get_plugin_registry)],
) -> tuple[dict[str, object], ...]:
    return plugin_registry.list_plugins()
