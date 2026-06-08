from __future__ import annotations

import logging

from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, status

from app.api.deps import get_icinga2_processor
from app.domain.rules import IngressDecisionEnvelope
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload
from app.processing.ingress import Icinga2DecisionProcessor

router = APIRouter()
logger = logging.getLogger(__name__)

@router.post("/webhooks/icinga2")
async def ingest_icinga2(
    processor: Annotated[Icinga2DecisionProcessor, Depends(get_icinga2_processor)],
    payload: Icinga2WebhookPayload = Body(...),
) -> IngressDecisionEnvelope:
    try:
        return await processor.process_payload(payload)
    except Exception as exc:
        logger.exception("icinga2 ingest failed")
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="ingest failed",
        ) from exc
