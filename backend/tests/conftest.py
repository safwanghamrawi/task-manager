"""Test fixtures.

The suite runs against SQLite/aiosqlite by default so `pytest` needs no running
services; point ``TEST_DATABASE_URL`` at Postgres to exercise the real driver
(CI does exactly that in the `test` job).

The application lifespan is not run here — ``httpx.ASGITransport`` does not
trigger it — so the engine and schema are set up explicitly, which also lets
each test start from an empty table.
"""

import os
from collections.abc import AsyncIterator

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app import db as db_module
from app.core.config import Settings
from app.main import create_app
from app.models import Base

TEST_DATABASE_URL = os.getenv("TEST_DATABASE_URL", "sqlite+aiosqlite:///:memory:")


@pytest.fixture
def settings() -> Settings:
    return Settings(
        database_url=TEST_DATABASE_URL,
        environment="local",
        log_level="WARNING",
        max_tasks=5,
    )


@pytest.fixture
async def engine(settings: Settings) -> AsyncIterator[None]:
    """Initialise the process-wide engine on a freshly created schema."""
    db_engine = db_module.init_engine(settings)
    async with db_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    try:
        yield None
    finally:
        await db_module.dispose_engine()


@pytest.fixture
async def client(settings: Settings, engine: None) -> AsyncIterator[AsyncClient]:
    """An HTTP client bound directly to the ASGI app."""
    app = create_app(settings)
    # raise_app_exceptions=False mirrors what uvicorn does in production: an
    # unhandled exception is logged and the client still receives the 500
    # response the handler produced, rather than the exception being re-raised
    # into the caller.
    transport = ASGITransport(app=app, raise_app_exceptions=False)
    async with AsyncClient(transport=transport, base_url="http://test") as http_client:
        yield http_client


@pytest.fixture
async def session(engine: None) -> AsyncIterator[AsyncSession]:
    """A database session for tests that exercise the service layer directly."""
    factory = async_sessionmaker(bind=db_module.get_engine(), expire_on_commit=False)
    async with factory() as db_session:
        yield db_session
