"""Per-request context propagated through logs without threading it manually."""

from contextvars import ContextVar

request_id_ctx: ContextVar[str] = ContextVar("request_id", default="-")


def get_request_id() -> str:
    """Return the current request id, or ``-`` outside of a request."""
    return request_id_ctx.get()
