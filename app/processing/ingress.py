from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Literal

from app.domain.audit import AuditDecisionSummary
from app.domain.events import EventType, NormalizedEvent
from app.domain.incidents import LifecycleOutcome
from app.domain.rules import (
    IncidentEffectSummary,
    IngressDecisionEnvelope,
    NoOpDecision,
    NotificationResult,
    RuleDecision,
)
from app.persistence.audit import (
    insert_incident_event,
    redact_payload,
)

from app.plugins.inputs.icinga2 import (
    Icinga2InputPlugin,
    Icinga2Rejection,
    Icinga2WebhookPayload,
)
from app.plugins.interfaces import InputPlugin, TopologyEnricher
from app.processing.rule_engine import RuleEngine
from app.processing.incident_manager import IncidentAggregationResult, IncidentManager
from app.processing.lifecycle import LifecycleManager, LifecycleResult
from app.processing.metrics import (
    record_event_accepted,
    record_event_rejected,
    record_notification_attempt,
    record_notification_failure,
    record_rule_matched,
)
from app.processing.logging import safe_log_extra
from app.processing.task_runner import TaskRunner


logger = logging.getLogger(__name__)

# Cap on incident_ids stored in the audit decision summary (D-18).
_AUDIT_INCIDENT_IDS_CAP = 20


