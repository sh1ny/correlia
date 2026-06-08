from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field

from app.domain.events import TagKey, TagValue


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]


class NoOpDecision(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    matched_rules: list[BoundedString] = Field(default_factory=list)
    reason: Annotated[str, Field(min_length=1)]


class IncidentEffectSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    inserted: int = Field(default=0, ge=0)
    updated: int = Field(default=0, ge=0)


class IngressDecisionEnvelope(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    state_accepted: bool
    event_id: BoundedString | None = None
    fingerprint: BoundedString | None = None
    source_id: BoundedString | None = None
    host: BoundedString | None = None
    service: BoundedString | None = None
    event_type: BoundedString | None = None
    severity: BoundedString | None = None
    final_tags: dict[TagKey, TagValue] = Field(default_factory=dict)
    enrichment_diagnostics: list[dict[str, object]] = Field(default_factory=list)
    matched_rules: list[BoundedString] = Field(default_factory=list)
    rule_decision: dict[str, object] | None = None
    group_key: BoundedString | None = None
    threshold_decision: dict[str, object] | None = None
    incident_effects: IncidentEffectSummary = Field(
        default_factory=lambda: IncidentEffectSummary(inserted=0, updated=0)
    )
    closure_count: int = Field(default=0, ge=0)
    notification_count: int = Field(default=0, ge=0)
    rejection: dict[str, object] | None = None
