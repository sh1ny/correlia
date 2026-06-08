from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, status

from app.api.deps import get_icinga2_processor
from app.processing.ingress import Icinga2DecisionProcessor
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload

router = APIRouter()


@router.post("/webhooks/icinga2")
async def ingest_icinga2(
    processor: Annotated[Icinga2DecisionProcessor, Depends(get_icinga2_processor)],
    payload: Icinga2WebhookPayload = Body(...),
) -> dict[str, object]:
    try:
        envelope = await processor.process_payload(payload)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="ingest failed",
        ) from None
    return envelope.model_dump(mode="json")
