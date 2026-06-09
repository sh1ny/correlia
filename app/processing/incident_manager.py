from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum
from uuid import UUID

from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import EventType, NormalizedEvent
from app.domain.incidents import DecisionContext
from app.domain.rules import NotificationResult, RuleDecision
from app.persistence.incidents import IncidentAggregationWriteResult, IncidentUpsertInput, record_problem_incident
from app.persistence.models import Incident


class NoDispatchReason(StrEnum):
    BELOW_THRESHOLD = "below_threshold"
    REPLAY = "replay"
    ALREADY_NOTIFIED = "already_notified"


@dataclass(frozen=True, slots=True)
class IncidentAggregationResult:
    incident_id: UUID
    effect: str
    status: str
    replay: bool
    inside_window: bool
    counted: bool
    counted_count: int
    threshold_crossed: bool
    first_threshold_transition: bool
    notification_triggered: bool
    notification_failed: bool
    no_dispatch_reason: str | None
    notification_results: tuple[NotificationResult, ...]


class IncidentManager:
    def __init__(self, session: AsyncSession, config_hash: str | None = None) -> None:
        self._session = session
        self._config_hash = config_hash

    async def apply_problem(
        self,
        event: NormalizedEvent,
        decision: RuleDecision,
    ) -> IncidentAggregationResult:
        if event.event_type is not EventType.PROBLEM:
            raise ValueError("IncidentManager.apply_problem only accepts PROBLEM events")

        window_seconds = max(
            1,
            int(
                (
                    decision.threshold_decision.window_end
                    - decision.threshold_decision.window_start
                ).total_seconds()
            ),
        )
        preliminary_context = self._decision_context(
            event=event,
            decision=decision,
            write_result=None,
            no_dispatch_reason=None,
        )
        write_result = await record_problem_incident(
            self._session,
            IncidentUpsertInput(
                rule_name=decision.rule_name,
                group_key=decision.group_key,
                severity=event.severity,
                event_time=event.timestamp,
                summary=decision.summary,
                affected_hosts=(event.host,),
                affected_services=(event.service,) if event.service is not None else (),
                decision_context=preliminary_context,
                fingerprint=event.fingerprint,
                threshold_count=decision.threshold_decision.threshold,
                window_seconds=window_seconds,
            ),
        )

        notification_triggered = write_result.first_threshold_transition
        no_dispatch_reason = self._no_dispatch_reason(write_result)
        final_context = self._decision_context(
            event=event,
            decision=decision,
            write_result=write_result,
            no_dispatch_reason=no_dispatch_reason,
        )
        await self._session.execute(
            update(Incident)
            .where(Incident.id == write_result.incident.id)
            .values(decision_context=final_context.model_dump(mode="json"))
        )
        write_result.incident.decision_context = final_context.model_dump(mode="json")

        return IncidentAggregationResult(
            incident_id=write_result.incident.id,
            effect=write_result.effect,
            status=write_result.incident.status,
            replay=write_result.replay,
            inside_window=write_result.inside_window,
            counted=write_result.counted,
            counted_count=write_result.counted_count,
            threshold_crossed=write_result.threshold_crossed,
            first_threshold_transition=write_result.first_threshold_transition,
            notification_triggered=notification_triggered,
            notification_failed=False,
            no_dispatch_reason=no_dispatch_reason.value if no_dispatch_reason is not None else None,
            notification_results=(),
        )

    def _decision_context(
        self,
        event: NormalizedEvent,
        decision: RuleDecision,
        write_result: IncidentAggregationWriteResult | None,
        no_dispatch_reason: NoDispatchReason | None,
    ) -> DecisionContext:
        notes: dict[str, str] = {
            "event.type": event.event_type.value,
            "event.severity": event.severity.value,
        }
        if no_dispatch_reason is not None:
            notes["dispatch.reason"] = no_dispatch_reason.value

        return DecisionContext(
            fingerprint=event.fingerprint,
            source_id=event.source_id,
            rule_name=decision.rule_name,
            group_key=decision.group_key,
            matched_rule_names=tuple(decision.matched_rules),
            event_count=write_result.incident.event_count if write_result is not None else None,
            config_hash=self._config_hash,
            notes=notes,
            threshold_count=decision.threshold_decision.threshold,
            counted_count=write_result.counted_count if write_result is not None else None,
            threshold_crossed=write_result.threshold_crossed if write_result is not None else None,
            first_threshold_transition=(
                write_result.first_threshold_transition if write_result is not None else None
            ),
            replay=write_result.replay if write_result is not None else None,
            action_names=tuple(decision.actions),
        )

    @staticmethod
    def _no_dispatch_reason(
        write_result: IncidentAggregationWriteResult,
    ) -> NoDispatchReason | None:
        if write_result.replay:
            return NoDispatchReason.REPLAY
        if write_result.first_threshold_transition:
            return None
        if write_result.threshold_crossed:
            return NoDispatchReason.ALREADY_NOTIFIED
        return NoDispatchReason.BELOW_THRESHOLD
