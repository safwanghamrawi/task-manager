"""Pydantic request/response models.

These are the API contract and are intentionally decoupled from the ORM
models: renaming a column must not silently change the wire format.
"""

from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator


class TaskCreate(BaseModel):
    """Payload accepted by ``POST /api/tasks``."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)

    title: Annotated[str, Field(min_length=1, max_length=200, examples=["Ship the release"])]
    description: Annotated[
        str | None,
        Field(default=None, max_length=2000, examples=["Cut the tag and update the changelog"]),
    ] = None
    completed: bool = False

    @field_validator("title")
    @classmethod
    def _title_not_blank(cls, value: str) -> str:
        if not value.strip():
            raise ValueError("title must not be blank")
        return value

    @field_validator("description")
    @classmethod
    def _empty_description_is_null(cls, value: str | None) -> str | None:
        return value or None


class TaskRead(BaseModel):
    """Representation of a task returned by the API."""

    model_config = ConfigDict(from_attributes=True)

    id: int
    title: str
    description: str | None
    completed: bool
    created_at: datetime
    updated_at: datetime


class TaskList(BaseModel):
    """Envelope for the collection endpoint, so pagination can be added later."""

    items: list[TaskRead]
    total: int


class HealthComponent(BaseModel):
    status: str
    detail: str | None = None
    latency_ms: float | None = None


class HealthResponse(BaseModel):
    """Response of the health endpoints."""

    status: str = Field(examples=["ok"])
    service: str
    version: str
    environment: str
    checks: dict[str, HealthComponent] = Field(default_factory=dict)


class ErrorDetail(BaseModel):
    code: str
    message: str
    request_id: str
    details: list[dict[str, object]] | None = None


class ErrorResponse(BaseModel):
    """Every non-2xx response from this API has this shape."""

    error: ErrorDetail
