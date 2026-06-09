from fastapi import APIRouter, Response

from app.processing.metrics import CONTENT_TYPE_LATEST, render_metrics

router = APIRouter(prefix="/v1")


@router.get("/metrics")
async def metrics() -> Response:
    return Response(content=render_metrics(), media_type=CONTENT_TYPE_LATEST)
