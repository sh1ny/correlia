from __future__ import annotations

from typing import TYPE_CHECKING, Any, Protocol

from app.domain.events import NormalizedEvent

if TYPE_CHECKING:
    from app.processing.enrichment import EnrichmentResult


class InputPlugin(Protocol):
    async def process_payload(self, payload: dict[str, Any]) -> NormalizedEvent: ...


class TopologyEnricher(Protocol):
    async def enrich(self, event: NormalizedEvent) -> "EnrichmentResult": ...
