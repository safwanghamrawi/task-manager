"""Database engine, session factory and startup schema management."""

import asyncio
import logging
from collections.abc import AsyncIterator

from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)

from app.core.config import Settings
from app.models import Base

logger = logging.getLogger(__name__)

_engine: AsyncEngine | None = None
_session_factory: async_sessionmaker[AsyncSession] | None = None


def create_engine(settings: Settings) -> AsyncEngine:
    """Build the async engine.

    SQLite (used by the test-suite) does not support connection pool sizing,
    so those options are only passed to real server-backed drivers.
    """
    kwargs: dict[str, object] = {
        "echo": settings.db_echo,
        "future": True,
        # Verify a pooled connection before handing it out. This is what makes
        # the API survive a Postgres restart or an idle-connection reaper
        # without returning a burst of 500s.
        "pool_pre_ping": True,
    }
    if not settings.database_url.startswith("sqlite"):
        kwargs |= {
            "pool_size": settings.db_pool_size,
            "max_overflow": settings.db_max_overflow,
            "pool_timeout": settings.db_pool_timeout,
            "pool_recycle": settings.db_pool_recycle,
        }
    return create_async_engine(settings.database_url, **kwargs)


def init_engine(settings: Settings) -> AsyncEngine:
    """Create and memoise the process-wide engine."""
    global _engine, _session_factory
    _engine = create_engine(settings)
    _session_factory = async_sessionmaker(
        bind=_engine,
        expire_on_commit=False,
        autoflush=False,
    )
    return _engine


async def dispose_engine() -> None:
    """Close every pooled connection. Called on graceful shutdown."""
    global _engine, _session_factory
    if _engine is not None:
        await _engine.dispose()
        logger.info("database_engine_disposed")
    _engine = None
    _session_factory = None


def get_engine() -> AsyncEngine:
    if _engine is None:  # pragma: no cover - guarded by application lifespan
        raise RuntimeError("Database engine is not initialised")
    return _engine


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency yielding a session with commit/rollback handling."""
    if _session_factory is None:  # pragma: no cover - guarded by lifespan
        raise RuntimeError("Database session factory is not initialised")
    async with _session_factory() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise


async def wait_for_database(engine: AsyncEngine, attempts: int, backoff: float) -> None:
    """Block until the database answers, with linear backoff.

    Compose `depends_on: service_healthy` already orders startup, but the API
    must also survive the database being restarted underneath it, and on EC2
    reboot both containers come up at once.
    """
    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            async with engine.connect() as conn:
                await conn.execute(text("SELECT 1"))
            logger.info("database_connection_established", extra={"attempt": attempt})
            return
        except SQLAlchemyError as exc:  # pragma: no cover - timing dependent
            last_error = exc
            logger.warning(
                "database_connection_failed",
                extra={"attempt": attempt, "max_attempts": attempts, "error": str(exc)},
            )
            await asyncio.sleep(backoff)
    raise RuntimeError(f"Database unreachable after {attempts} attempts") from last_error


async def create_schema(engine: AsyncEngine) -> None:
    """Create missing tables.

    `create_all` is idempotent and safe to run from several replicas at once
    because it checks for existence first; it does not, however, alter existing
    tables. See docs/ADRs in the README for the Alembic migration path.
    """
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("database_schema_ready", extra={"tables": list(Base.metadata.tables)})
