# syntax=docker/dockerfile:1.7

###############################################################################
# Stage 1 - builder: resolve and compile dependencies into a self-contained
# virtualenv. Build toolchains stay in this stage and never reach the runtime
# image.
###############################################################################
FROM python:3.12-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /build

# Dependencies are copied on their own so this layer is cached across every
# change to application code.
COPY requirements.txt ./
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

###############################################################################
# Stage 2 - dev-deps: production dependencies plus the test and lint toolchain.
# Shared by the `test` and `dev` stages below.
###############################################################################
FROM builder AS dev-deps

ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONPATH=/app \
    # `app.main` builds the application at import time and refuses to start
    # without a database URL — that fail-fast behaviour is deliberate, so the
    # test stage supplies a throw-away in-memory database instead of relaxing it.
    DATABASE_URL=sqlite+aiosqlite:///:memory:

COPY requirements-dev.txt ./
RUN /opt/venv/bin/pip install --no-cache-dir -r requirements-dev.txt

WORKDIR /app
COPY pyproject.toml ./
COPY app ./app
COPY tests ./tests

###############################################################################
# Stage 3 - test: runs during `docker build --target test`. Keeping it in this
# Dockerfile guarantees the suite runs against the exact interpreter and
# dependency set that ships to production.
###############################################################################
FROM dev-deps AS test

RUN ruff check . && ruff format --check . && mypy app && pytest

###############################################################################
# Stage 4 - dev: hot-reloading server for local development. Source is
# bind-mounted over /app/app by docker-compose.override.yml.
###############################################################################
FROM dev-deps AS dev

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]

###############################################################################
# Stage 5 - runtime: slim, non-root, no build tools, no package manager cache.
###############################################################################
FROM python:3.12-slim-bookworm AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONFAULTHANDLER=1 \
    PATH="/opt/venv/bin:$PATH"

# curl is used by the container healthcheck only; ~1MB and avoids shipping a
# second HTTP client. Everything else is dropped and the apt lists removed.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system --gid 10001 app \
    && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /opt/venv /opt/venv

WORKDIR /app
COPY --chown=root:root app ./app

# Least privilege: the process owns nothing it executes, so it cannot rewrite
# its own code even if compromised. Combined with read_only + tmpfs in compose.
USER 10001:10001

EXPOSE 8000

# Liveness, not readiness: if the database is down, restarting this container
# fixes nothing and a crash-loop only makes recovery slower. Docker restarts
# the container only when the process itself is wedged.
HEALTHCHECK --interval=15s --timeout=3s --start-period=20s --retries=3 \
    CMD curl --fail --silent --show-error http://127.0.0.1:8000/health/live || exit 1

# One worker per container: metrics stay accurate without Prometheus
# multiprocess mode, and horizontal scaling is done with replicas instead.
# Uvicorn traps SIGTERM, drains in-flight requests, then runs the lifespan
# shutdown hook that disposes the connection pool.
CMD ["uvicorn", "app.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--workers", "1", \
     "--proxy-headers", \
     "--forwarded-allow-ips", "*", \
     "--timeout-graceful-shutdown", "20", \
     "--no-access-log"]
