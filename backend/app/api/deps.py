"""Shared FastAPI dependencies."""

from typing import Annotated

from fastapi import Depends, Request
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.db import get_session
from app.services import TaskService


def get_app_settings(request: Request) -> Settings:
    """Return the settings the application was built with.

    Reading them off ``app.state`` rather than the module-level cache means an
    application created by the factory with explicit settings — as the tests
    do — behaves consistently all the way down into the dependency graph.
    """
    settings: Settings = request.app.state.settings
    return settings


SettingsDep = Annotated[Settings, Depends(get_app_settings)]
SessionDep = Annotated[AsyncSession, Depends(get_session)]


def get_task_service(session: SessionDep, settings: SettingsDep) -> TaskService:
    """Build the service for one request, bound to that request's session."""
    return TaskService(session=session, max_tasks=settings.max_tasks)


TaskServiceDep = Annotated[TaskService, Depends(get_task_service)]
