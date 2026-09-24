from __future__ import annotations

from dataclasses import dataclass
import logging
from typing import Literal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.domain.events import EventType, NormalizedEvent
from app.persistence.incidents import (
    LifecycleWriteResult,
    ack_open_incident,
    close_open_incident,
    expire_stale_incidents,
    resolve_host_recovery,
    resolve_service_recovery,
)
from app.processing.metrics import record_incident_effect
from app.processing.logging import safe_log_extra

logger = logging.getLogger(__name__)

LifecycleResultEffect = Literal[
    "affected_set_shrunk",
    "resolved",
    "noop",
    "closed",
    "acknowledged",
    "expired",
]


@dataclass(frozen=True, slots=True)
class LifecycleResult:
    """Result of an ingress-driven source-recovery lifecycle.

    The caller (ingress) owns the database transaction. The manager does
    not commit and does not submit notification tasks. Recovery events do
    not trigger notification dispatch (D-03 / D-13); ``notification_intent``
    is always ``"no_dispatch"`` for this path so audit rows can record the
    intent without consulting plugins.
    """

    incident_ids: tuple[UUID, ...]
    effect: LifecycleResultEffect
    transitioned_to: str | None
    previous_host_count: int
    previous_service_count: int
    affected_object_removed: bool
    notification_intent: Literal["no_dispatch"] = "no_dispatch"

    @property
    def incident_id(self) -> UUID | None:
        if not self.incident_ids:
            return None
        return self.incident_ids[0]

    @property
    def resolved_count(self) -> int:
        return 1 if self.effect == "resolved" else 0


class LifecycleManager:
    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    async def resolve_for_event(self, event: NormalizedEvent) -> LifecycleResult:
        if event.event_type is not EventType.RECOVERY:
            raise ValueError(
                "LifecycleManager.resolve_for_event only accepts RECOVERY events"
            )

        if event.service is not None:
            write_results = await resolve_service_recovery(
                self._session,
                host=event.host,
                service=event.service,
                recovery_time=event.timestamp,
                fingerprint=event.fingerprint,
                source_id=event.source_id,
            )
        else:
            write_results = await resolve_host_recovery(
                self._session,
                host=event.host,
                recovery_time=event.timestamp,
                fingerprint=event.fingerprint,
                source_id=event.source_id,
            )
        for write_result in write_results:
            record_incident_effect(write_result.effect)
        logger.info(
            "recovery lifecycle applied",
            extra=safe_log_extra(
                event="recovery_lifecycle",
                incident_id=str(write_results[0].incident.id)
                if write_results
                else None,
                effect=_result_from_writes(write_results).effect,
                count=len(write_results),
            ),
        )
        return _result_from_writes(write_results)

    async def acknowledge(self, incident_id: UUID, *, operator: str) -> LifecycleResult:
        write_result = await ack_open_incident(
            self._session, incident_id, operator=operator
        )
        await self._session.commit()
        if write_result is None:
            return _empty_result()
        record_incident_effect(write_result.effect)
        logger.info(
            "incident acknowledged",
            extra=safe_log_extra(
                event="operator_mutation",
                incident_id=str(write_result.incident.id),
                status=write_result.incident.status,
                effect=write_result.effect,
                reason="acknowledged",
                operator=operator,
            ),
        )
        return _result_from_writes((write_result,))

    async def manual_close(
        self,
        incident_id: UUID,
        *,
        operator: str,
        reason: str,
    ) -> LifecycleResult:
        write_result = await close_open_incident(
            self._session,
            incident_id,
            operator=operator,
            reason=reason,
        )
        await self._session.commit()
        if write_result is None:
            return _empty_result()
        record_incident_effect(write_result.effect)
        logger.info(
            "incident manually closed",
            extra=safe_log_extra(
                event="operator_mutation",
                incident_id=str(write_result.incident.id),
                status=write_result.incident.status,
                effect=write_result.effect,
                reason=reason,
                operator=operator,
            ),
        )
        return _result_from_writes((write_result,))


async def expire_stale_batch(
    sessionmaker: async_sessionmaker[AsyncSession],
    limit: int,
) -> int:
    async with sessionmaker() as session:
        write_results = await expire_stale_incidents(session, limit=limit)
        for write_result in write_results:
            record_incident_effect("expired")
        await session.commit()
        logger.info(
            "stale incidents expired",
            extra=safe_log_extra(
                event="incident_expiration",
                effect="expired",
                expired_count=len(write_results),
            ),
        )
        return len(write_results)


def _empty_result() -> LifecycleResult:
    return LifecycleResult(
        incident_ids=(),
        effect="noop",
        transitioned_to=None,
        previous_host_count=0,
        previous_service_count=0,
        affected_object_removed=False,
    )


def _result_from_writes(
    write_results: tuple[LifecycleWriteResult, ...],
) -> LifecycleResult:
    if not write_results:
        return _empty_result()
    resolved = [result for result in write_results if result.effect == "resolved"]
    shrunk = [
        result for result in write_results if result.effect == "affected_set_shrunk"
    ]
    if resolved:
        effect: LifecycleResultEffect = "resolved"
        transitioned_to = resolved[0].transitioned_to
    elif shrunk:
        effect = "affected_set_shrunk"
        transitioned_to = None
    else:
        effect = write_results[0].effect
        transitioned_to = write_results[0].transitioned_to
    return LifecycleResult(
        incident_ids=tuple(result.incident.id for result in write_results),
        effect=effect,
        transitioned_to=transitioned_to,
        previous_host_count=sum(result.previous_host_count for result in write_results),
        previous_service_count=sum(
            result.previous_service_count for result in write_results
        ),
        affected_object_removed=any(
            result.affected_object_removed for result in write_results
        ),
    )
