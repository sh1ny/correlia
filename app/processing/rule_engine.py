from __future__ import annotations

from datetime import datetime, timedelta

from app.config.rules import CompiledRule
from app.domain.events import NormalizedEvent
from app.domain.rules import NoOpDecision, RuleDecision, ThresholdDecision


class RuleEngine:
    def __init__(self, rules: list[CompiledRule]) -> None:
        self._rules = sorted(rules, key=lambda r: r.definition.priority)
        # In-memory threshold state: (rule_name, group_key) -> {fingerprint: timestamp}
        self._window_state: dict[tuple[str, str], dict[str, datetime]] = {}

    async def evaluate(self, event: NormalizedEvent) -> RuleDecision | NoOpDecision:
        if event.event_type.value == "RECOVERY":
            return NoOpDecision(reason="recovery events bypass rule aggregation")

        for compiled in self._rules:
            if self._matches_rule(compiled, event):
                group_key = self._build_group_key(compiled, event)
                if group_key is None:
                    missing = self._find_missing_group_field(compiled, event)
                    return NoOpDecision(
                        reason=f"missing required group-by field: {missing}"
                    )
                threshold_decision = self._evaluate_threshold(
                    compiled, group_key, event
                )
                summary = self._render_summary(
                    compiled.definition.output_summary, event
                )
                return RuleDecision(
                    rule_name=compiled.definition.name,
                    priority=compiled.definition.priority,
                    matched_rules=[compiled.definition.name],
                    group_key=group_key,
                    threshold_decision=threshold_decision,
                    summary=summary,
                    actions=[a.plugin for a in compiled.definition.actions],
                )

        return NoOpDecision(reason="no matching rule")

    def _matches_rule(self, compiled: CompiledRule, event: NormalizedEvent) -> bool:
        rule = compiled.definition
        if event.severity not in rule.match.severities:
            return False
        if not compiled.host_pattern.match(event.host):
            return False
        if compiled.service_pattern is not None:
            if event.service is None:
                return False
            if not compiled.service_pattern.match(event.service):
                return False
        for tag_key, tag_value in rule.match.tags.items():
            if event.tags.get(tag_key) != tag_value:
                return False
        return True

    def _build_group_key(
        self, compiled: CompiledRule, event: NormalizedEvent
    ) -> str | None:
        segments: list[str] = []
        for field in compiled.definition.window.group_by:
            value = self._resolve_field(field, event)
            if value is None:
                return None
            segments.append(f"{field}={value}")
        return "|".join(segments)

    def _find_missing_group_field(
        self, compiled: CompiledRule, event: NormalizedEvent
    ) -> str:
        for field in compiled.definition.window.group_by:
            if self._resolve_field(field, event) is None:
                return field
        return "unknown"

    def _resolve_field(self, field: str, event: NormalizedEvent) -> str | None:
        if field == "host":
            return event.host
        if field == "service":
            return event.service
        if field == "message":
            return event.message
        if field == "severity":
            return event.severity.value
        if field == "event_type":
            return event.event_type.value
        if field == "fingerprint":
            return event.fingerprint
        if field == "source_id":
            return event.source_id
        if field == "timestamp":
            return event.timestamp.isoformat()
        if field == "ip_address":
            return event.ip_address
        return event.tags.get(field)

    def _evaluate_threshold(
        self, compiled: CompiledRule, group_key: str, event: NormalizedEvent
    ) -> ThresholdDecision:
        rule = compiled.definition
        window_seconds = rule.window.duration_seconds
        threshold = rule.window.trigger_threshold
        key = (rule.name, group_key)

        window_end = event.timestamp
        window_start = window_end - timedelta(seconds=window_seconds)

        state = self._window_state.setdefault(key, {})
        # Prune old fingerprints outside the window
        stale = [fp for fp, ts in state.items() if ts < window_start]
        for fp in stale:
            del state[fp]

        replay_reasons: list[str] = []
        if event.fingerprint in state:
            replay_reasons.append(
                f"replay: fingerprint {event.fingerprint} already counted in window"
            )
        else:
            state[event.fingerprint] = event.timestamp

        counted_fingerprints = sorted(state.keys())
        counted = len(counted_fingerprints)
        crossed = counted >= threshold

        return ThresholdDecision(
            rule_name=rule.name,
            group_key=group_key,
            window_start=window_start,
            window_end=window_end,
            threshold=threshold,
            counted_fingerprints=counted_fingerprints,
            counted=counted,
            crossed=crossed,
            replay_or_skip_reasons=replay_reasons,
        )

    def _render_summary(self, template: str, event: NormalizedEvent) -> str:
        normalized_fields: dict[str, str | None] = {
            "host": event.host,
            "service": event.service,
            "message": event.message,
            "severity": event.severity.value,
            "event_type": event.event_type.value,
            "fingerprint": event.fingerprint,
            "source_id": event.source_id,
            "timestamp": event.timestamp.isoformat(),
            "ip_address": event.ip_address,
        }
        context: dict[str, str | None] = dict(event.tags)
        context.update(normalized_fields)
        # Safe substitution: missing keys leave the placeholder
        result = template
        for key, value in context.items():
            if value is not None:
                result = result.replace(f"{{{key}}}", str(value))
        return result
