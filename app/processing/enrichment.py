from __future__ import annotations

from dataclasses import dataclass, field
from ipaddress import ip_address

from app.config.topology import CompiledHostnameRule, CompiledSubnetRule, CompiledTopologyConfig
from app.domain.events import NormalizedEvent


@dataclass(frozen=True, slots=True)
class EnrichmentDiagnostic:
    rule_id: str
    rule_name: str
    match_source: str
    tags_added: dict[str, str]
    tags_overridden: list[tuple[str, str, str]] = field(default_factory=list)
    conflicts: list[tuple[str, str, str]] = field(default_factory=list)


@dataclass(frozen=True, slots=True)
class EnrichmentResult:
    event: NormalizedEvent
    diagnostics: list[EnrichmentDiagnostic] = field(default_factory=list)


class StaticTopologyEnricher:
    def __init__(self, config: CompiledTopologyConfig) -> None:
        self._config = config

    async def enrich(self, event: NormalizedEvent) -> EnrichmentResult:
        # Try hostname rules first (D-09: hostname precedence)
        for hostname_rule in self._config.hostname_rules:
            if hostname_rule.pattern.match(event.host):
                return self._apply_rule(event, hostname_rule, "hostname")

        # Subnet fallback only if no hostname match and event has an IP
        if event.ip_address is not None:
            try:
                addr = ip_address(event.ip_address)
            except ValueError:
                # Malformed IP address — skip subnet matching
                return EnrichmentResult(event=event, diagnostics=[])
            for subnet_rule in self._config.subnet_rules:
                if addr.version != subnet_rule.network.version:
                    continue
                if addr in subnet_rule.network:
                    return self._apply_rule(event, subnet_rule, "subnet")

        # No match
        return EnrichmentResult(event=event, diagnostics=[])

    def _apply_rule(
        self,
        event: NormalizedEvent,
        rule: CompiledHostnameRule | CompiledSubnetRule,
        match_source: str,
    ) -> EnrichmentResult:
        tags_added: dict[str, str] = {}
        tags_overridden: list[tuple[str, str, str]] = []
        conflicts: list[tuple[str, str, str]] = []

        new_tags = dict(event.tags)

        for key, value in rule.tags.items():
            if key in new_tags:
                old_value = new_tags[key]
                if old_value != value:
                    tags_overridden.append((key, old_value, value))
                    conflicts.append((key, old_value, value))
            else:
                tags_added[key] = value
            new_tags[key] = value

        enriched_event = event.model_copy(update={"tags": new_tags})
        diagnostic = EnrichmentDiagnostic(
            rule_id=rule.id,
            rule_name=rule.name,
            match_source=match_source,
            tags_added=tags_added,
            tags_overridden=tags_overridden,
            conflicts=conflicts,
        )
        return EnrichmentResult(event=enriched_event, diagnostics=[diagnostic])
