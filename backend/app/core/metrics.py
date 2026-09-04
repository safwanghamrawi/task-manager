"""Prometheus instrumentation.

Cardinality is the thing that kills a metrics backend, so the request labels
are deliberately limited to (method, path template, status). Using the route
template rather than the raw path keeps `/api/tasks/1` and `/api/tasks/2` in
the same series.
"""

from prometheus_client import CollectorRegistry, Counter, Gauge, Histogram, Info

# A dedicated registry keeps the exposition free of collectors registered by
# imported libraries and makes tests deterministic.
REGISTRY = CollectorRegistry(auto_describe=True)

APP_INFO = Info(
    "task_manager_app",
    "Static information about the running application",
    registry=REGISTRY,
)

REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests processed",
    labelnames=("method", "path", "status"),
    registry=REGISTRY,
)

REQUEST_DURATION = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency in seconds",
    labelnames=("method", "path"),
    # Buckets tuned for a small JSON API: sub-millisecond up to a 5s timeout.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
    registry=REGISTRY,
)

REQUESTS_IN_PROGRESS = Gauge(
    "http_requests_in_progress",
    "HTTP requests currently being processed",
    labelnames=("method", "path"),
    registry=REGISTRY,
)

TASKS_CREATED = Counter(
    "tasks_created_total",
    "Tasks created successfully",
    registry=REGISTRY,
)

TASKS_DELETED = Counter(
    "tasks_deleted_total",
    "Tasks deleted successfully",
    registry=REGISTRY,
)

DB_UP = Gauge(
    "database_up",
    "1 when the last database health probe succeeded, 0 otherwise",
    registry=REGISTRY,
)
