###############################################################################
# Stage 1: builder — install deps into a venv we'll copy into the runtime image.
###############################################################################
FROM python:3.13-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml ./
COPY app ./app

RUN pip install --upgrade pip && pip install . \
    # Strip build-only deps from the venv — these aren't needed to run the
    # service and they're what Trivy was flagging for HIGH CVEs (jaraco.context,
    # wheel, setuptools transitives). The runtime image is leaner too.
    && pip uninstall -y pip setuptools wheel

###############################################################################
# Stage 2: runtime — distroless python, non-root, no shell or package manager.
###############################################################################
FROM gcr.io/distroless/python3-debian13:nonroot AS runtime

ARG APP_VERSION=0.0.0-dev
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/opt/venv/lib/python3.13/site-packages \
    COUNTER_APP_VERSION=${APP_VERSION}

COPY --from=builder /opt/venv /opt/venv
COPY --chown=nonroot:nonroot app /app/app

WORKDIR /app
USER nonroot

EXPOSE 8080

# Kubernetes liveness/readiness probes own health-checking in production; this
# HEALTHCHECK is a defence-in-depth for plain `docker run`. Distroless has
# python available so we can hit /healthz without curl.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).status==200 else 1)"]

ENTRYPOINT ["python", "-m", "uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080", "--no-access-log"]
