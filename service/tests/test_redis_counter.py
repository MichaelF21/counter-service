"""Tests for RedisCounter using fakeredis.

fakeredis provides an in-memory implementation of the redis-py protocol so we
exercise the real CounterRepository implementation, not a stub. Closes the
coverage gap on RedisCounter (was 41% covered by constructor-only tests).
"""

import fakeredis.aioredis
import pytest

from app.counter import RedisCounter


@pytest.fixture
async def fake_client():
    client = fakeredis.aioredis.FakeRedis(decode_responses=True)
    try:
        yield client
    finally:
        await client.aclose()


@pytest.fixture
async def redis_counter(fake_client, monkeypatch):
    """Build a RedisCounter wired against fakeredis instead of a real server."""

    def _from_url(url: str, *args, **kwargs):
        return fake_client

    import app.counter as counter_mod

    monkeypatch.setattr(counter_mod.aioredis, "from_url", _from_url)
    rc = RedisCounter("redis://fake:6379/0", "test:counter", "test:restarts")
    yield rc


async def test_value_returns_zero_when_unset(redis_counter):
    assert await redis_counter.value() == 0


async def test_increment_sets_and_increments(redis_counter):
    assert await redis_counter.increment() == 1
    assert await redis_counter.increment() == 2
    assert await redis_counter.increment() == 3
    assert await redis_counter.value() == 3


async def test_value_reads_existing(redis_counter, fake_client):
    await fake_client.set("test:counter", "42")
    assert await redis_counter.value() == 42


async def test_restart_count_starts_zero(redis_counter):
    assert await redis_counter.restart_count() == 0


async def test_record_restart_is_independent_of_counter(redis_counter):
    await redis_counter.increment()
    await redis_counter.increment()
    assert await redis_counter.record_restart() == 1
    assert await redis_counter.record_restart() == 2
    assert await redis_counter.restart_count() == 2
    # The main counter must not have been touched by record_restart
    assert await redis_counter.value() == 2


async def test_ping_returns_true_on_healthy_redis(redis_counter):
    assert await redis_counter.ping() is True


async def test_ping_returns_false_on_redis_error(redis_counter, monkeypatch):
    async def _boom():
        raise ConnectionError("redis down")

    monkeypatch.setattr(redis_counter._client, "ping", _boom)
    assert await redis_counter.ping() is False


async def test_close_releases_client(monkeypatch, fake_client):
    closed = {"called": False}

    async def _aclose():
        closed["called"] = True

    monkeypatch.setattr(fake_client, "aclose", _aclose)

    def _from_url(url, *args, **kwargs):
        return fake_client

    import app.counter as counter_mod

    monkeypatch.setattr(counter_mod.aioredis, "from_url", _from_url)
    rc = RedisCounter("redis://fake:6379/0", "k", "rk")
    await rc.close()
    assert closed["called"] is True