class Icinga2DecisionProcessor:
    def __init__(
        self,
        plugin: InputPlugin,
        topology_enricher: TopologyEnricher | None = None,
        rule_engine: RuleEngine | None = None,
        sessionmaker: Any | None = None,
        task_runner: TaskRunner | None = None,
        plugin_registry: object | None = None,
        config_hash: str | None = None,
        *,
        audit_raw_payload_max_bytes: int,
        audit_raw_payload_hmac_key: str | Any,
    ) -> None:
        self._plugin = plugin
        self._topology_enricher = topology_enricher
        self._rule_engine = rule_engine
        self._sessionmaker = sessionmaker
        self._task_runner = task_runner
        self._plugin_registry = plugin_registry
        self._config_hash = config_hash
        self._audit_raw_payload_max_bytes = audit_raw_payload_max_bytes
        self._audit_raw_payload_hmac_key = audit_raw_payload_hmac_key

    async def process_payload(
        self, payload: Icinga2WebhookPayload
    ) -> IngressDecisionEnvelope:
        logger.info("ingestion received", extra=safe_log_extra(event="ingestion_received"))
        plugin_result = await self._plugin.process_payload(payload)

        if isinstance(plugin_result, Icinga2Rejection):
            record_event_rejected(plugin_result.reason)
            logger.info(
                "ingestion rejected",
                extra=safe_log_extra(event="ingestion_rejected", reason=plugin_result.reason),
            )
            return IngressDecisionEnvelope(
                state_accepted=False,
                source_id=plugin_result.source_id,
                host=plugin_result.host,
                service=plugin_result.service,
                rejection=plugin_result.model_dump(mode="json"),
            )

        event = plugin_result
        record_event_accepted(event.event_type.value)
        logger.info(
            "normalization succeeded",
            extra=safe_log_extra(
                event="normalization_succeeded",
                event_type=event.event_type.value,
                severity=event.severity.value,
            ),
        )

        # AUD-02: every accepted normalized event requires a sessionmaker so
        # the audit row can be inserted in the same transaction as the
        # incident/lifecycle write. Fail fast instead of silently dropping
        # audit writes.
        if self._sessionmaker is None:
            raise RuntimeError(
                "audit configuration is incomplete: ingress sessionmaker is required "
                "for accepted events (AUD-02)"
            )

        diagnostics: list[dict[str, object]] = []
        if self._topology_enricher is not None:
            enrichment_result = await self._topology_enricher.enrich(event)
            event = enrichment_result.event
            diagnostics = [
                {
                    "rule_id": d.rule_id,
                    "rule_name": d.rule_name,
                    "match_source": d.match_source,
                    "tags_added": d.tags_added,
                    "tags_overridden": d.tags_overridden,
                    "conflicts": d.conflicts,
                }
                for d in enrichment_result.diagnostics
            ]
            logger.info(
                "enrichment completed",
                extra=safe_log_extra(
                    event="enrichment_completed",
                    event_type=event.event_type.value,
                    count=len(diagnostics),
                ),
            )

        matched_rules: list[str] = []
        rule_decision: dict[str, object] | None = None
        group_key: str | None = None
        threshold_decision: dict[str, object] | None = None
        noop_reason: str | None = None
        decision: RuleDecision | None = None

        if self._rule_engine is not None:
            engine_decision = await self._rule_engine.evaluate(event)
            rule_decision = engine_decision.model_dump(mode="json")
            if isinstance(engine_decision, RuleDecision):
                decision = engine_decision
                matched_rules = list(decision.matched_rules)
                for rule_name in matched_rules:
                    record_rule_matched(rule_name)
                    logger.info(
                        "rule matched",
                        extra=safe_log_extra(
                            event="rule_matched",
                            rule_name=rule_name,
                            group_key=decision.group_key,
                        ),
                    )
                group_key = decision.group_key
                if event.event_type is EventType.PROBLEM:
                    threshold_decision = decision.threshold_decision.model_dump(mode="json")
            else:
                noop_reason = engine_decision.reason
        else:
            noop_reason = "no rule engine configured"
            rule_decision = NoOpDecision(reason=noop_reason).model_dump(mode="json")

        # ------------------------------------------------------------------
        # Single ingress-owned transaction for the accepted event (D-01/D-02).
        #   1. open one AsyncSession,
        #   2. run the manager (PROBLEM) or lifecycle manager (RECOVERY),
        #      or skip both for noop paths,
        #   3. build the audit decision summary,
        #   4. redact + HMAC the raw payload,
        #   5. insert the incident_events row,
        #   6. commit once.
        # Notification submission happens AFTER the commit (D-03).
        # ------------------------------------------------------------------
        async with self._sessionmaker() as session:
            incident_result: IncidentAggregationResult | None = None
            lifecycle_result: LifecycleResult | None = None

            if (
                event.event_type is EventType.PROBLEM
                and decision is not None
            ):
                manager = IncidentManager(
                    session,
                    task_runner=self._task_runner,
                    plugin_registry=self._plugin_registry,
                    config_hash=self._config_hash,
                )
                incident_result = await manager.apply_problem(event, decision)
            elif event.event_type is EventType.RECOVERY:
                lifecycle_manager = LifecycleManager(session)
                lifecycle_result = await lifecycle_manager.resolve_for_event(event)
                logger.info(
                    "recovery resolved",
                    extra=safe_log_extra(
                        event="recovery_resolved",
                        incident_id=str(lifecycle_result.incident_id)
                        if lifecycle_result.incident_id is not None
                        else None,
                        effect=lifecycle_result.effect,
                        closure_count=lifecycle_result.resolved_count,
                    ),
                )

            summary = _build_audit_summary(
                event=event,
                decision=decision,
                rule_decision_dict=rule_decision,
                matched_rules=matched_rules,
                group_key=group_key,
                incident_result=incident_result,
                lifecycle_result=lifecycle_result,
                noop_reason=noop_reason,
            )

            raw_payload_dict = (
                payload.model_dump(mode="json")
                if hasattr(payload, "model_dump")
                else dict(payload) if payload else {}
            )
            redacted = redact_payload(
                raw_payload_dict,
                max_bytes=self._audit_raw_payload_max_bytes,
                hmac_key=self._audit_raw_payload_hmac_key,
            )

            await insert_incident_event(
                session,
                event_timestamp=event.timestamp,
                source_id=event.source_id,
                fingerprint=event.fingerprint,
                event_type=event.event_type.value,
                severity=event.severity.value,
                host=event.host,
                service=event.service,
                incident_ids=[str(uid) for uid in summary.incident_ids],
                incident_effect=summary.incident_effect,
                decision_summary=summary.model_dump(mode="json"),
                normalized_event=event.model_dump(mode="json"),
                raw_payload=redacted.payload,
                raw_payload_original_byte_length=redacted.original_byte_length,
                raw_payload_stored_byte_length=redacted.stored_byte_length,
                raw_payload_truncated=redacted.truncated,
                redaction_version=redacted.redaction_version,
                redacted_path_count=redacted.redacted_path_count,
                raw_payload_hmac=redacted.payload_hmac,
            )

            await session.commit()

        # Post-commit notification submission (D-03). Audit rows record
        # notification_intent only; plugin delivery results are NOT
        # written back to incident_events.
        notification_results: tuple[NotificationResult, ...] = ()
        if (
            incident_result is not None
            and incident_result.notification_intent == "dispatch_planned"
        ):
            notification_results = await self._submit_notifications(
                incident_result.incident_id, decision
            )
        if incident_result is not None:
            logger.info(
                "notification decision recorded",
                extra=safe_log_extra(
                    event="notification_decision",
                    incident_id=str(incident_result.incident_id),
                    notification_intent=incident_result.notification_intent,
                    notification_count=sum(
                        1 for r in notification_results if r.success
                    ),
                ),
            )

        return IngressDecisionEnvelope(
            state_accepted=True,
            event_id=event.fingerprint,
            fingerprint=event.fingerprint,
            source_id=event.source_id,
            host=event.host,
            service=event.service,
            event_type=event.event_type.value,
            severity=event.severity.value,
            final_tags=dict(event.tags),
            enrichment_diagnostics=diagnostics,
            matched_rules=matched_rules,
            rule_decision=rule_decision,
            group_key=group_key,
            threshold_decision=threshold_decision,
            incident_effects=_incident_effects(incident_result),
            closure_count=(
                lifecycle_result.resolved_count if lifecycle_result is not None else 0
            ),
            lifecycle_outcome=_lifecycle_outcome(lifecycle_result),
            recovery_resolution=_recovery_resolution(lifecycle_result),
            affected_object_removed=(
                lifecycle_result.affected_object_removed
                if lifecycle_result is not None
                else False
            ),
            incident_id=(
                incident_result.incident_id
                if incident_result is not None
                else lifecycle_result.incident_id
                if lifecycle_result is not None
                else None
            ),
            threshold_crossed=(
                incident_result.threshold_crossed if incident_result is not None else False
            ),
            notification_triggered=any(r.success for r in notification_results),
            notification_failed=any(
                r.success is False for r in notification_results
            ),
            no_dispatch_reason=(
                incident_result.no_dispatch_reason if incident_result is not None else None
            ),
            notification_results=notification_results,
            notification_count=sum(1 for r in notification_results if r.success),
            rejection=None,
        )

    async def _submit_notifications(
        self,
        incident_id: Any,
        decision: RuleDecision | None,
    ) -> tuple[NotificationResult, ...]:
        if self._task_runner is None or decision is None:
            return ()
        results: list[NotificationResult] = []
        known_plugins = set(getattr(self._plugin_registry, "names", ()))
        for plugin_name in sorted(set(decision.actions)):
            if plugin_name not in known_plugins:
                result = NotificationResult(
                    success=False,
                    category="missing_plugin",
                    message="configured output plugin is missing",
                )
                record_notification_attempt(plugin_name, result.category)
                record_notification_failure(plugin_name, result.category)
                results.append(result)
                continue
            try:
                await self._task_runner.submit(
                    "notify",
                    {
                        "incident_id": str(incident_id),
                        "plugin_name": plugin_name,
                        "config_hash": self._config_hash,
                    },
                )
            except Exception:
                result = NotificationResult(
                    success=False,
                    category="dispatch_failed",
                    message="notification task submission failed",
                )
                record_notification_attempt(plugin_name, result.category)
                record_notification_failure(plugin_name, result.category)
                results.append(result)
                continue
            results.append(
                NotificationResult(
                    success=True,
                    category="dispatched",
                    message="notification task submitted",
                )
            )
        return tuple(results)


