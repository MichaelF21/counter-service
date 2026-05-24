import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response
from fastapi.responses import PlainTextResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest

from app import __version__
from app.config import Settings, get_settings
from app.counter import CounterRepository, build_counter
from app.ingest import IngestPayload, IngestStore
from app.logging_setup import configure_logging
from app.metrics import (
    counter_value,
    http_request_duration_seconds,
    http_requests_total,
    registry,
    restart_count,
)

log = logging.getLogger("counter")


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.log_level)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        repo: CounterRepository = build_counter(
            settings.backend, settings.redis_url, settings.redis_key, settings.restart_key
        )
        app.state.repo = repo
        app.state.settings = settings
        app.state.ingest = None
        if settings.ingest_enabled:
            ingest_store = IngestStore(settings)
            await ingest_store.connect()
            app.state.ingest = ingest_store
            log.info("ingest.connected", extra={"db": settings.pg_database})
        restarts = await repo.record_restart()
        restart_count.set(restarts)
        counter_value.set(await repo.value())
        log.info(
            "service.started",
            extra={
                "version": settings.app_version,
                "backend": settings.backend,
                "restarts": restarts,
                "ingest_enabled": settings.ingest_enabled,
            },
        )
        try:
            yield
        finally:
            await repo.close()
            if app.state.ingest is not None:
                await app.state.ingest.close()
            log.info("service.stopped")

    app = FastAPI(
        title="counter-service",
        version=settings.app_version,
        lifespan=lifespan,
        docs_url="/docs",
        redoc_url=None,
    )

    @app.middleware("http")
    async def observe(request: Request, call_next):  # type: ignore[no-untyped-def]
        start = time.perf_counter()
        response = await call_next(request)
        elapsed = time.perf_counter() - start
        route = request.scope.get("route")
        endpoint = getattr(route, "path", None) or request.url.path
        http_requests_total.labels(request.method, endpoint, str(response.status_code)).inc()
        http_request_duration_seconds.labels(request.method, endpoint).observe(elapsed)
        return response

    @app.get("/", response_class=PlainTextResponse)
    async def get_count(request: Request) -> str:
        repo: CounterRepository = request.app.state.repo
        value = await repo.value()
        counter_value.set(value)
        return f"counter-service v{settings.app_version}\ncount: {value}\n"

    @app.post("/", status_code=201, response_class=PlainTextResponse)
    async def post_count(request: Request) -> str:
        repo: CounterRepository = request.app.state.repo
        new_value = await repo.increment()
        counter_value.set(new_value)
        return f"count: {new_value}\n"

    @app.get("/healthz", response_class=PlainTextResponse)
    async def healthz() -> str:
        return "ok"

    @app.get("/readyz")
    async def readyz(request: Request) -> Response:
        repo: CounterRepository = request.app.state.repo
        ok = await repo.ping()
        return Response(
            content="ready" if ok else "not ready",
            status_code=200 if ok else 503,
            media_type="text/plain",
        )

    @app.get("/version", response_class=PlainTextResponse)
    async def version() -> str:
        return settings.app_version

    @app.get("/metrics")
    async def metrics() -> Response:
        return Response(generate_latest(registry), media_type=CONTENT_TYPE_LATEST)

    @app.post("/ingest", status_code=201)
    async def ingest(payload: IngestPayload, request: Request) -> Response:
        """Write a counter sample to the Crossplane-provisioned Postgres table.

        Returns 503 if the ingest sink isn't wired (env var
        COUNTER_INGEST_ENABLED=false or the Postgres backend isn't reachable).
        """
        store: IngestStore | None = request.app.state.ingest
        if store is None:
            return Response(content="ingest disabled\n", status_code=503, media_type="text/plain")
        await store.insert(payload)
        return Response(content="ingested\n", status_code=201, media_type="text/plain")

    log.info("app.created", extra={"version": __version__, "app_version": settings.app_version})
    return app


app = create_app()
