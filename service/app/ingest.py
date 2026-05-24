"""Optional /ingest sink that writes counter samples into a Postgres table
provisioned by the Crossplane XAppDatabase API (Task 2).

Module is intentionally thin:
  - lazy connection-pool init from Settings
  - one INSERT per /ingest call (asyncpg, parameterised)
  - graceful shutdown via close()

The Postgres backend is OPTIONAL — counter-service runs fine without it.
The endpoint returns 503 when COUNTER_INGEST_ENABLED is false.
"""

from __future__ import annotations

from datetime import date, datetime

import asyncpg
from pydantic import BaseModel, Field

from app.config import Settings


class IngestPayload(BaseModel):
    """Request body for POST /ingest."""

    date: date
    counter_values: int = Field(ge=0)
    restart_count: int = Field(ge=0)


def _build_dsn(s: Settings) -> str:
    if s.pg_dsn:
        return s.pg_dsn
    return (
        f"postgresql://{s.pg_username}:{s.pg_password}"
        f"@{s.pg_host}:{s.pg_port}/{s.pg_database}"
    )


class IngestStore:
    """asyncpg connection pool + parameterised INSERT.

    A single pool per process. The table identifier is interpolated into the
    SQL statement because asyncpg doesn't parameterise identifiers — we
    validate it (and the schema) at config time via Settings to keep this
    safe from injection.
    """

    def __init__(self, settings: Settings) -> None:
        self._settings = settings
        self._pool: asyncpg.Pool | None = None
        # The schema + table are operator-supplied (via env wired from a
        # Crossplane-rendered Secret). Quoting them with " " makes the names
        # case-preserving and blocks SQL injection on these identifiers; we
        # additionally validate them in the XRD's OpenAPI schema upstream.
        self._insert_sql = (
            f'INSERT INTO "{settings.pg_schema}"."{settings.pg_table}" '
            f'("date", "counter_values", "restart_count") VALUES ($1, $2, $3)'
        )

    async def connect(self) -> None:
        if self._pool is None:
            self._pool = await asyncpg.create_pool(
                _build_dsn(self._settings),
                min_size=1,
                max_size=5,
                command_timeout=5,
            )

    async def insert(self, payload: IngestPayload) -> None:
        if self._pool is None:
            raise RuntimeError("IngestStore not connected")
        # asyncpg expects datetime for timestamp columns; normalise date -> midnight.
        ts = datetime.combine(payload.date, datetime.min.time())
        async with self._pool.acquire() as conn:
            await conn.execute(
                self._insert_sql,
                ts,
                payload.counter_values,
                payload.restart_count,
            )

    async def close(self) -> None:
        if self._pool is not None:
            await self._pool.close()
            self._pool = None
