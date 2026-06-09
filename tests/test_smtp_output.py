from __future__ import annotations

import asyncio
from email import message_from_bytes
from email.policy import default

import pytest
from app.domain.events import Severity
from app.plugins.interfaces import NotificationEnvelope
from app.plugins.outputs.email import SmtpOutputPlugin


class SmtpCaptureServer:
    def __init__(self, server: asyncio.AbstractServer, messages: asyncio.Queue[bytes]) -> None:
        self._server = server
        self._messages = messages

    @property
    def port(self) -> int:
        socket = self._server.sockets[0]
        return int(socket.getsockname()[1])

    async def next_message(self) -> bytes:
        return await self._messages.get()

    async def close(self) -> None:
        self._server.close()
        await self._server.wait_closed()

    @classmethod
    async def start(cls) -> "SmtpCaptureServer":
        messages: asyncio.Queue[bytes] = asyncio.Queue()

        async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            writer.write(b"220 mailpit.local ESMTP\r\n")
            await writer.drain()
            while line := await reader.readline():
                command = line.decode("ascii", errors="ignore").strip()
                upper = command.upper()
                if upper.startswith("EHLO"):
                    writer.write(b"250-mailpit.local\r\n250 HELP\r\n")
                elif upper.startswith("HELO"):
                    writer.write(b"250 mailpit.local\r\n")
                elif upper.startswith("MAIL FROM") or upper.startswith("RCPT TO"):
                    writer.write(b"250 OK\r\n")
                elif upper == "DATA":
                    writer.write(b"354 End data with <CR><LF>.<CR><LF>\r\n")
                    await writer.drain()
                    data = bytearray()
                    while data_line := await reader.readline():
                        if data_line == b".\r\n":
                            break
                        data.extend(data_line)
                    await messages.put(bytes(data))
                    writer.write(b"250 queued\r\n")
                elif upper == "QUIT":
                    writer.write(b"221 bye\r\n")
                    await writer.drain()
                    writer.close()
                    await writer.wait_closed()
                    return
                else:
                    writer.write(b"250 OK\r\n")
                await writer.drain()

        server = await asyncio.start_server(handle, "127.0.0.1", 0)
        return cls(server, messages)


async def test_smtp_output_sends_mailpit_compatible_message_with_incident_fields() -> None:
    server = await SmtpCaptureServer.start()
    try:
        plugin = SmtpOutputPlugin(
            host="127.0.0.1",
            port=server.port,
            from_address="correlia@example.test",
            to_addresses=["ops@example.test"],
            subject_prefix="[Correlia]",
            timeout=5.0,
        )
        envelope = NotificationEnvelope(
            incident_id="550e8400-e29b-41d4-a716-446655440000",
            rule_name="database-critical",
            group_key="service=db",
            severity=Severity.CRITICAL,
            summary="database cluster unavailable",
            affected_hosts=("db-01", "db-02"),
            affected_services=("postgres",),
        )

        await plugin.send_notification(envelope)
        raw_message = await asyncio.wait_for(server.next_message(), timeout=2)
    finally:
        await server.close()

    message = message_from_bytes(raw_message, policy=default)
    body = message.get_content()

    assert message["From"] == "correlia@example.test"
    assert message["To"] == "ops@example.test"
    assert "[CRITICAL] database-critical: database cluster unavailable" in message["Subject"]
    assert "Incident ID: 550e8400-e29b-41d4-a716-446655440000" in body
    assert "Rule: database-critical" in body
    assert "Group key: service=db" in body
    assert "Severity: CRITICAL" in body
    assert "Summary: database cluster unavailable" in body
    assert "Affected hosts: db-01, db-02" in body
    assert "Affected services: postgres" in body


def test_smtp_output_status_is_safe_and_secret_free() -> None:
    plugin = SmtpOutputPlugin(username="operator", password="super-secret", start_tls=True)

    status = plugin.plugin_status().model_dump(mode="json")

    assert status == {"plugin_type": "email", "ready": True, "status": "ready"}
    assert "super-secret" not in repr(status)



@pytest.mark.parametrize(
    "kwargs, match",
    [
        ({"password": "super-secret"}, "username and password"),
        ({"username": "operator", "password": "super-secret"}, "requires explicit TLS"),
        (
            {"username": "operator", "password": "super-secret", "start_tls": True, "validate_certs": False},
            "certificate validation",
        ),
    ],
)
def test_smtp_output_rejects_unsafe_authenticated_configuration(
    kwargs: dict[str, object], match: str
) -> None:
    with pytest.raises(ValueError, match=match):
        SmtpOutputPlugin(**kwargs)