FROM python:3.14.7-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:0.11.7 /uv /uvx /bin/

WORKDIR /app
ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

COPY pyproject.toml uv.lock ./
RUN uv sync --locked --no-dev --no-install-project


FROM python:3.14.7-slim

WORKDIR /app
ENV PATH="/app/.venv/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --system correlia \
    && useradd --system --gid correlia --home-dir /app --shell /usr/sbin/nologin correlia

COPY --from=builder --chown=correlia:correlia /app/.venv /app/.venv
COPY --chown=correlia:correlia app ./app
COPY --chown=correlia:correlia migrations ./migrations
COPY --chown=correlia:correlia config ./config
COPY --chown=correlia:correlia alembic.ini ./alembic.ini
COPY --chown=correlia:correlia --chmod=755 scripts/container-entrypoint.sh ./scripts/container-entrypoint.sh

USER correlia

ENTRYPOINT ["/app/scripts/container-entrypoint.sh"]
