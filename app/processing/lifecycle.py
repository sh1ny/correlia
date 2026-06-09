from __future__ import annotations

from dataclasses import dataclass
from typing import Literal
from uuid import UUID

from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import EventType, NormalizedEvent
from app.persistence.incidents import (
    LifecycleWriteResult,
    ack_open_incident,
    close_open_incident,
    resolve_host_recovery,
    resolve_service_recovery,
)

LifecycleResultEffect = Literal[
    "affected_set_shrunk",
    "resolved",
    "noop",
    "closed",
    "acknowledged",
]


@dataclass(frozen=True, slots=True)
class LifecycleResult:
    incident_ids: tuple[UUID, ...]
    effect: LifecycleResultEffect
    transitioned_to: str | None
    previous_host_count: int
    previous_service_count: int
    affected_object_removed: bool

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
            raise ValueError("LifecycleManager.resolve_for_event only accepts RECOVERY events")

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
        await self._session.commit()
        return _result_from_writes(write_results)

    async def acknowledge(self, incident_id: UUID, *, operator: str) -> LifecycleResult:
        write_result = await ack_open_incident(self._session, incident_id, operator=operator)
        await self._session.commit()
        if write_result is None:
            return _empty_result()
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
        return _result_from_writes((write_result,))


def _empty_result() -> LifecycleResult:
    return LifecycleResult(
        incident_ids=(),
        effect="noop",
        transitioned_to=None,
        previous_host_count=0,
        previous_service_count=0,
        affected_object_removed=False,
    )


def _result_from_writes(write_results: tuple[LifecycleWriteResult, ...]) -> LifecycleResult:
    if not write_results:
        return _empty_result()
    resolved = [result for result in write_results if result.effect == "resolved"]
    shrunk = [result for result in write_results if result.effect == "affected_set_shrunk"]
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
        previous_service_count=sum(result.previous_service_count for result in write_results),
        affected_object_removed=any(result.affected_object_removed for result in write_results),
    )
