"""Task use-cases.

Kept apart from the HTTP layer so the rules are testable without a client and
so the routes stay thin: they translate HTTP to a call and back.
"""

import logging

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import TaskLimitExceededError, TaskNotFoundError
from app.core.metrics import TASKS_CREATED, TASKS_DELETED
from app.models import Task
from app.schemas import TaskCreate

logger = logging.getLogger(__name__)


class TaskService:
    """Read/write operations on tasks."""

    def __init__(self, session: AsyncSession, max_tasks: int) -> None:
        self._session = session
        self._max_tasks = max_tasks

    async def list_tasks(self, limit: int, offset: int) -> tuple[list[Task], int]:
        """Return a page of tasks (newest first) and the total row count."""
        statement = (
            select(Task)
            .order_by(Task.created_at.desc(), Task.id.desc())
            .limit(limit)
            .offset(offset)
        )
        result = await self._session.execute(statement)
        tasks = list(result.scalars().all())
        total = await self._session.scalar(select(func.count()).select_from(Task)) or 0
        return tasks, total

    async def create_task(self, payload: TaskCreate) -> Task:
        """Persist a new task."""
        current = await self._session.scalar(select(func.count()).select_from(Task)) or 0
        if current >= self._max_tasks:
            raise TaskLimitExceededError(f"The task limit of {self._max_tasks} has been reached")

        task = Task(
            title=payload.title,
            description=payload.description,
            completed=payload.completed,
        )
        self._session.add(task)
        await self._session.commit()
        await self._session.refresh(task)

        TASKS_CREATED.inc()
        logger.info("task_created", extra={"task_id": task.id})
        return task

    async def delete_task(self, task_id: int) -> None:
        """Delete a task, or raise if it does not exist.

        A single conditional DELETE avoids the read-then-write race where two
        concurrent deletes both find the row and one fails confusingly.
        """
        result = await self._session.execute(delete(Task).where(Task.id == task_id))
        await self._session.commit()

        if result.rowcount == 0:
            raise TaskNotFoundError(task_id)

        TASKS_DELETED.inc()
        logger.info("task_deleted", extra={"task_id": task_id})
