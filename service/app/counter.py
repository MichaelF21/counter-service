from typing import Protocol

import redis.asyncio as aioredis


class CounterRepository(Protocol):
    async def increment(self) -> int: ...
    async def value(self) -> int: ...
    async def record_restart(self) -> int: ...
    async def restart_count(self) -> int: ...
    async def ping(self) -> bool: ...
    async def close(self) -> None: ...


class InMemoryCounter:
    def __init__(self) -> None:
        self._count = 0
        self._restarts = 0

    async def increment(self) -> int:
        self._count += 1
        return self._count

    async def value(self) -> int:
        return self._count

    async def record_restart(self) -> int:
        self._restarts += 1
        return self._restarts

    async def restart_count(self) -> int:
        return self._restarts

    async def ping(self) -> bool:
        return True

    async def close(self) -> None:
        return None


class RedisCounter:
    def __init__(self, url: str, key: str, restart_key: str) -> None:
        self._client: aioredis.Redis = aioredis.from_url(  # type: ignore[no-untyped-call]
            url, decode_responses=True
        )
        self._key = key
        self._restart_key = restart_key

    async def increment(self) -> int:
        return int(await self._client.incr(self._key))

    async def value(self) -> int:
        raw = await self._client.get(self._key)
        return int(raw) if raw is not None else 0

    async def record_restart(self) -> int:
        return int(await self._client.incr(self._restart_key))

    async def restart_count(self) -> int:
        raw = await self._client.get(self._restart_key)
        return int(raw) if raw is not None else 0

    async def ping(self) -> bool:
        try:
            return bool(await self._client.ping())
        except Exception:
            return False

    async def close(self) -> None:
        await self._client.aclose()


def build_counter(backend: str, redis_url: str, key: str, restart_key: str) -> CounterRepository:
    if backend.lower() == "redis":
        return RedisCounter(redis_url, key, restart_key)
    if backend.lower() == "memory":
        return InMemoryCounter()
    raise ValueError(f"Unsupported COUNTER_BACKEND: {backend!r}")
