"""HTTP middleware: request ids, structured access logs, Prometheus metrics."""

import logging
import time
import uuid
from collections.abc import Awaitable, Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response
from starlette.types import ASGIApp

from app.core.context import request_id_ctx
from app.core.metrics import REQUEST_COUNT, REQUEST_DURATION, REQUESTS_IN_PROGRESS

logger = logging.getLogger("app.access")

RequestHandler = Callable[[Request], Awaitable[Response]]

# Paths that would otherwise flood the access log and the metrics series.
_QUIET_PATHS = frozenset({"/health", "/health/live", "/health/ready", "/metrics"})


def _client_ip(request: Request) -> str:
    """Best-effort client address, honouring the proxy header set by Traefik."""
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[0].strip()
    return request.client.host if request.client else "-"


def _route_template(request: Request) -> str:
    """Return the matched route pattern, falling back to a low-cardinality label.

    Unmatched paths (404s) all collapse to a single ``__unmatched__`` series so
    a crawler hitting random URLs cannot inflate metric cardinality.
    """
    route = request.scope.get("route")
    path = getattr(route, "path", None)
    if path:
        return str(path)
    return request.url.path if request.url.path in _QUIET_PATHS else "__unmatched__"


class RequestContextMiddleware(BaseHTTPMiddleware):
    """Attach a request id to the context and echo it back to the client."""

    async def dispatch(self, request: Request, call_next: RequestHandler) -> Response:
        incoming = request.headers.get("x-request-id", "").strip()
        # Bound the accepted length: the id ends up in every log line.
        request_id = incoming[:64] if incoming else uuid.uuid4().hex
        # Both a context variable (for logging, which cannot see the request)
        # and request.state (for error handlers that run after the context is
        # torn down).
        request.state.request_id = request_id
        token = request_id_ctx.set(request_id)
        try:
            response = await call_next(request)
        finally:
            request_id_ctx.reset(token)
        response.headers["X-Request-ID"] = request_id
        return response


class ObservabilityMiddleware(BaseHTTPMiddleware):
    """Record latency/count metrics and emit one structured access log line."""

    def __init__(self, app: ASGIApp) -> None:
        super().__init__(app)

    async def dispatch(self, request: Request, call_next: RequestHandler) -> Response:
        method = request.method
        start = time.perf_counter()
        status = 500

        # The route is only resolved downstream, so metrics are labelled after
        # the handler runs; in-progress uses the raw path prefix instead.
        in_progress_path = request.url.path if request.url.path in _QUIET_PATHS else "*"
        REQUESTS_IN_PROGRESS.labels(method=method, path=in_progress_path).inc()
        try:
            response = await call_next(request)
            status = response.status_code
            return response
        except Exception:
            # The exception handlers below turn this into a 500 response; we
            # still want the metric and the log line to reflect reality.
            logger.exception("unhandled_exception", extra={"path": request.url.path})
            raise
        finally:
            duration = time.perf_counter() - start
            REQUESTS_IN_PROGRESS.labels(method=method, path=in_progress_path).dec()
            path = _route_template(request)
            REQUEST_DURATION.labels(method=method, path=path).observe(duration)
            REQUEST_COUNT.labels(method=method, path=path, status=str(status)).inc()

            if request.url.path not in _QUIET_PATHS:
                logger.info(
                    "http_request",
                    extra={
                        "http_method": method,
                        "http_path": request.url.path,
                        "http_route": path,
                        "http_status": status,
                        "duration_ms": round(duration * 1000, 2),
                        "client_ip": _client_ip(request),
                        "user_agent": request.headers.get("user-agent", "-"),
                    },
                )
