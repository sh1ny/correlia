"""create incidents

Revision ID: 0001_create_incidents
Revises: 
Create Date: 2026-06-08 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0001_create_incidents"
down_revision: Union[str, Sequence[str], None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "incidents",
        sa.Column("id", postgresql.UUID(as_uuid=True), primary_key=True),
        sa.Column("rule_name", sa.String(), nullable=False),
        sa.Column("group_key", sa.String(), nullable=False),
        sa.Column("status", sa.String(), nullable=False),
        sa.Column("severity", sa.String(), nullable=False),
        sa.Column("summary", sa.String(), nullable=False),
        sa.Column("event_count", sa.Integer(), nullable=False, server_default="1"),
        sa.Column(
            "affected_hosts",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column(
            "affected_services",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'[]'::jsonb"),
        ),
        sa.Column(
            "decision_context",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
        sa.Column("start_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("last_update_time", sa.DateTime(timezone=True), nullable=False),
        sa.Column("acknowledged_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("acknowledged_by", sa.String(), nullable=True),
        sa.Column("resolved_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            nullable=False,
            server_default=sa.func.now(),
        ),
        sa.CheckConstraint(
            "status IN ('OPEN', 'RESOLVED', 'CLOSED')",
            name="ck_incidents_status",
        ),
        sa.CheckConstraint(
            "severity IN ('OK', 'WARNING', 'UNKNOWN', 'CRITICAL')",
            name="ck_incidents_severity",
        ),
        sa.CheckConstraint(
            "event_count >= 1",
            name="ck_incidents_event_count_positive",
        ),
    )
    op.create_index(
        "incidents_one_open_per_rule_group",
        "incidents",
        ["rule_name", "group_key"],
        unique=True,
        postgresql_where=sa.text("status = 'OPEN'"),
    )


def downgrade() -> None:
    op.drop_index("incidents_one_open_per_rule_group", table_name="incidents")
    op.drop_table("incidents")
