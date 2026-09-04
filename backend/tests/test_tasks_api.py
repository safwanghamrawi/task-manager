"""End-to-end tests for the task endpoints."""

import pytest
from httpx import AsyncClient


async def _create(client: AsyncClient, title: str = "Write the runbook") -> dict:
    response = await client.post("/api/tasks", json={"title": title})
    assert response.status_code == 201, response.text
    return response.json()


async def test_list_is_empty_initially(client: AsyncClient) -> None:
    response = await client.get("/api/tasks")

    assert response.status_code == 200
    assert response.json() == {"items": [], "total": 0}


async def test_create_returns_the_persisted_task(client: AsyncClient) -> None:
    response = await client.post(
        "/api/tasks", json={"title": "Deploy", "description": "to staging"}
    )

    assert response.status_code == 201
    body = response.json()
    assert body["id"] > 0
    assert body["title"] == "Deploy"
    assert body["description"] == "to staging"
    assert body["completed"] is False
    assert body["created_at"] and body["updated_at"]


async def test_created_task_is_listed_newest_first(client: AsyncClient) -> None:
    first = await _create(client, "first")
    second = await _create(client, "second")

    body = (await client.get("/api/tasks")).json()

    assert body["total"] == 2
    assert [item["id"] for item in body["items"]] == [second["id"], first["id"]]


async def test_pagination_limits_the_page(client: AsyncClient) -> None:
    for index in range(3):
        await _create(client, f"task-{index}")

    body = (await client.get("/api/tasks", params={"limit": 2})).json()

    assert len(body["items"]) == 2
    assert body["total"] == 3


async def test_delete_removes_the_task(client: AsyncClient) -> None:
    task = await _create(client)

    assert (await client.delete(f"/api/tasks/{task['id']}")).status_code == 204
    assert (await client.get("/api/tasks")).json()["total"] == 0


async def test_delete_unknown_task_returns_structured_404(client: AsyncClient) -> None:
    response = await client.delete("/api/tasks/424242")

    assert response.status_code == 404
    error = response.json()["error"]
    assert error["code"] == "task_not_found"
    assert error["request_id"]


@pytest.mark.parametrize(
    "payload",
    [
        {},  # title missing
        {"title": ""},  # title empty
        {"title": "   "},  # title blank
        {"title": "x" * 201},  # title too long
        {"title": "ok", "unexpected": 1},  # unknown field rejected
    ],
)
async def test_invalid_payloads_are_rejected(client: AsyncClient, payload: dict) -> None:
    response = await client.post("/api/tasks", json=payload)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "validation_error"


async def test_task_limit_is_enforced(client: AsyncClient) -> None:
    # The test settings cap the table at 5 rows.
    for index in range(5):
        await _create(client, f"task-{index}")

    response = await client.post("/api/tasks", json={"title": "one too many"})

    assert response.status_code == 409
    assert response.json()["error"]["code"] == "task_limit_exceeded"


async def test_request_id_is_echoed_back(client: AsyncClient) -> None:
    response = await client.get("/api/tasks", headers={"X-Request-ID": "trace-abc"})

    assert response.headers["X-Request-ID"] == "trace-abc"


async def test_delete_rejects_non_positive_id(client: AsyncClient) -> None:
    assert (await client.delete("/api/tasks/0")).status_code == 422
