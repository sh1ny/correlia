from __future__ import annotations

import logging

from typing import Annotated

from fastapi import APIRouter, Body, Depends, HTTPException, Security, status

from app.api.security import require_ingress_token

from app.api.deps import get_icinga2_processor
from app.domain.rules import IngressDecisionEnvelope
from app.plugins.inputs.icinga2 import Icinga2WebhookPayload
from app.processing.ingress import Icinga2DecisionProcessor
from app.processing.logging import safe_log_extra

router = APIRouter(prefix="/v1", dependencies=[Security(require_ingress_token)])
logger = logging.getLogger(__name__)


@router.post("/icinga2/events")
async def ingest_icinga2(
    processor: Annotated[Icinga2DecisionProcessor, Depends(get_icinga2_processor)],
    payload: Icinga2WebhookPayload = Body(...),
) -> IngressDecisionEnvelope:
    try:
        return await processor.process_payload(payload)
    except Exception as exc:
        logger.error(
            "icinga2 ingest failed",
            extra=safe_log_extra(
                event="ingestion_failed",
                exception_type=type(exc).__name__,
            ),
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="ingest failed",
        ) from exc
