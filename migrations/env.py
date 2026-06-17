import asyncio
import os
from logging.config import fileConfig

from alembic import context
from pydantic import PostgresDsn, TypeAdapter
from sqlalchemy import pool
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import async_engine_from_config

from app.persistence.models import Base

config = context.config

if config.attributes.get("configure_logger", True):
    fileConfig(config.config_file_name)

target_metadata = Base.metadata

_DATABASE_URL_ADAPTER = TypeAdapter(PostgresDsn)


def _database_url_from_env() -> str:
    database_url = os.environ.get("DATABASE_URL")
    if database_url is None or database_url.strip() == "":
        raise RuntimeError(
            "DATABASE_URL is required when -x database_url=... is not provided"
        )
    return str(_DATABASE_URL_ADAPTER.validate_python(database_url))


def get_database_url() -> str:
    runtime_url = None
    if hasattr(config.cmd_opts, "x") and config.cmd_opts.x is not None:
        for item in config.cmd_opts.x:
            if isinstance(item, str) and item.startswith("database_url="):
                runtime_url = item.split("=", 1)[1]
                break
    if runtime_url:
        return str(runtime_url)
    return _database_url_from_env()


def run_migrations_offline() -> None:
    url = get_database_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def do_run_migrations(connection: Connection) -> None:
    context.configure(connection=connection, target_metadata=target_metadata)

    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    alembic_config = config.get_section(config.config_ini_section, {})
    alembic_config["sqlalchemy.url"] = get_database_url()

    connectable = async_engine_from_config(
        alembic_config,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)

    await connectable.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())
