from __future__ import annotations

import hashlib
import secrets
from typing import Annotated

from fastapi import Depends, HTTPException, Security, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.api.deps import get_app_settings
from app.config.settings import Settings

_security = HTTPBearer(auto_error=False)


class Unauthorized(HTTPException):
    def __init__(self) -> None:
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="unauthorized",
            headers={"WWW-Authenticate": "Bearer"},
        )


def _token_matches(
    credentials: HTTPAuthorizationCredentials | None, expected: str | None
) -> bool:
    if expected is None or credentials is None:
        return False
    try:
        return secrets.compare_digest(credentials.credentials, expected)
    except TypeError:
        return False


def require_operator_token(
    settings: Annotated[Settings, Depends(get_app_settings)],
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    if not settings.api_auth_enabled:
        return
    expected = (
        settings.operator_api_token.get_secret_value()
        if settings.operator_api_token is not None
        else None
    )
    if not _token_matches(credentials, expected):
        raise Unauthorized()


def require_ingress_token(
    settings: Annotated[Settings, Depends(get_app_settings)],
    credentials: HTTPAuthorizationCredentials | None = Security(_security),
) -> None:
    if not settings.api_auth_enabled:
        return
    expected = (
        settings.ingress_api_token.get_secret_value()
        if settings.ingress_api_token is not None
        else None
    )
    if not _token_matches(credentials, expected):
        raise Unauthorized()


def bearer_identity_hash(
    credentials: HTTPAuthorizationCredentials | None,
) -> str | None:
    if credentials is None:
        return None
    return hashlib.sha256(credentials.credentials.encode()).hexdigest()
