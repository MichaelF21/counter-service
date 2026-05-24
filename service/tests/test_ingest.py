"""Tests for the optional /ingest endpoint and the IngestStore wrapper.

We don't spin up a real Postgres in the unit suite — the underlying
asyncpg pool is mocked. Live integration is covered by manual evidence
(crossplane/evidence/ingest-smoke.txt) once Postgres is reachable.
"""

from datetime import date

import pytest
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.ingest import IngestPayload, IngestStore, _build_dsn
from app.main import create_app


def test_payload_rejects_negative_counter():
    with pytest.raises(ValueError):
        IngestPayload(date=date(2026, 1, 1), counter_values=-1, restart_count=0)


def test_dsn_built_from_parts_when_no_full_dsn():
    s = Settings(
        ingest_enabled=True,
        pg_host="db",
        pg_port=5432,
        pg_database="x",
        pg_username="u",
        pg_password="p",
    )
    assert _build_dsn(s) == "postgresql://u:p@db:5432/x"


def test_dsn_uses_pg_dsn_when_provided():
    s = Settings(ingest_enabled=True, pg_dsn="postgresql://override@h/db")
    assert _build_dsn(s) == "postgresql://override@h/db"


def test_insert_sql_quotes_identifiers():
    s = Settings(ingest_enabled=True, pg_schema="my_schema", pg_table="my_table")
    store = IngestStore(s)
    assert store._insert_sql.startswith('INSERT INTO "my_schema"."my_table"')
    assert '"date"' in store._insert_sql


async def test_insert_raises_when_not_connected():
    store = IngestStore(Settings(ingest_enabled=True))
    with pytest.raises(RuntimeError, match="not connected"):
        await store.insert(IngestPayload(date=date(2026, 1, 1), counter_values=1, restart_count=1))


async def test_close_is_noop_when_never_connected():
    store = IngestStore(Settings(ingest_enabled=True))
    await store.close()  # should not raise


async def test_ingest_endpoint_returns_503_when_disabled():
    settings = Settings(
        backend="memory", app_version="t", log_level="WARNING", ingest_enabled=False
    )
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            r = await ac.post(
                "/ingest",
                json={"date": "2026-01-01", "counter_values": 5, "restart_count": 1},
            )
            assert r.status_code == 503
            assert "disabled" in r.text


async def test_ingest_endpoint_rejects_bad_payload():
    settings = Settings(
        backend="memory", app_version="t", log_level="WARNING", ingest_enabled=False
    )
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            r = await ac.post("/ingest", json={"date": "not-a-date"})
            assert r.status_code == 422


async def test_ingest_endpoint_succeeds_with_mocked_store(monkeypatch):
    """End-to-end through the FastAPI route, with the IngestStore.connect
    monkey-patched to skip the real asyncpg pool init."""

    inserted = []

    class FakeStore:
        async def connect(self):
            pass

        async def insert(self, payload):
            inserted.append(payload)

        async def close(self):
            pass

    import app.main as main_mod

    def _fake_store(_settings):
        return FakeStore()

    monkeypatch.setattr(main_mod, "IngestStore", _fake_store)

    settings = Settings(
        backend="memory", app_version="t", log_level="WARNING",
        ingest_enabled=True, pg_database="counter_data",
    )
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            r = await ac.post(
                "/ingest",
                json={"date": "2026-01-01", "counter_values": 7, "restart_count": 2},
            )
            assert r.status_code == 201
            assert r.text.strip() == "ingested"
    assert len(inserted) == 1
    assert inserted[0].counter_values == 7
