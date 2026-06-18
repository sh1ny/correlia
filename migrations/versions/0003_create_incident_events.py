"""create incident_events

Revision ID: 0003_create_incident_events
Revises: 0002_add_threshold_state
Create Date: 2026-06-18 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0003_create_incident_events"
down_revision: Union[str, Sequence[str], None] = "0002_add_threshold_state"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "incident_events",
        sa.Column(
            "id",
            postgresql.UUID(as_uuid=True),
            primary_key=True,
            server_default=sa.text("gen_random_uuid()"),
        ),
        sa.Column(
            "accepted_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column("event_timestamp", sa.DateTime(timezone=True), nullable=False),
        sa.Column("source_id", sa.String(), nullable=False),
        sa.Column("fingerprint", sa.String(), nullable=False),
        sa.Column("event_type", sa.String(), nullable=False),
        sa.Column("severity", sa.String(), nullable=False),
        sa.Column("host", sa.String(), nullable=False),
        sa.Column("service", sa.String(), nullable=True),
        sa.Column(
            "incident_ids",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column("incident_effect", sa.String(), nullable=False),
        sa.Column(
            "decision_summary",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "normalized_event",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column(
            "raw_payload",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("raw_payload_original_byte_length", sa.Integer(), nullable=False),
        sa.Column("raw_payload_stored_byte_length", sa.Integer(), nullable=False),
        sa.Column(
            "raw_payload_truncated",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
        sa.Column("redaction_version", sa.Integer(), nullable=False),
        sa.Column("redacted_path_count", sa.Integer(), nullable=False),
        sa.Column("raw_payload_hmac", sa.String(), nullable=False),
        sa.CheckConstraint(
            "event_type IN ('PROBLEM', 'RECOVERY')",
            name="ck_incident_events_event_type",
        ),
        sa.CheckConstraint(
            "severity IN ('OK', 'WARNING', 'UNKNOWN', 'CRITICAL')",
            name="ck_incident_events_severity",
        ),
        sa.CheckConstraint(
            "incident_effect IN ('none', 'inserted', 'updated', 'resolved', 'affected_set_shrunk')",
            name="ck_incident_events_incident_effect",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(incident_ids) = 'array'",
            name="ck_incident_events_incident_ids_array",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(decision_summary) = 'object'",
            name="ck_incident_events_decision_summary_object",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(normalized_event) = 'object'",
            name="ck_incident_events_normalized_event_object",
        ),
        sa.CheckConstraint(
            "jsonb_typeof(raw_payload) = 'object'",
            name="ck_incident_events_raw_payload_object",
        ),
        sa.CheckConstraint(
            "raw_payload_original_byte_length >= 0 AND raw_payload_stored_byte_length >= 0",
            name="ck_incident_events_raw_payload_byte_lengths_non_negative",
        ),
        sa.CheckConstraint(
            "raw_payload_stored_byte_length <= raw_payload_original_byte_length",
            name="ck_incident_events_raw_payload_stored_lte_original",
        ),
        sa.CheckConstraint(
            "redaction_version >= 1",
            name="ck_incident_events_redaction_version_positive",
        ),
        sa.CheckConstraint(
            "redacted_path_count >= 0",
            name="ck_incident_events_redacted_path_count_non_negative",
        ),
    )
    op.create_index(
        "ix_incident_events_accepted_at_id",
        "incident_events",
        ["accepted_at", "id"],
    )
    op.create_index(
        "ix_incident_events_incident_ids_gin",
        "incident_events",
        ["incident_ids"],
        postgresql_using="gin",
    )
    op.create_index("ix_incident_events_fingerprint", "incident_events", ["fingerprint"])
    op.create_index("ix_incident_events_source_id", "incident_events", ["source_id"])
    op.create_index("ix_incident_events_event_type", "incident_events", ["event_type"])
    op.create_index("ix_incident_events_severity", "incident_events", ["severity"])
    op.create_index("ix_incident_events_host", "incident_events", ["host"])
    op.create_index("ix_incident_events_service", "incident_events", ["service"])
    op.create_index(
        "ix_incident_events_incident_effect", "incident_events", ["incident_effect"]
    )
    op.create_index(
        "ix_incident_events_event_timestamp", "incident_events", ["event_timestamp"]
    )
    op.create_index(
        "ix_incident_events_no_dispatch_reason",
        "incident_events",
        [sa.text("(decision_summary ->> 'no_dispatch_reason')")],
    )


def downgrade() -> None:
    op.drop_index("ix_incident_events_no_dispatch_reason", table_name="incident_events")
    op.drop_index("ix_incident_events_event_timestamp", table_name="incident_events")
    op.drop_index("ix_incident_events_incident_effect", table_name="incident_events")
    op.drop_index("ix_incident_events_service", table_name="incident_events")
    op.drop_index("ix_incident_events_host", table_name="incident_events")
    op.drop_index("ix_incident_events_severity", table_name="incident_events")
    op.drop_index("ix_incident_events_event_type", table_name="incident_events")
    op.drop_index("ix_incident_events_source_id", table_name="incident_events")
    op.drop_index("ix_incident_events_fingerprint", table_name="incident_events")
    op.drop_index("ix_incident_events_incident_ids_gin", table_name="incident_events")
    op.drop_index("ix_incident_events_accepted_at_id", table_name="incident_events")
    op.drop_table("incident_events")
