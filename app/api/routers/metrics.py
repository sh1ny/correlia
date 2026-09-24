from fastapi import APIRouter, Response, Security

from app.api.security import require_operator_token

from app.processing.metrics import CONTENT_TYPE_LATEST, render_metrics


def build_router(protect_metrics: bool = False) -> APIRouter:
    router = APIRouter(prefix="/v1")
    if protect_metrics:
        router.dependencies.append(Security(require_operator_token))

    @router.get("/metrics")
    async def metrics() -> Response:
        return Response(content=render_metrics(), media_type=CONTENT_TYPE_LATEST)

    return router


router = build_router()
