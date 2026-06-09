from __future__ import annotations

from datetime import datetime
from typing import Annotated, Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.domain.events import Severity, TagKey, TagValue
from app.domain.incidents import LifecycleOutcome


BoundedString = Annotated[str, Field(min_length=1, max_length=256)]
BoundedStringTuple = Annotated[tuple[BoundedString, ...], Field(max_length=20)]


class MatchCriteria(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    severities: list[Severity]
    host_pattern: BoundedString
    service_pattern: BoundedString | None = None
    tags: dict[TagKey, TagValue] = Field(default_factory=dict)


class RuleAction(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    name: BoundedString
    plugin: BoundedString


class RuleWindow(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    duration_seconds: int = Field(ge=1)
    group_by: list[BoundedString] = Field(min_length=1)
    trigger_threshold: int = Field(ge=1)


class RuleDefinition(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    name: BoundedString
    priority: int
    match: MatchCriteria
    window: RuleWindow
    output_summary: BoundedString
    actions: list[RuleAction] = Field(default_factory=list)

    @field_validator("actions", mode="after")
    @classmethod
    def _actions_not_empty(cls, value: list[RuleAction]) -> list[RuleAction]:
        if not value:
            raise ValueError("actions must not be empty")
        return value


class ThresholdDecision(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    rule_name: BoundedString
    group_key: BoundedString
    window_start: datetime
    window_end: datetime
    threshold: int = Field(ge=1)
    counted_fingerprints: list[BoundedString] = Field(default_factory=list)
    counted: int = Field(default=0, ge=0)
    crossed: bool
    replay_or_skip_reasons: list[str] = Field(default_factory=list)


class RuleDecision(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    rule_name: BoundedString
    priority: int
    matched_rules: list[BoundedString] = Field(default_factory=list)
    group_key: BoundedString
    threshold_decision: ThresholdDecision
    summary: BoundedString
    actions: list[BoundedString] = Field(default_factory=list)


class NoOpDecision(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    schema_version: Literal[1] = 1
    matched_rules: list[BoundedString] = Field(default_factory=list)
    reason: Annotated[str, Field(min_length=1)]


class IncidentEffectSummary(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    inserted: int = Field(default=0, ge=0)
    updated: int = Field(default=0, ge=0)


NotificationCategory = Literal[
    "dispatched",
    "missing_plugin",
    "missing_incident",
    "plugin_exception",
    "dispatch_failed",
]


class NotificationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    success: bool
    category: NotificationCategory
    message: Annotated[str, Field(min_length=1, max_length=256)]

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
    lifecycle_outcome: LifecycleOutcome | None = None
    recovery_resolution: Literal["noop", "affected_set_shrunk", "resolved"] | None = None
    affected_object_removed: bool = False
    incident_id: UUID | None = None
    threshold_crossed: bool = False
    notification_triggered: bool = False
    notification_failed: bool = False
    no_dispatch_reason: BoundedString | None = None
    notification_results: tuple[NotificationResult, ...] = Field(default_factory=tuple, max_length=20)
    notification_count: int = Field(default=0, ge=0)
    rejection: dict[str, object] | None = None
