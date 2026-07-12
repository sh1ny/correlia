#!/bin/sh
set -eu

if [ -z "${DATABASE_URL:-}" ]; then
    printf '%s\n' 'Database configuration is required' >&2
    exit 1
fi

set +e
alembic upgrade head
migration_status=$?
set -e

if [ "$migration_status" -ne 0 ]; then
    printf 'Database migration failed (exit %s)\n' "$migration_status" >&2
    exit "$migration_status"
fi

exec uvicorn app.main:create_app --factory --host 0.0.0.0 --port 8000 --workers 1 --no-access-log
