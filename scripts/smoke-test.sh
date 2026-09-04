#!/usr/bin/env bash
#
# Post-deployment verification: exercise every endpoint against a running
# stack and exit non-zero on the first failure. Safe to run against production
# — it deletes the task it creates.
#
#   ./scripts/smoke-test.sh                  # http://localhost
#   ./scripts/smoke-test.sh http://1.2.3.4
set -euo pipefail

BASE_URL="${1:-${BASE_URL:-http://localhost}}"
BASE_URL="${BASE_URL%/}"
API="${BASE_URL}/api"
failures=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }
warn() { printf '  \033[33mWARN\033[0m %s\n' "$1"; }

expect_status() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then pass "${description} (${actual})"
  else fail "${description}: expected ${expected}, got ${actual}"; fi
}

echo "==> Smoke testing ${BASE_URL}"

echo "Frontend"
status="$(curl -fsS -o /dev/null -w '%{http_code}' "${BASE_URL}/" || echo 000)"
expect_status "GET / serves the UI" 200 "${status}"

echo "Health"
health="$(curl -fsS "${API}/health" || echo '{}')"
if grep -q '"status":"ok"' <<<"${health}"; then pass "GET /api/health reports ok"
else fail "GET /api/health did not report ok: ${health}"; fi
if grep -q '"status":"up"' <<<"${health}"; then pass "database check reports up"
else fail "database check is not up"; fi

echo "Tasks"
created="$(curl -fsS -X POST "${API}/tasks" \
  -H 'Content-Type: application/json' \
  -d '{"title":"smoke-test task","description":"created by smoke-test.sh"}' || echo '{}')"
task_id="$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' <<<"${created}")"
if [[ -n "${task_id}" ]]; then pass "POST /api/tasks created task #${task_id}"
else fail "POST /api/tasks did not return an id: ${created}"; fi

status="$(curl -fsS -o /dev/null -w '%{http_code}' "${API}/tasks")"
expect_status "GET /api/tasks lists tasks" 200 "${status}"

if [[ -n "${task_id}" ]]; then
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${API}/tasks/${task_id}")"
  expect_status "DELETE /api/tasks/${task_id}" 204 "${status}"
  status="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${API}/tasks/${task_id}")"
  expect_status "DELETE of a missing task is a 404" 404 "${status}"
fi

echo "Validation"
status="$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${API}/tasks" \
  -H 'Content-Type: application/json' -d '{"title":""}')"
expect_status "POST with an empty title is rejected" 422 "${status}"

echo "Security"
status="$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/metrics")"
if [[ "${status}" == "403" ]]; then
  pass "/metrics is blocked by the edge IP allowlist (403)"
elif [[ "${status}" == "200" ]]; then
  # Expected when running from inside the allowlist — ADMIN_ALLOWED_CIDRS
  # locally, admin_allowed_cidrs on the ALB. From a public client this must
  # be a 403.
  warn "/metrics answered 200 — verify this client is inside ADMIN_ALLOWED_CIDRS"
else
  fail "/metrics returned an unexpected ${status}"
fi

echo
if (( failures > 0 )); then
  printf '\033[31m%d check(s) failed\033[0m\n' "${failures}"
  exit 1
fi
printf '\033[32mAll smoke checks passed\033[0m\n'
