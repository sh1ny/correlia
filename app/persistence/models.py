"""SQLAlchemy declarative models for incident persistence."""

from __future__ import annotations

from datetime import datetime
from typing import Any
from uuid import UUID

from sqlalchemy import Boolean, DateTime, Integer, String, func
from sqlalchemy.dialects.postgresql import JSONB, UUID as PG_UUID
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column

OPEN_INCIDENT_UNIQUE_INDEX_NAME = "incidents_one_open_per_rule_group"
OPEN_INCIDENT_UNIQUE_PREDICATE_SQL = "status = 'OPEN'"


class Base(DeclarativeBase):
    pass


class Incident(Base):
    __tablename__ = "incidents"

    id: Mapped[UUID] = mapped_column(PG_UUID(as_uuid=True), primary_key=True)
    rule_name: Mapped[str] = mapped_column(String, nullable=False)
    group_key: Mapped[str] = mapped_column(String, nullable=False)
    status: Mapped[str] = mapped_column(String, nullable=False)
    severity: Mapped[str] = mapped_column(String, nullable=False)
    summary: Mapped[str] = mapped_column(String, nullable=False)
    event_count: Mapped[int] = mapped_column(nullable=False, default=1, server_default="1")
    affected_hosts: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default="'[]'::jsonb"
    )
    affected_services: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default="'[]'::jsonb"
    )
    decision_context: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    window_state: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    threshold_crossed: Mapped[bool] = mapped_column(nullable=False, default=False, server_default="false")
    notified_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    start_time: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    last_update_time: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    acknowledged_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    acknowledged_by: Mapped[str | None] = mapped_column(String, nullable=True)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default="now()"
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default="now()"
    )


class IncidentEvent(Base):
    __tablename__ = "incident_events"

    id: Mapped[UUID] = mapped_column(
        PG_UUID(as_uuid=True),
        primary_key=True,
        server_default=func.gen_random_uuid(),
    )
    accepted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
    event_timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False)
    source_id: Mapped[str] = mapped_column(String, nullable=False)
    fingerprint: Mapped[str] = mapped_column(String, nullable=False)
    event_type: Mapped[str] = mapped_column(String, nullable=False)
    severity: Mapped[str] = mapped_column(String, nullable=False)
    host: Mapped[str] = mapped_column(String, nullable=False)
    service: Mapped[str | None] = mapped_column(String, nullable=True)
    incident_ids: Mapped[list[str]] = mapped_column(
        JSONB, nullable=False, default=list, server_default="'[]'::jsonb"
    )
    incident_effect: Mapped[str] = mapped_column(String, nullable=False)
    decision_summary: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    normalized_event: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    raw_payload: Mapped[dict[str, Any]] = mapped_column(
        JSONB, nullable=False, default=dict, server_default="'{}'::jsonb"
    )
    raw_payload_original_byte_length: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_payload_stored_byte_length: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_payload_truncated: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=False, server_default="false"
    )
    redaction_version: Mapped[int] = mapped_column(Integer, nullable=False)
    redacted_path_count: Mapped[int] = mapped_column(Integer, nullable=False)
    raw_payload_hmac: Mapped[str] = mapped_column(String, nullable=False)
