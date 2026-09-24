"""add threshold state

Revision ID: 0002_add_threshold_state
Revises: 0001_create_incidents
Create Date: 2026-06-09 00:00:00.000000

"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = "0002_add_threshold_state"
down_revision: Union[str, Sequence[str], None] = "0001_create_incidents"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        "incidents",
        sa.Column(
            "window_state",
            postgresql.JSONB(),
            nullable=False,
            server_default=sa.text("'{}'::jsonb"),
        ),
    )
    op.add_column(
        "incidents",
        sa.Column(
            "threshold_crossed",
            sa.Boolean(),
            nullable=False,
            server_default=sa.text("false"),
        ),
    )
    op.add_column(
        "incidents",
        sa.Column("notified_at", sa.DateTime(timezone=True), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("incidents", "notified_at")
    op.drop_column("incidents", "threshold_crossed")
    op.drop_column("incidents", "window_state")
