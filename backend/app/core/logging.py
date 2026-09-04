"""Structured JSON logging.

One JSON object per line on stdout, which is what the container runtime and
any log shipper (CloudWatch agent, Fluent Bit, Loki) expects. The request id is
pulled from a context variable so every log line emitted while handling a
request can be correlated, including logs from libraries that know nothing
about our middleware.
"""

import json
import logging
import sys
from datetime import UTC, datetime
from typing import Any

from app.core.context import get_request_id

# Attributes present on every LogRecord; anything else was added by the caller
# via `extra=` and is therefore worth emitting.
_RESERVED = frozenset(logging.LogRecord("", 0, "", 0, "", None, None).__dict__) | {
    "asctime",
    "message",
    "taskName",
}


class JsonFormatter(logging.Formatter):
    """Render log records as single-line JSON documents."""

    def __init__(self, service: str, environment: str) -> None:
        super().__init__()
        self.service = service
        self.environment = environment

    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, tz=UTC).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "service": self.service,
            "environment": self.environment,
            "request_id": get_request_id(),
        }

        for key, value in record.__dict__.items():
            if key not in _RESERVED and not key.startswith("_"):
                payload[key] = value

        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        if record.stack_info:
            payload["stack"] = self.formatStack(record.stack_info)

        return json.dumps(payload, default=str, separators=(",", ":"))


def configure_logging(level: str, service: str, environment: str) -> None:
    """Install the JSON formatter on the root logger and tame uvicorn's."""
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service=service, environment=environment))

    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)

    # uvicorn ships its own handlers; drop them so nothing bypasses the
    # formatter. Its access log is disabled outright because our middleware
    # emits a richer, structured equivalent.
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        logger = logging.getLogger(name)
        logger.handlers = []
        logger.propagate = True
    logging.getLogger("uvicorn.access").disabled = True
