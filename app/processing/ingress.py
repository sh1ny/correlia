from __future__ import annotations

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


class Icinga2DecisionProcessor:
    def __init__(self, plugin: Icinga2InputPlugin) -> None:
        self._plugin = plugin

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
            enrichment_diagnostics=[],
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


def build_icinga2_processor() -> Icinga2DecisionProcessor:
    return Icinga2DecisionProcessor(plugin=Icinga2InputPlugin())
