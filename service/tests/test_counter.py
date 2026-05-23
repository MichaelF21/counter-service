import pytest

from app.counter import InMemoryCounter, build_counter


async def test_inmemory_increment_and_value():
    c = InMemoryCounter()
    assert await c.value() == 0
    for expected in (1, 2, 3):
        assert await c.increment() == expected
    assert await c.value() == 3


async def test_inmemory_restart_tracking():
    c = InMemoryCounter()
    assert await c.restart_count() == 0
    assert await c.record_restart() == 1
    assert await c.record_restart() == 2
    assert await c.restart_count() == 2


async def test_inmemory_ping_always_ok():
    c = InMemoryCounter()
    assert await c.ping() is True


def test_build_counter_rejects_unknown_backend():
    with pytest.raises(ValueError, match="Unsupported"):
        build_counter("postgres", "", "", "")


def test_build_counter_memory():
    c = build_counter("memory", "", "k", "rk")
    assert isinstance(c, InMemoryCounter)


def test_build_counter_redis_constructs_without_connecting():
    from app.counter import RedisCounter

    c = build_counter("redis", "redis://localhost:6379/0", "k", "rk")
    assert isinstance(c, RedisCounter)
