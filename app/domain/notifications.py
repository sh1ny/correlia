from __future__ import annotations

from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field


NotificationCategory = Literal[
    "dispatched",
    "missing_plugin",
    "missing_incident",
    "plugin_exception",
    "dispatch_failed",
]

BoundedNotificationString = Annotated[str, Field(min_length=1, max_length=256)]


class NotificationResult(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    success: bool
    category: NotificationCategory
    message: BoundedNotificationString


class NotificationDeliveryRecord(BaseModel):
    """Latest terminal delivery result retained for one output plugin."""

    model_config = ConfigDict(strict=True, extra="forbid", frozen=True)

    schema_version: Literal[1] = 1
    plugin_name: BoundedNotificationString
    result: NotificationResult