def _build_audit_summary(
    *,
    event: NormalizedEvent,
    decision: RuleDecision | None,
    rule_decision_dict: dict[str, object] | None,
    matched_rules: list[str],
    group_key: str | None,
    incident_result: IncidentAggregationResult | None,
    lifecycle_result: LifecycleResult | None,
    noop_reason: str | None,
) -> AuditDecisionSummary:
    if lifecycle_result is not None:
        return _build_recovery_audit_summary(
            event=event,
            lifecycle_result=lifecycle_result,
        )
    if incident_result is not None:
        return _build_problem_audit_summary(
            event=event,
            incident_result=incident_result,
            rule_name=_safe_rule_name(rule_decision_dict),
            group_key=group_key,
            threshold_count=_safe_threshold_count(rule_decision_dict),
        )
    return _build_noop_audit_summary(
        event=event,
        noop_reason=noop_reason,
        matched_rules=matched_rules,
    )


def _build_problem_audit_summary(
    *,
    event: NormalizedEvent,
    incident_result: IncidentAggregationResult,
    rule_name: str | None,
    group_key: str | None,
    threshold_count: int | None = None,
) -> AuditDecisionSummary:
    affected_count = 1 if incident_result.incident_id is not None else 0
    incident_ids, truncated = _incident_ids_for_audit((incident_result.incident_id,))
    return AuditDecisionSummary(
        decision_kind="problem",
        incident_effect=_problem_incident_effect(incident_result),
        rule_name=rule_name,
        group_key=group_key,
        incident_ids=incident_ids,
        affected_incident_count=affected_count,
        incident_ids_truncated=truncated,
        decision_reason=None,
        no_dispatch_reason=incident_result.no_dispatch_reason,
        notification_intent=incident_result.notification_intent,
        counted_count=incident_result.counted_count,
        threshold_count=threshold_count,
        threshold_crossed=incident_result.threshold_crossed,
        replay=incident_result.replay,
        first_threshold_transition=incident_result.first_threshold_transition,
        recovery_resolution=None,
        affected_object_removed=None,
    )


