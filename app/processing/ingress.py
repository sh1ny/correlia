from __future__ import annotations

from pathlib import Path

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
from app.plugins.interfaces import TopologyEnricher
from app.processing.rule_engine import RuleEngine


class Icinga2DecisionProcessor:
    def __init__(
        self,
        plugin: Icinga2InputPlugin,
        topology_enricher: TopologyEnricher | None = None,
        rule_engine: RuleEngine | None = None,
    ) -> None:
        self._plugin = plugin
        self._topology_enricher = topology_enricher
        self._rule_engine = rule_engine

    async def process_payload(
        self, payload: Icinga2WebhookPayload
    ) -> IngressDecisionEnvelope:
        plugin_result = await self._plugin.process_payload(payload)

        if isinstance(plugin_result, Icinga2Rejection):
            return IngressDecisionEnvelope(
                state_accepted=False,
                source_id=plugin_result.source_id,
                host=plugin_result.host,
                service=plugin_result.service,
                rejection=plugin_result.model_dump(mode="json"),
            )

        event = plugin_result
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

        if self._rule_engine is not None:
            decision = await self._rule_engine.evaluate(event)
            rule_decision = decision.model_dump(mode="json")
            if isinstance(decision, RuleDecision):
                matched_rules = list(decision.matched_rules)
                group_key = decision.group_key
                threshold_decision = decision.threshold_decision.model_dump(
                    mode="json"
                )
            else:
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
            incident_effects=IncidentEffectSummary(inserted=0, updated=0),
            closure_count=0,
            notification_count=0,
            rejection=None,
        )


def build_icinga2_processor(
    topology_path: Path | None = None,
    rules_path: Path | None = None,
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

        rules_config = load_rules_config(rules_path)
        rule_engine = RuleEngine(list(rules_config.rules))

    return Icinga2DecisionProcessor(
        plugin=plugin,
        topology_enricher=enricher,
        rule_engine=rule_engine,
    )
