"""Application factory and ASGI entrypoint."""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware

from app import __version__
from app.api import health, tasks
from app.core.config import Settings, get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import configure_logging
from app.core.metrics import APP_INFO
from app.core.middleware import ObservabilityMiddleware, RequestContextMiddleware
from app.db import create_schema, dispose_engine, init_engine, wait_for_database

logger = logging.getLogger(__name__)

DESCRIPTION = """
Task Manager API.

A small, stateless CRUD service over PostgreSQL. All state lives in the
database, so instances can be added or removed freely behind a load balancer.

* `GET /api/tasks` - list tasks
* `POST /api/tasks` - create a task
* `DELETE /api/tasks/{id}` - delete a task
* `GET /health` - aggregated health (also `/health/live`, `/health/ready`)
* `GET /metrics` - Prometheus exposition
""".strip()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    """Start-up and shut-down.

    Uvicorn runs this on SIGTERM as well, which is what makes shutdown
    graceful: in-flight requests finish, then the pool is drained before the
    process exits.
    """
    settings: Settings = app.state.settings

    engine = init_engine(settings)
    await wait_for_database(
        engine,
        attempts=settings.db_connect_max_attempts,
        backoff=settings.db_connect_backoff_seconds,
    )
    if settings.db_auto_create_schema:
        await create_schema(engine)

    logger.info(
        "application_started",
        extra={"version": __version__, "environment": settings.environment},
    )
    try:
        yield
    finally:
        logger.info("application_stopping")
        await dispose_engine()
        logger.info("application_stopped")


def create_app(settings: Settings | None = None) -> FastAPI:
    """Build the FastAPI application."""
    settings = settings or get_settings()
    configure_logging(
        level=settings.log_level,
        service=settings.app_name,
        environment=settings.environment,
    )
    APP_INFO.info({"version": __version__, "environment": settings.environment})

    app = FastAPI(
        title="Task Manager API",
        description=DESCRIPTION,
        version=__version__,
        lifespan=lifespan,
        root_path=settings.root_path,
        docs_url="/docs",
        redoc_url="/redoc",
        openapi_url="/openapi.json",
    )
    app.state.settings = settings

    # Middleware runs bottom-up: the request id must be set before anything
    # that logs, so it is added last.
    app.add_middleware(GZipMiddleware, minimum_size=1024)
    if settings.cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=settings.cors_origins,
            allow_credentials=False,
            allow_methods=["GET", "POST", "DELETE", "OPTIONS"],
            allow_headers=["Content-Type", "X-Request-ID"],
            expose_headers=["X-Request-ID"],
            max_age=600,
        )
    app.add_middleware(ObservabilityMiddleware)
    app.add_middleware(RequestContextMiddleware)

    register_exception_handlers(app)

    app.include_router(health.router)
    app.include_router(tasks.router)

    return app


app = create_app()
