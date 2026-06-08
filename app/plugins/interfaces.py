from __future__ import annotations

from typing import TYPE_CHECKING, Protocol

from app.domain.events import NormalizedEvent

if TYPE_CHECKING:
    from app.plugins.inputs.icinga2 import Icinga2Rejection
    from app.processing.enrichment import EnrichmentResult


class InputPlugin(Protocol):
    async def process_payload(
        self, payload: object
    ) -> NormalizedEvent | "Icinga2Rejection": ...


class TopologyEnricher(Protocol):
    async def enrich(self, event: NormalizedEvent) -> "EnrichmentResult": ...
