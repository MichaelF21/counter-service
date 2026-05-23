import pytest


async def test_get_initial_count_is_zero(client):
    r = await client.get("/")
    assert r.status_code == 200
    assert "count: 0" in r.text
    assert "v test-1.2.3" in r.text.replace("v", "v ")  # tolerate formatting


async def test_post_increments(client):
    for expected in (1, 2, 3):
        r = await client.post("/")
        assert r.status_code == 201
        assert f"count: {expected}" in r.text


async def test_get_after_posts_returns_total(client):
    for _ in range(5):
        await client.post("/")
    r = await client.get("/")
    assert "count: 5" in r.text


async def test_healthz(client):
    r = await client.get("/healthz")
    assert r.status_code == 200 and r.text == "ok"


async def test_readyz(client):
    r = await client.get("/readyz")
    assert r.status_code == 200 and r.text == "ready"


async def test_version(client):
    r = await client.get("/version")
    assert r.status_code == 200 and r.text == "test-1.2.3"


async def test_metrics_exposes_prometheus_format(client):
    await client.post("/")
    r = await client.get("/metrics")
    assert r.status_code == 200
    body = r.text
    assert "counter_http_requests_total" in body
    assert "counter_value" in body
    assert "counter_restart_count" in body


@pytest.mark.parametrize("method", ["PUT", "DELETE", "PATCH"])
async def test_other_methods_rejected(client, method):
    r = await client.request(method, "/")
    assert r.status_code == 405
