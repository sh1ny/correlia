from __future__ import annotations

import logging
from collections.abc import Mapping
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.domain.events import Severity
from app.domain.rules import NotificationCategory, NotificationResult
from app.persistence.incidents import record_notification_result
from app.persistence.models import Incident
from app.plugins.interfaces import NotificationEnvelope
from app.processing.metrics import record_notification_attempt, record_notification_failure

logger = logging.getLogger(__name__)


class NotificationTaskPayload(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    incident_id: UUID
    plugin_name: str = Field(min_length=1, max_length=256)
    config_hash: str | None = Field(default=None, max_length=128)

    @field_validator("incident_id", mode="before")
    @classmethod
    def parse_incident_id(cls, value: object) -> object:
        if isinstance(value, str):
            return UUID(value)
        return value


class NotificationDispatcher:
    def __init__(self, session_factory: async_sessionmaker[AsyncSession], plugin_registry: Any) -> None:
        self._session_factory = session_factory
        self._plugin_registry = plugin_registry

    async def process(self, payload: Mapping[str, Any]) -> NotificationResult:
        try:
            task = NotificationTaskPayload.model_validate(dict(payload))
        except ValidationError:
            return _result(False, "dispatch_failed", "invalid notification task payload")

        registry_hash = getattr(self._plugin_registry, "config_hash", None)
        if (
            task.config_hash is not None
            and registry_hash is not None
            and task.config_hash != registry_hash
        ):
            result = _result(False, "dispatch_failed", "stale plugin configuration")
            record_notification_attempt(task.plugin_name, result.category)
            record_notification_failure(task.plugin_name, result.category)
            await self._record_if_incident_exists(task.incident_id, task.plugin_name, result)
            return result

        try:
            plugin = self._plugin_registry.get_plugin(task.plugin_name)
        except KeyError:
            result = _result(False, "missing_plugin", "configured output plugin is missing")
            record_notification_attempt(task.plugin_name, result.category)
            record_notification_failure(task.plugin_name, result.category)
            await self._record_if_incident_exists(task.incident_id, task.plugin_name, result)
            return result

        async with self._session_factory() as session:
            incident = await _load_incident(session, task.incident_id)
            if incident is None:
                result = _result(False, "missing_incident", "incident is missing")
                record_notification_attempt(task.plugin_name, result.category)
                record_notification_failure(task.plugin_name, result.category)
                return result
            envelope = _envelope_from_incident(incident)

        try:
            await plugin.send_notification(envelope)
        except Exception as exc:  # pragma: no cover - exercised by behavior tests
            logger.warning(
                "notification plugin raised",
                extra={"plugin_name": task.plugin_name, "exception_type": type(exc).__name__},
            )
            result = _result(False, "plugin_exception", f"plugin exception: {type(exc).__name__}")
            record_notification_attempt(task.plugin_name, result.category)
            record_notification_failure(task.plugin_name, result.category)
            await self._record_if_incident_exists(task.incident_id, task.plugin_name, result)
            return result

        result = _result(True, "dispatched", "notification dispatched")
        record_notification_attempt(task.plugin_name, result.category)
        await self._record_if_incident_exists(task.incident_id, task.plugin_name, result)
        return result

    async def _record_if_incident_exists(
        self, incident_id: UUID, plugin_name: str, result: NotificationResult
    ) -> None:
        async with self._session_factory() as session:
            await record_notification_result(session, incident_id, plugin_name, result)
            await session.commit()


def _result(success: bool, category: NotificationCategory, message: str) -> NotificationResult:
    return NotificationResult(success=success, category=category, message=message[:256])


async def _load_incident(session: AsyncSession, incident_id: UUID) -> Incident | None:
    result = await session.execute(select(Incident).where(Incident.id == incident_id))
    return result.scalar_one_or_none()


def _envelope_from_incident(incident: Incident) -> NotificationEnvelope:
    return NotificationEnvelope(
        incident_id=str(incident.id),
        rule_name=incident.rule_name,
        group_key=incident.group_key,
        severity=Severity(incident.severity),
        summary=incident.summary,
        affected_hosts=tuple(incident.affected_hosts),
        affected_services=tuple(incident.affected_services),
    )