def _build_recovery_audit_summary(
    *,
    event: NormalizedEvent,
    lifecycle_result: LifecycleResult,
) -> AuditDecisionSummary:
    affected = len(lifecycle_result.incident_ids)
    incident_ids, truncated = _incident_ids_for_audit(lifecycle_result.incident_ids)
    return AuditDecisionSummary(
        decision_kind="recovery",
        incident_effect=_recovery_incident_effect(lifecycle_result),
        rule_name=None,
        group_key=None,
        incident_ids=incident_ids,
        affected_incident_count=affected,
        incident_ids_truncated=truncated,
        decision_reason="source_recovery",
        no_dispatch_reason=None,
        notification_intent="no_dispatch",
        counted_count=None,
        threshold_count=None,
        threshold_crossed=None,
        replay=None,
        first_threshold_transition=None,
        recovery_resolution=_recovery_resolution_for_audit(lifecycle_result),
        affected_object_removed=lifecycle_result.affected_object_removed,
    )


def _build_noop_audit_summary(
    *,
    event: NormalizedEvent,
    noop_reason: str | None,
    matched_rules: list[str],
) -> AuditDecisionSummary:
    return AuditDecisionSummary(
        decision_kind="noop",
        incident_effect="none",
        rule_name=None,
        group_key=None,
        incident_ids=(),
        affected_incident_count=0,
        incident_ids_truncated=False,
        decision_reason=noop_reason or "no matching rule",
        no_dispatch_reason="no_matching_rule" if not matched_rules else None,
        notification_intent="no_dispatch",
        counted_count=None,
        threshold_count=None,
        threshold_crossed=None,
        replay=None,
        first_threshold_transition=None,
        recovery_resolution=None,
        affected_object_removed=None,
    )


def _incident_ids_for_audit(
    incident_ids: tuple[Any, ...],
) -> tuple[tuple[str, ...], bool]:
    capped = tuple(str(uid) for uid in incident_ids[:_AUDIT_INCIDENT_IDS_CAP])
    truncated = len(incident_ids) > _AUDIT_INCIDENT_IDS_CAP
    return capped, truncated


