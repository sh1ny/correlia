from __future__ import annotations

from dataclasses import dataclass
import logging
from enum import StrEnum
from typing import Literal
from uuid import UUID

from sqlalchemy import update
from sqlalchemy.ext.asyncio import AsyncSession

from app.domain.events import EventType, NormalizedEvent
from app.domain.notifications import NotificationDeliveryRecord
from app.domain.incidents import DecisionContext
from app.domain.rules import RuleDecision
from app.persistence.incidents import (
    IncidentAggregationWriteResult,
    IncidentUpsertInput,
    record_problem_incident,
)
from app.persistence.models import Incident
from app.processing.metrics import record_incident_effect
from app.processing.logging import safe_log_extra
from app.processing.task_runner import TaskRunner

logger = logging.getLogger(__name__)


class NoDispatchReason(StrEnum):
    BELOW_THRESHOLD = "below_threshold"
    REPLAY = "replay"
    ALREADY_NOTIFIED = "already_notified"


NotificationIntent = Literal["dispatch_planned", "no_dispatch"]


@dataclass(frozen=True, slots=True)
class IncidentAggregationResult:
    """Result of an ingress-driven problem aggregation.

    The caller (ingress) owns the database transaction: the manager writes
    incident/decision_context rows but does not commit and does not submit
    notification tasks. ``notification_intent`` communicates whether the
    caller should plan a notification dispatch after committing the audit
    and incident rows, or skip dispatch with a documented reason.
    """

    incident_id: UUID
    effect: str
    status: str
    replay: bool
    inside_window: bool
    counted: bool
    counted_count: int
    threshold_crossed: bool
    first_threshold_transition: bool
    notification_intent: NotificationIntent
    no_dispatch_reason: str | None


class IncidentManager:
    def __init__(
        self,
        session: AsyncSession,
        *,
        task_runner: TaskRunner | None = None,
        plugin_registry: object | None = None,
        config_hash: str | None = None,
    ) -> None:
        self._session = session
        self._task_runner = task_runner
        self._plugin_registry = plugin_registry
        self._config_hash = config_hash or getattr(plugin_registry, "config_hash", None)

    async def apply_problem(
        self,
        event: NormalizedEvent,
        decision: RuleDecision,
    ) -> IncidentAggregationResult:
        if event.event_type is not EventType.PROBLEM:
            raise ValueError(
                "IncidentManager.apply_problem only accepts PROBLEM events"
            )

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
        record_incident_effect(write_result.effect)
        logger.info(
            "incident upserted",
            extra=safe_log_extra(
                event="incident_upserted",
                incident_id=str(write_result.incident.id),
                rule_name=decision.rule_name,
                group_key=decision.group_key,
                status=write_result.incident.status,
                severity=event.severity.value,
                effect=write_result.effect,
                count=write_result.counted_count,
            ),
        )

        no_dispatch_reason = self._no_dispatch_reason(write_result)
        final_context = self._decision_context(
            event=event,
            decision=decision,
            write_result=write_result,
            no_dispatch_reason=no_dispatch_reason,
        )
        serialized_context = final_context.model_dump(mode="json")
        await self._session.execute(
            update(Incident)
            .where(Incident.id == write_result.incident.id)
            .values(decision_context=serialized_context)
        )
        write_result.incident.decision_context = serialized_context

        notification_intent: NotificationIntent = (
            "dispatch_planned" if no_dispatch_reason is None else "no_dispatch"
        )
        logger.info(
            "problem aggregation completed",
            extra=safe_log_extra(
                event="problem_aggregation",
                incident_id=str(write_result.incident.id),
                rule_name=decision.rule_name,
                group_key=decision.group_key,
                effect=write_result.effect,
                notification_intent=notification_intent,
                no_dispatch_reason=(
                    no_dispatch_reason.value if no_dispatch_reason is not None else None
                ),
                first_threshold_transition=write_result.first_threshold_transition,
            ),
        )
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
            notification_intent=notification_intent,
            no_dispatch_reason=(
                no_dispatch_reason.value if no_dispatch_reason is not None else None
            ),
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

        notification_delivery_results: tuple[NotificationDeliveryRecord, ...] = ()
        if write_result is not None:
            notification_delivery_results = DecisionContext.model_validate(
                {
                    "notification_delivery_results": (
                        write_result.incident.decision_context or {}
                    ).get("notification_delivery_results", ())
                }
            ).notification_delivery_results

        return DecisionContext(
            fingerprint=event.fingerprint,
            source_id=event.source_id,
            rule_name=decision.rule_name,
            group_key=decision.group_key,
            matched_rule_names=tuple(decision.matched_rules),
            event_count=write_result.incident.event_count
            if write_result is not None
            else None,
            config_hash=self._config_hash,
            notes=notes,
            threshold_count=decision.threshold_decision.threshold,
            counted_count=write_result.counted_count
            if write_result is not None
            else None,
            threshold_crossed=write_result.threshold_crossed
            if write_result is not None
            else None,
            first_threshold_transition=(
                write_result.first_threshold_transition
                if write_result is not None
                else None
            ),
            replay=write_result.replay if write_result is not None else None,
            action_names=tuple(decision.actions),
            notification_delivery_results=notification_delivery_results,
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
