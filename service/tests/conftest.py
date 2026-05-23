import pytest
from httpx import ASGITransport, AsyncClient

from app.config import Settings
from app.main import create_app


@pytest.fixture
def settings() -> Settings:
    return Settings(backend="memory", app_version="test-1.2.3", log_level="WARNING")
    # tests pin their own version string; production version is in app/__init__.py


@pytest.fixture
async def client(settings: Settings):
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        transport = ASGITransport(app=app)
        async with AsyncClient(transport=transport, base_url="http://test") as ac:
            yield ac
