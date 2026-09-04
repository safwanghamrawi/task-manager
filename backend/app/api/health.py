"""Liveness, readiness and metrics endpoints.

The distinction matters to any orchestrator:

* liveness  - is the process healthy enough to keep? A failure means restart.
* readiness - can it serve traffic right now? A failure means stop routing to
  it, but do not kill it: the database may simply be failing over.
"""

import logging
import time

from fastapi import APIRouter, Response, status
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import text
from sqlalchemy.exc import SQLAlchemyError

from app import __version__
from app.api.deps import SettingsDep
from app.core.metrics import DB_UP, REGISTRY
from app.db import get_engine
from app.schemas import HealthComponent, HealthResponse

logger = logging.getLogger(__name__)

router = APIRouter(tags=["operations"])


async def _check_database() -> HealthComponent:
    """Probe the database with a trivial query and a hard timeout."""
    start = time.perf_counter()
    try:
        engine = get_engine()
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except (SQLAlchemyError, RuntimeError, OSError) as exc:
        DB_UP.set(0)
        logger.warning("health_check_database_failed", extra={"error": str(exc)})
        return HealthComponent(status="down", detail=type(exc).__name__)

    DB_UP.set(1)
    return HealthComponent(status="up", latency_ms=round((time.perf_counter() - start) * 1000, 2))


def _base_health(settings: SettingsDep, status_text: str) -> HealthResponse:
    return HealthResponse(
        status=status_text,
        service=settings.app_name,
        version=__version__,
        environment=settings.environment,
    )


@router.get(
    "/health",
    response_model=HealthResponse,
    summary="Health check",
    description=(
        "Aggregated health, including a database round-trip. Returns 503 when a "
        "dependency is unavailable so a load balancer can drain this instance."
    ),
)
async def health(settings: SettingsDep, response: Response) -> HealthResponse:
    database = await _check_database()
    healthy = database.status == "up"
    body = _base_health(settings, "ok" if healthy else "degraded")
    body.checks = {"database": database}
    if not healthy:
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    return body


@router.get(
    "/health/live",
    response_model=HealthResponse,
    summary="Liveness probe",
    description="Succeeds while the process is able to serve. No dependencies checked.",
)
async def liveness(settings: SettingsDep) -> HealthResponse:
    return _base_health(settings, "ok")


@router.get(
    "/health/ready",
    response_model=HealthResponse,
    summary="Readiness probe",
    description="Succeeds only when every dependency needed to serve traffic is reachable.",
)
async def readiness(settings: SettingsDep, response: Response) -> HealthResponse:
    return await health(settings, response)


# Mirrored under /api so the browser can reach it through the single Traefik
# rule that routes /api to this service, without exposing /metrics publicly.
@router.get("/api/health", response_model=HealthResponse, summary="Health check (public path)")
async def public_health(settings: SettingsDep, response: Response) -> HealthResponse:
    return await health(settings, response)


@router.get(
    "/metrics",
    summary="Prometheus metrics",
    description="OpenMetrics/Prometheus text exposition of application metrics.",
    response_class=Response,
    responses={200: {"content": {CONTENT_TYPE_LATEST: {}}}},
)
async def metrics() -> Response:
    return Response(content=generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)
