from pathlib import Path
from typing import Literal, Self

from pydantic import Field, PostgresDsn, SecretStr, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="CORRELIA_",
        case_sensitive=False,
        extra="forbid",
    )

    database_url: PostgresDsn = Field(validation_alias="DATABASE_URL")
    environment: Literal["local", "test", "production"] = "local"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    rules_path: Path | None = None
    topology_path: Path | None = None
    plugins_path: Path | None = None
    lifecycle_scan_interval_seconds: int = Field(default=30, ge=1, le=86_400)
    lifecycle_batch_size: int = Field(default=100, ge=1, le=1_000)

    # Security and HTTP-control settings (Phase 5)
    api_auth_enabled: bool = True
    operator_api_token: SecretStr | None = None
    ingress_api_token: SecretStr | None = None

    expose_readyz: bool = True
    expose_metrics: bool = True

    max_body_bytes: int = Field(default=1_048_576, ge=1_024)
    max_body_bytes_operator: int | None = Field(default=None, ge=1_024)
    max_body_bytes_ingress: int | None = Field(default=None, ge=1_024)
    max_body_bytes_metrics: int | None = Field(default=None, ge=1_024)
    max_body_bytes_readyz: int | None = Field(default=None, ge=1_024)
    max_body_bytes_health: int | None = Field(default=None, ge=1_024)

    rate_limit_enabled: bool = True
    rate_limit_requests_operator: int = Field(default=60, ge=1)
    rate_limit_window_seconds_operator: int = Field(default=60, ge=1)
    rate_limit_requests_ingress: int = Field(default=120, ge=1)
    rate_limit_window_seconds_ingress: int = Field(default=60, ge=1)
    rate_limit_requests_metrics: int = Field(default=30, ge=1)
    rate_limit_window_seconds_metrics: int = Field(default=60, ge=1)
    rate_limit_requests_readyz: int = Field(default=60, ge=1)
    rate_limit_window_seconds_readyz: int = Field(default=60, ge=1)
    rate_limit_requests_health: int = Field(default=120, ge=1)
    rate_limit_window_seconds_health: int = Field(default=60, ge=1)
    rate_limit_sweep_interval_seconds: int = Field(default=60, ge=1, le=3600)

    @model_validator(mode="after")
    def _require_security_tokens_when_enabled(self) -> Self:
        if not self.api_auth_enabled:
            return self
        operator_value: str | None = (
            self.operator_api_token.get_secret_value()
            if self.operator_api_token is not None
            else None
        )
        ingress_value: str | None = (
            self.ingress_api_token.get_secret_value()
            if self.ingress_api_token is not None
            else None
        )
        missing: list[str] = []
        if operator_value is None:
            missing.append("operator_api_token")
        elif operator_value.strip() == "":
            missing.append("operator_api_token")
        if ingress_value is None:
            missing.append("ingress_api_token")
        elif ingress_value.strip() == "":
            missing.append("ingress_api_token")
        if missing:
            raise ValueError(
                f"api_auth_enabled requires non-empty values for: {', '.join(missing)}"
            )
        if operator_value == ingress_value:
            raise ValueError(
                "api_auth_enabled requires distinct operator_api_token and ingress_api_token"
            )
        return self


def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
