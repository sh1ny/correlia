from __future__ import annotations

from collections.abc import Sequence
from email.message import EmailMessage
from typing import Annotated

import aiosmtplib
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.plugins.interfaces import NotificationEnvelope, PluginStatus

BoundedString = Annotated[str, Field(min_length=1, max_length=256)]


class SmtpOutputOptions(BaseModel):
    model_config = ConfigDict(strict=True, extra="forbid")

    host: BoundedString = "localhost"
    port: int = Field(default=1025, ge=1, le=65535)
    from_address: BoundedString = "correlia@localhost"
    to_addresses: list[BoundedString] = Field(default_factory=lambda: ["ops@localhost"], min_length=1, max_length=100)
    subject_prefix: str = Field(default="[Correlia]", max_length=64)
    username: str | None = Field(default=None, max_length=256)
    password: str | None = Field(default=None, max_length=256)
    use_tls: bool = False
    start_tls: bool | None = None
    validate_certs: bool = True
    timeout: float = Field(default=60.0, ge=0.1, le=120.0)

    @field_validator("to_addresses", mode="after")
    @classmethod
    def reject_blank_recipients(cls, value: list[str]) -> list[str]:
        for address in value:
            if not address.strip():
                raise ValueError("recipient addresses must not be blank")
        return value

    @model_validator(mode="after")
    def require_tls_for_credentials(self) -> "SmtpOutputOptions":
        has_username = self.username is not None
        has_password = self.password is not None
        if has_username != has_password:
            raise ValueError("SMTP username and password must be configured together")
        if not has_username:
            return self
        if not (self.use_tls or self.start_tls is True):
            raise ValueError("authenticated SMTP requires explicit TLS or STARTTLS")
        if not self.validate_certs:
            raise ValueError("authenticated SMTP requires certificate validation")
        return self


class SmtpOutputPlugin:
    def __init__(
        self,
        *,
        host: str = "localhost",
        port: int = 1025,
        from_address: str = "correlia@localhost",
        to_addresses: str | Sequence[str] = ("ops@localhost",),
        subject_prefix: str = "[Correlia]",
        username: str | None = None,
        password: str | None = None,
        use_tls: bool = False,
        start_tls: bool | None = None,
        validate_certs: bool = True,
        timeout: float = 60.0,
    ) -> None:
        recipients = [to_addresses] if isinstance(to_addresses, str) else list(to_addresses)
        self._options = SmtpOutputOptions.model_validate(
            {
                "host": host,
                "port": port,
                "from_address": from_address,
                "to_addresses": recipients,
                "subject_prefix": subject_prefix,
                "username": username,
                "password": password,
                "use_tls": use_tls,
                "start_tls": start_tls,
                "validate_certs": validate_certs,
                "timeout": timeout,
            }
        )

    def plugin_status(self) -> PluginStatus:
        return PluginStatus(plugin_type="email", ready=True, status="ready")

    async def send_notification(self, envelope: NotificationEnvelope) -> None:
        message = EmailMessage()
        message["From"] = self._options.from_address
        message["To"] = ", ".join(self._options.to_addresses)
        message["Subject"] = self._subject(envelope)
        message.set_content(self._body(envelope))

        await aiosmtplib.send(
            message,
            hostname=self._options.host,
            port=self._options.port,
            username=self._options.username,
            password=self._options.password,
            timeout=self._options.timeout,
            use_tls=self._options.use_tls,
            start_tls=self._options.start_tls,
            validate_certs=self._options.validate_certs,
        )

    def _subject(self, envelope: NotificationEnvelope) -> str:
        prefix = f"{self._options.subject_prefix} " if self._options.subject_prefix else ""
        return f"{prefix}[{envelope.severity.value}] {envelope.rule_name}: {envelope.summary}"

    @staticmethod
    def _body(envelope: NotificationEnvelope) -> str:
        hosts = ", ".join(envelope.affected_hosts) if envelope.affected_hosts else "none"
        services = ", ".join(envelope.affected_services) if envelope.affected_services else "none"
        return "\n".join(
            (
                f"Incident ID: {envelope.incident_id}",
                f"Rule: {envelope.rule_name}",
                f"Group key: {envelope.group_key}",
                f"Severity: {envelope.severity.value}",
                f"Summary: {envelope.summary}",
                f"Affected hosts: {hosts}",
                f"Affected services: {services}",
            )
        )