def _problem_incident_effect(
    result: IncidentAggregationResult,
) -> Literal["none", "inserted", "updated"]:
    if result.effect == "inserted":
        return "inserted"
    if result.effect == "updated":
        return "updated"
    return "none"


def _recovery_incident_effect(
    result: LifecycleResult,
) -> Literal["none", "resolved", "affected_set_shrunk"]:
    if result.effect == "resolved":
        return "resolved"
    if result.effect == "affected_set_shrunk":
        return "affected_set_shrunk"
    return "none"


def _recovery_resolution_for_audit(
    result: LifecycleResult,
) -> Literal["noop", "resolved", "affected_set_shrunk"]:
    if result.effect == "resolved":
        return "resolved"
    if result.effect == "affected_set_shrunk":
        return "affected_set_shrunk"
    return "noop"


def _safe_rule_name(decision: dict[str, object] | None) -> str | None:
    if not isinstance(decision, dict):
        return None
    name = decision.get("rule_name")
    if isinstance(name, str):
        return name
    return None


def _safe_threshold_count(decision: dict[str, object] | None) -> int | None:
    if not isinstance(decision, dict):
        return None
    td = decision.get("threshold_decision")
    if not isinstance(td, dict):
        return None
    raw = td.get("threshold")
    if isinstance(raw, int):
        return raw
    return None


def _incident_effects(
    result: IncidentAggregationResult | None,
) -> IncidentEffectSummary:
    if result is None:
        return IncidentEffectSummary(inserted=0, updated=0)
    if result.effect == "inserted":
        return IncidentEffectSummary(inserted=1, updated=0)
    return IncidentEffectSummary(inserted=0, updated=1)


def _lifecycle_outcome(result: LifecycleResult | None) -> LifecycleOutcome | None:
    if result is None:
        return None
    return LifecycleOutcome(
        effect=result.effect,
        reason="source_recovery",
        previous_host_count=result.previous_host_count,
        previous_service_count=result.previous_service_count,
        affected_object_removed=result.affected_object_removed,
    )


RecoveryResolution = Literal["noop", "affected_set_shrunk", "resolved"]


def _recovery_resolution(result: LifecycleResult | None) -> RecoveryResolution | None:
    if result is None:
        return None
    if result.effect in ("noop", "affected_set_shrunk", "resolved"):
        return result.effect
    return None


def build_icinga2_processor(
    topology_path: Path | None = None,
    rules_path: Path | None = None,
    *,
    sessionmaker: Any | None = None,
    task_runner: TaskRunner | None = None,
    plugin_registry: object | None = None,
    audit_raw_payload_max_bytes: int,
    audit_raw_payload_hmac_key: str | Any,
) -> Icinga2DecisionProcessor:
    plugin = Icinga2InputPlugin()
    enricher: TopologyEnricher | None = None
    if topology_path is not None:
        from app.config.topology import load_topology_config
        from app.processing.enrichment import StaticTopologyEnricher

        config = load_topology_config(topology_path)
        enricher = StaticTopologyEnricher(config)

    rule_engine: RuleEngine | None = None
    if rules_path is not None:
        from app.config.rules import load_rules_config

        known_plugins = frozenset(getattr(plugin_registry, "names", ()))
        rules_config = load_rules_config(rules_path, known_plugins=known_plugins)
        rule_engine = RuleEngine(list(rules_config.rules))

    return Icinga2DecisionProcessor(
        plugin=plugin,
        topology_enricher=enricher,
        rule_engine=rule_engine,
        sessionmaker=sessionmaker,
        task_runner=task_runner,
        plugin_registry=plugin_registry,
        config_hash=getattr(plugin_registry, "config_hash", None),
        audit_raw_payload_max_bytes=audit_raw_payload_max_bytes,
        audit_raw_payload_hmac_key=audit_raw_payload_hmac_key,
    )
