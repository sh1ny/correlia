from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import get_app_settings, get_sessionmaker
from app.config.settings import Settings
from app.persistence.database import check_database_ready

router = APIRouter(prefix="/v1")


@router.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@router.get("/readyz")
async def readyz(
    settings: Annotated[Settings, Depends(get_app_settings)],
    sessionmaker: Annotated[
        async_sessionmaker[AsyncSession], Depends(get_sessionmaker)
    ],
) -> dict[str, str]:
    try:
        await check_database_ready(sessionmaker)
    except Exception as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="not ready",
        ) from exc

    return {"status": "ready"}
