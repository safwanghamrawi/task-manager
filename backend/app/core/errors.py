"""Domain exceptions and the handlers that map them onto the wire format.

Every error leaving this service is a single JSON shape:

    {"error": {"code", "message", "request_id", "details"}}

so the frontend has exactly one branch to write, and `request_id` ties the
user-visible failure back to the structured log line.
"""

import logging

from fastapi import FastAPI, Request, status
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from sqlalchemy.exc import SQLAlchemyError
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.core.context import get_request_id

logger = logging.getLogger(__name__)


class AppError(Exception):
    """Base class for expected, domain-level failures."""

    status_code: int = status.HTTP_500_INTERNAL_SERVER_ERROR
    code: str = "internal_error"

    def __init__(self, message: str) -> None:
        super().__init__(message)
        self.message = message


class TaskNotFoundError(AppError):
    status_code = status.HTTP_404_NOT_FOUND
    code = "task_not_found"

    def __init__(self, task_id: int) -> None:
        super().__init__(f"Task {task_id} was not found")
        self.task_id = task_id


class TaskLimitExceededError(AppError):
    """Guard rail: refuse to grow the table without bound."""

    status_code = status.HTTP_409_CONFLICT
    code = "task_limit_exceeded"


class DatabaseUnavailableError(AppError):
    status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    code = "database_unavailable"


def _request_id(request: Request) -> str:
    """Resolve the request id for an error response.

    Starlette installs the catch-all ``Exception`` handler in the outermost
    middleware, which runs *after* RequestContextMiddleware has reset the
    context variable. The id is therefore also stashed on ``request.state``,
    and that copy is preferred here so a 500 is still traceable to its log line.
    """
    stored = getattr(request.state, "request_id", None)
    if isinstance(stored, str) and stored:
        return stored
    return get_request_id()


def _error_response(
    request: Request,
    status_code: int,
    code: str,
    message: str,
    details: list[dict[str, object]] | None = None,
) -> JSONResponse:
    payload: dict[str, object] = {
        "code": code,
        "message": message,
        "request_id": _request_id(request),
    }
    if details:
        payload["details"] = details
    return JSONResponse(status_code=status_code, content={"error": payload})


def register_exception_handlers(app: FastAPI) -> None:
    """Attach the handlers to the application."""

    @app.exception_handler(AppError)
    async def _handle_app_error(request: Request, exc: AppError) -> JSONResponse:
        logger.warning("app_error", extra={"error_code": exc.code, "detail": exc.message})
        return _error_response(request, exc.status_code, exc.code, exc.message)

    @app.exception_handler(RequestValidationError)
    async def _handle_validation_error(
        request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        details = jsonable_encoder(exc.errors(), exclude={"url", "ctx"})
        logger.info("request_validation_failed", extra={"validation_errors": details})
        return _error_response(
            request,
            status.HTTP_422_UNPROCESSABLE_ENTITY,
            "validation_error",
            "The request payload is invalid",
            details,
        )

    @app.exception_handler(StarletteHTTPException)
    async def _handle_http_error(request: Request, exc: StarletteHTTPException) -> JSONResponse:
        return _error_response(
            request,
            exc.status_code,
            f"http_{exc.status_code}",
            str(exc.detail),
        )

    async def _database_unavailable(request: Request, exc: Exception) -> JSONResponse:
        # Never leak a driver message (it can contain the DSN) to the client.
        logger.error(
            "database_error",
            extra={"error_type": type(exc).__name__, "detail": str(exc)[:200]},
        )
        return _error_response(
            request,
            status.HTTP_503_SERVICE_UNAVAILABLE,
            "database_unavailable",
            "The service is temporarily unable to reach its database",
        )

    @app.exception_handler(SQLAlchemyError)
    async def _handle_db_error(request: Request, exc: SQLAlchemyError) -> JSONResponse:
        return await _database_unavailable(request, exc)

    @app.exception_handler(OSError)
    async def _handle_socket_error(request: Request, exc: OSError) -> JSONResponse:
        """Connection refused, DNS failure, reset socket - the database is gone.

        asyncpg raises these before SQLAlchemy has anything to wrap, so without
        this handler a database outage is reported as a 500 "internal error",
        which points on-call at the wrong service.
        """
        return await _database_unavailable(request, exc)

    @app.exception_handler(Exception)
    async def _handle_unexpected(request: Request, exc: Exception) -> JSONResponse:
        logger.exception("unhandled_error", extra={"error_type": type(exc).__name__})
        return _error_response(
            request,
            status.HTTP_500_INTERNAL_SERVER_ERROR,
            "internal_error",
            "An unexpected error occurred",
        )
