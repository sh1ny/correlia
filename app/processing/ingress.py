from __future__ import annotations

from pathlib import Path

from app.domain.rules import (
    IncidentEffectSummary,
    IngressDecisionEnvelope,
    NoOpDecision,
)
from app.plugins.inputs.icinga2 import (
    Icinga2InputPlugin,
    Icinga2Rejection,
    Icinga2WebhookPayload,
)
from app.plugins.interfaces import TopologyEnricher


class Icinga2DecisionProcessor:
    def __init__(
        self,
        plugin: Icinga2InputPlugin,
        topology_enricher: TopologyEnricher | None = None,
    ) -> None:
        self._plugin = plugin
        self._topology_enricher = topology_enricher

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
            matched_rules=[],
            rule_decision=NoOpDecision(
                reason="no matching rule"
            ).model_dump(mode="json"),
            group_key=None,
            threshold_decision=None,
            incident_effects=IncidentEffectSummary(inserted=0, updated=0),
            closure_count=0,
            notification_count=0,
            rejection=None,
        )


def build_icinga2_processor(
    topology_path: Path | None = None,
) -> Icinga2DecisionProcessor:
    plugin = Icinga2InputPlugin()
    enricher: TopologyEnricher | None = None
    if topology_path is not None:
        from app.config.topology import load_topology_config
        from app.processing.enrichment import StaticTopologyEnricher

        config = load_topology_config(topology_path)
        enricher = StaticTopologyEnricher(config)
    return Icinga2DecisionProcessor(plugin=plugin, topology_enricher=enricher)
