"""Task endpoints."""

from typing import Annotated

from fastapi import APIRouter, Path, Query, Response, status

from app.api.deps import TaskServiceDep
from app.schemas import ErrorResponse, TaskCreate, TaskList, TaskRead

router = APIRouter(prefix="/api/tasks", tags=["tasks"])

_ERRORS: dict[int | str, dict[str, object]] = {
    422: {"model": ErrorResponse, "description": "Validation error"},
    503: {"model": ErrorResponse, "description": "Database unavailable"},
}


@router.get(
    "",
    response_model=TaskList,
    summary="List tasks",
    description="Returns tasks ordered by creation date, newest first.",
    responses=_ERRORS,
)
async def list_tasks(
    service: TaskServiceDep,
    limit: Annotated[int, Query(ge=1, le=200, description="Maximum tasks to return")] = 100,
    offset: Annotated[int, Query(ge=0, description="Number of tasks to skip")] = 0,
) -> TaskList:
    tasks, total = await service.list_tasks(limit=limit, offset=offset)
    return TaskList(items=[TaskRead.model_validate(task) for task in tasks], total=total)


@router.post(
    "",
    response_model=TaskRead,
    status_code=status.HTTP_201_CREATED,
    summary="Create a task",
    responses={**_ERRORS, 409: {"model": ErrorResponse, "description": "Task limit reached"}},
)
async def create_task(payload: TaskCreate, service: TaskServiceDep) -> TaskRead:
    task = await service.create_task(payload)
    return TaskRead.model_validate(task)


@router.delete(
    "/{task_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="Delete a task",
    responses={**_ERRORS, 404: {"model": ErrorResponse, "description": "Task not found"}},
)
async def delete_task(
    service: TaskServiceDep,
    task_id: Annotated[int, Path(ge=1, description="Identifier of the task to delete")],
) -> Response:
    await service.delete_task(task_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
