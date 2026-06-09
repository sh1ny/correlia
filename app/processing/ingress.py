from __future__ import annotations

from pathlib import Path
from typing import Any

from app.domain.events import EventType, NormalizedEvent
from app.domain.incidents import LifecycleOutcome
from app.domain.rules import (
    IncidentEffectSummary,
    IngressDecisionEnvelope,
    NoOpDecision,
    RuleDecision,
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
    record_rule_matched,
)
from app.processing.task_runner import TaskRunner


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
    ) -> None:
        self._plugin = plugin
        self._topology_enricher = topology_enricher
        self._rule_engine = rule_engine
        self._sessionmaker = sessionmaker
        self._task_runner = task_runner
        self._plugin_registry = plugin_registry
        self._config_hash = config_hash

    async def process_payload(
        self, payload: Icinga2WebhookPayload
    ) -> IngressDecisionEnvelope:
        plugin_result = await self._plugin.process_payload(payload)

        if isinstance(plugin_result, Icinga2Rejection):
            record_event_rejected(plugin_result.reason)
            return IngressDecisionEnvelope(
                state_accepted=False,
                source_id=plugin_result.source_id,
                host=plugin_result.host,
                service=plugin_result.service,
                rejection=plugin_result.model_dump(mode="json"),
            )

        event = plugin_result
        record_event_accepted(event.event_type.value)
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

        matched_rules: list[str] = []
        rule_decision: dict[str, object] | None = None
        group_key: str | None = None
        threshold_decision: dict[str, object] | None = None
        incident_result: IncidentAggregationResult | None = None
        lifecycle_result: LifecycleResult | None = None
        if self._rule_engine is not None:
            decision = await self._rule_engine.evaluate(event)
            rule_decision = decision.model_dump(mode="json")
            if isinstance(decision, RuleDecision):
                matched_rules = list(decision.matched_rules)
                for rule_name in matched_rules:
                    record_rule_matched(rule_name)
                group_key = decision.group_key
                if event.event_type is EventType.PROBLEM:
                    threshold_decision = decision.threshold_decision.model_dump(mode="json")
                    if self._sessionmaker is not None:
                        incident_result = await self._apply_problem(event, decision)
            elif event.event_type is not EventType.RECOVERY:
                matched_rules = list(decision.matched_rules)
            if event.event_type is EventType.RECOVERY and self._sessionmaker is not None:
                lifecycle_result = await self._apply_recovery(event)
                matched_rules = list(decision.matched_rules)
        else:
            rule_decision = NoOpDecision(reason="no matching rule").model_dump(
                mode="json"
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
            recovery_resolution=(
                lifecycle_result.effect if lifecycle_result is not None else None
            ),
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
            notification_triggered=(
                incident_result.notification_triggered if incident_result is not None else False
            ),
            notification_failed=(
                incident_result.notification_failed if incident_result is not None else False
            ),
            no_dispatch_reason=(
                incident_result.no_dispatch_reason if incident_result is not None else None
            ),
            notification_results=(
                incident_result.notification_results if incident_result is not None else ()
            ),
            notification_count=(
                sum(1 for result in incident_result.notification_results if result.success)
                if incident_result is not None
                else 0
            ),
            rejection=None,
        )

    async def _apply_problem(
        self, event: NormalizedEvent, decision: RuleDecision
    ) -> IncidentAggregationResult:
        sessionmaker = self._sessionmaker
        if sessionmaker is None:
            raise RuntimeError("sessionmaker is required for problem aggregation")
        async with sessionmaker() as session:
            manager = IncidentManager(
                session,
                task_runner=self._task_runner,
                plugin_registry=self._plugin_registry,
                config_hash=self._config_hash,
            )
            return await manager.apply_problem(event, decision)

    async def _apply_recovery(self, event: NormalizedEvent) -> LifecycleResult:
        sessionmaker = self._sessionmaker
        if sessionmaker is None:
            raise RuntimeError("sessionmaker is required for recovery resolution")
        async with sessionmaker() as session:
            manager = LifecycleManager(session)
            return await manager.resolve_for_event(event)



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


def build_icinga2_processor(
    topology_path: Path | None = None,
    rules_path: Path | None = None,
    *,
    sessionmaker: Any | None = None,
    task_runner: TaskRunner | None = None,
    plugin_registry: object | None = None,
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
    )
