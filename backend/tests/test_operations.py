"""Tests for the health, metrics and error-handling behaviour."""

from httpx import AsyncClient
from pytest import MonkeyPatch

from app.services import TaskService


async def test_health_reports_database_up(client: AsyncClient) -> None:
    response = await client.get("/health")

    assert response.status_code == 200
    body = response.json()
    assert body["status"] == "ok"
    assert body["checks"]["database"]["status"] == "up"
    assert body["version"]


async def test_liveness_does_not_touch_the_database(client: AsyncClient) -> None:
    body = (await client.get("/health/live")).json()

    assert body["status"] == "ok"
    assert body["checks"] == {}


async def test_readiness_is_exposed(client: AsyncClient) -> None:
    assert (await client.get("/health/ready")).status_code == 200


async def test_health_is_mirrored_under_api(client: AsyncClient) -> None:
    assert (await client.get("/api/health")).json()["status"] == "ok"


async def test_metrics_exposes_request_series(client: AsyncClient) -> None:
    await client.get("/api/tasks")

    response = await client.get("/metrics")
    body = response.text

    assert response.status_code == 200
    assert "text/plain" in response.headers["content-type"]
    assert "http_requests_total" in body
    assert "http_request_duration_seconds_bucket" in body
    assert 'path="/api/tasks"' in body


async def test_metrics_counts_created_tasks(client: AsyncClient) -> None:
    await client.post("/api/tasks", json={"title": "counted"})

    assert "tasks_created_total" in (await client.get("/metrics")).text


async def test_unmatched_paths_do_not_create_a_series_per_path(client: AsyncClient) -> None:
    await client.get("/definitely-not-a-route")

    assert 'path="__unmatched__"' in (await client.get("/metrics")).text


async def test_openapi_document_is_served(client: AsyncClient) -> None:
    schema = (await client.get("/openapi.json")).json()

    assert schema["info"]["title"] == "Task Manager API"
    assert "/api/tasks" in schema["paths"]


async def test_database_outage_returns_503_not_500(
    client: AsyncClient, monkeypatch: MonkeyPatch
) -> None:
    """A dependency outage must not be reported as a bug in this service.

    asyncpg raises a bare OSError (DNS failure, refused connection) before
    SQLAlchemy can wrap it, which used to surface as a 500 "internal error".
    """

    async def explode(*_: object, **__: object) -> None:
        raise OSError("[Errno -2] Name or service not known")

    monkeypatch.setattr(TaskService, "list_tasks", explode)

    response = await client.get("/api/tasks")

    assert response.status_code == 503
    body = response.json()["error"]
    assert body["code"] == "database_unavailable"
    # The driver message can contain the DSN; it must never reach the client.
    assert "Errno" not in body["message"]


async def test_error_responses_carry_the_request_id(
    client: AsyncClient, monkeypatch: MonkeyPatch
) -> None:
    """Even a 500 has to be traceable back to its log line."""

    async def explode(*_: object, **__: object) -> None:
        raise ValueError("something entirely unexpected")

    monkeypatch.setattr(TaskService, "list_tasks", explode)

    response = await client.get("/api/tasks", headers={"X-Request-ID": "trace-500"})

    assert response.status_code == 500
    assert response.json()["error"]["request_id"] == "trace-500"
