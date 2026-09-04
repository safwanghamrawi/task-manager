# Task Manager

A small task manager built the way a production service is built: a Next.js UI,
a FastAPI service, PostgreSQL for persistence.

The feature set is deliberately tiny — list, create and delete a task. The
engineering around it is the point.

- [Install locally](#install-locally)
- [What you get](#what-you-get)
- [Everyday commands](#everyday-commands)
- [Verify it works](#verify-it-works)
- [Load testing](#load-testing)
- [Working on the code](#working-on-the-code)
- [Troubleshooting](#troubleshooting)

---

## Install locally

### Prerequisites

**Docker, with Compose v2. That is the whole list.**

Python, Node, PostgreSQL and the linters all run inside containers, so
nothing else needs to be on your machine and nothing is installed onto it.

```bash
docker --version           # 24+ is fine
docker compose version     # must be v2 — "docker-compose" v1 will not work
```

### Three steps

```bash
git clone <this repo> && cd sg-test

make env      # creates .env from .env.example
make up       # builds the images and starts everything
```

`make up` prints the URLs when it finishes. First run takes a few minutes while
the images build; later runs take seconds.

**You do not need to edit `.env` to get started.** The defaults work as-is for
local development. Two things are worth knowing about it:

| Variable | Why it matters locally |
|---|---|
| `DOCKERHUB_NAMESPACE` | Required, even though local dev never pulls it. Compose resolves the base file's image names before the dev override replaces them, so it must be set to *something*. The placeholder in `.env.example` is fine |
| `HTTP_PORT` | The port the UI is served on, default `80`. Set it to `8080` if port 80 is taken or your system will not hand it to a non-root process |

`POSTGRES_PASSWORD` only guards a throwaway local database, so the placeholder
is fine here too. It is a real secret in production, where it is generated into
AWS Secrets Manager and never written to a file.

### Open it

```
http://localhost           the UI
http://localhost/api/tasks the API
http://localhost:8000/docs OpenAPI docs, straight to the backend
```

If you changed `HTTP_PORT`, the first two move with it — `http://localhost:8080`
and so on. **Trust what `make up` printed over this list**; it reads the real
value from `.env`.

---

## What you get

Four containers, plus an optional fifth:

| Service | What it is | Port |
|---|---|---|
| `traefik` | The local edge. Routes `/` to the frontend and `/api` to the backend so both share one origin — which is what production's load balancer does. The only container publishing a port | **80** |
| `frontend` | Next.js 15, React 19, hot reload | 127.0.0.1:3000 |
| `backend` | FastAPI on Python 3.12, hot reload | 127.0.0.1:8000 |
| `postgres` | PostgreSQL 17. Data lives in a named volume and survives restarts | 127.0.0.1:5432 |
| `prometheus` | Optional — `make monitoring`. Scrapes the backend's metrics | 127.0.0.1:9090 |

Everything but Traefik binds to `127.0.0.1`, so nothing is exposed to your
network. The database sits on a Docker network declared `internal: true`, which
strips its gateway — it has no route to the internet at all.

Sharing one origin is why the UI calls a relative `/api` and no CORS is
involved, locally or in production.

---

## Everyday commands

`make help` lists all 27 targets. The ones you will actually use:

```bash
make up          # start everything, with hot reload
make down        # stop, keeping the database
make logs        # follow structured logs from every service
make ps          # what is running, and is it healthy
make clean       # stop AND delete the database volume
```

Editing a file under `backend/app/` or `frontend/src/` reloads that service
automatically — both source trees are bind-mounted read-only into the
containers. No rebuild, no restart.

---

## Verify it works

```bash
make smoke
```

This exercises every endpoint against the running stack: it loads the UI,
checks health, creates a task, lists it, deletes it, confirms the delete 404s
on a second attempt, and confirms an empty title is rejected with a 422. It
cleans up the task it creates, so it is safe to re-run.

If you changed `HTTP_PORT`, pass the URL:

```bash
./scripts/smoke-test.sh http://localhost:8080
```

One check may print `WARN` rather than `PASS`: the `/metrics` endpoint is
restricted to an IP allowlist that includes Docker's own network, so a request
from inside the compose network legitimately succeeds where a public one would
get a 403. That is expected locally.

---

## Load testing

```bash
./scripts/run-loadtest.sh
```

Runs [`loadtest/k6-load-test.js`](loadtest/k6-load-test.js) in the official
`grafana/k6` container, so **k6 does not need to be installed**. The container
joins the compose `edge` network and addresses Traefik by service name, so
traffic takes the same path a real client's would — through the edge, not
straight at the backend.

The stack has to be running first (`make up`).

### What it runs

Two scenarios, in order:

1. **Smoke** — 1 VU, one full CRUD cycle. It runs first and aborts the whole
   run if it fails, so a broken deployment is reported as broken rather than as
   a latency regression.
2. **Load** — ramps to 100 VUs over 10s, holds 30s, ramps down over 5s. Each
   iteration lists tasks, sometimes creates and deletes one, and sleeps
   0.1–0.3s between iterations to behave like a client rather than a tight
   loop.

### Thresholds are the pass/fail contract

A breached threshold exits non-zero, so this can gate a release:

| Threshold | Meaning |
|---|---|
| `http_req_failed: rate<0.01` | under 1% transport-level failures |
| `business_errors: rate<0.01` | under 1% unexpected status codes |
| `http_req_duration: p(95)<500, p(99)<1000` | overall latency, ms |
| `task_list_duration: p(95)<400` | the read path |
| `task_create_duration: p(95)<600` | the write path |
| `checks: rate>0.99` | assertions that passed |

Alongside k6's built-ins it records `task_list_duration`,
`task_create_duration`, `task_delete_duration`, `business_errors`,
`tasks_created` and `tasks_deleted`, so a slow read is distinguishable from a
slow write.

### Tuning it

All three are environment variables:

```bash
VUS=200 DURATION=60s ./scripts/run-loadtest.sh     # heavier
BASE_URL=http://localhost:8080 ./scripts/run-loadtest.sh
```

| Variable | Default | Notes |
|---|---|---|
| `VUS` | `100` | Virtual users at the plateau |
| `DURATION` | `30s` | Length of the plateau, excluding ramps |
| `BASE_URL` | `http://traefik` | A `//traefik` or `//backend` URL joins the compose network; anything else is treated as external and does not |
| `NETWORK` | `edge` | The compose network to join |

### Results

Every run writes two timestamped files to `loadtest/results/`:

```
run-20260903T211928Z.log        the full console output
summary-20260903T211928Z.json   machine-readable summary
```

### Against the deployed stack

```bash
BASE_URL="$(terraform -chdir=infra/terraform output -raw app_url)" \
  ./scripts/run-loadtest.sh
```

Raise `waf_rate_limit` first. A load test from a single address deliberately
sends far more than one client's fair share, so WAF will do exactly what it is
there for and you will measure the rate limiter instead of the application.

---

## Working on the code

```bash
make test            # backend suite, ruff and mypy — all inside the image
make lint-frontend   # ESLint and tsc, in a container
make check           # everything CI runs
```

`make test` builds the backend image's `test` stage, so the suite runs against
the exact interpreter and dependency set that ships. The suite defaults to
SQLite so it needs no services; CI runs the same tests against a real
PostgreSQL to catch driver-level differences.

To run tests directly instead:

```bash
cd backend && pytest -v
```

---

## Troubleshooting

**`make up` fails with `DOCKERHUB_NAMESPACE is required`**
You have no `.env`. Run `make env`.

**Port 80 already in use, or permission denied binding it**
Set `HTTP_PORT=8080` in `.env` and `make up` again. Common on systems that
reserve ports below 1024 for root.

**`http://localhost` refuses the connection**
Almost always `HTTP_PORT` pointing somewhere else. Check which port Traefik
actually took:

```bash
docker compose ps traefik      # look at the PORTS column
grep HTTP_PORT .env
```

**The UI loads but the API returns 502**
The backend has not finished starting, or it cannot reach the database.

```bash
make ps                        # is backend healthy?
docker compose logs backend | tail -40
```

**Everything is wedged**

```bash
make clean && make up          # destroys local data and rebuilds
```
