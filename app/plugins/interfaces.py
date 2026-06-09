from __future__ import annotations

from typing import TYPE_CHECKING, Annotated, Protocol

from pydantic import BaseModel, ConfigDict, Field

from app.domain.events import Severity
from app.domain.events import NormalizedEvent

if TYPE_CHECKING:
    from app.plugins.inputs.icinga2 import Icinga2Rejection
    from app.processing.enrichment import EnrichmentResult

BoundedString = Annotated[str, Field(min_length=1, max_length=256)]


class PluginStatus(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    plugin_type: BoundedString
    ready: bool
    status: BoundedString


class NotificationEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    incident_id: BoundedString
    rule_name: BoundedString
    group_key: BoundedString
    severity: Severity
    summary: BoundedString
    affected_hosts: tuple[BoundedString, ...] = Field(default_factory=tuple, max_length=100)
    affected_services: tuple[BoundedString, ...] = Field(default_factory=tuple, max_length=100)



class OutputPlugin(Protocol):
    async def send_notification(self, envelope: NotificationEnvelope) -> None: ...

    def plugin_status(self) -> PluginStatus: ...
class InputPlugin(Protocol):
    async def process_payload(
        self, payload: object
    ) -> NormalizedEvent | "Icinga2Rejection": ...


class TopologyEnricher(Protocol):
    async def enrich(self, event: NormalizedEvent) -> "EnrichmentResult": ...
