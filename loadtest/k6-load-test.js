/**
 * k6 load test for the Task Manager API.
 *
 * Default profile: ramp to 100 virtual users, hold for 30s, ramp down.
 *
 *   BASE_URL=http://localhost k6 run loadtest/k6-load-test.js
 *   docker run --rm -i --network edge -e BASE_URL=http://traefik \
 *     -v "$PWD/loadtest:/scripts" grafana/k6 run /scripts/k6-load-test.js
 *
 * The test drives real writes, so it creates and then deletes its own tasks;
 * `teardown` sweeps anything a mid-test abort left behind.
 */

import http from "k6/http";
import { check, group, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import { randomIntBetween } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

const BASE_URL = (__ENV.BASE_URL || "http://localhost").replace(/\/+$/, "");
const API = `${BASE_URL}/api`;

const VUS = Number(__ENV.VUS || 100);
const DURATION = __ENV.DURATION || "30s";

// --- Custom metrics ---------------------------------------------------------
// The built-in http_req_duration mixes every endpoint together; these split
// read latency from write latency, which is what capacity planning needs.
const listLatency = new Trend("task_list_duration", true);
const createLatency = new Trend("task_create_duration", true);
const deleteLatency = new Trend("task_delete_duration", true);
const businessErrors = new Rate("business_errors");
const tasksCreated = new Counter("tasks_created");
const tasksDeleted = new Counter("tasks_deleted");

export const options = {
  scenarios: {
    // 1. Prove the system works at all before hammering it. A failing smoke
    //    test aborts the run, so a broken deployment is not reported as a
    //    latency regression.
    smoke: {
      executor: "shared-iterations",
      vus: 1,
      iterations: 1,
      exec: "smokeTest",
      tags: { scenario: "smoke" },
    },

    // 2. The headline scenario: 100 VUs for 30 seconds, with short ramps so
    //    the numbers reflect steady state rather than connection setup.
    load: {
      executor: "ramping-vus",
      startTime: "5s",
      startVUs: 0,
      stages: [
        { duration: "10s", target: VUS },
        { duration: DURATION, target: VUS },
        { duration: "5s", target: 0 },
      ],
      exec: "loadTest",
      gracefulRampDown: "10s",
      tags: { scenario: "load" },
    },
  },

  // Thresholds are the pass/fail contract. A breached threshold exits non-zero
  // so CI can gate a release on it.
  thresholds: {
    http_req_failed: ["rate<0.01"], //   <1% transport-level failures
    business_errors: ["rate<0.01"], //   <1% unexpected status codes
    http_req_duration: ["p(95)<500", "p(99)<1000"],
    task_list_duration: ["p(95)<400"],
    task_create_duration: ["p(95)<600"],
    checks: ["rate>0.99"],
  },

  // Cap the summary's cardinality and keep the JSON export readable.
  summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"],
  noConnectionReuse: false,
  discardResponseBodies: false,
};

const JSON_HEADERS = { "Content-Type": "application/json" };

/** Runs once, before the load scenario. Fails fast on a broken deployment. */
export function setup() {
  const health = http.get(`${API}/health`, { tags: { endpoint: "health" } });
  const ok = check(health, {
    "health endpoint returns 200": (r) => r.status === 200,
    "backend reports itself healthy": (r) => r.json("status") === "ok",
    "database is reachable": (r) => r.json("checks.database.status") === "up",
  });

  if (!ok) {
    throw new Error(`Backend is not healthy at ${API}/health (status ${health.status})`);
  }
  return { startedAt: new Date().toISOString() };
}

/** One pass over every endpoint, asserting the full contract. */
export function smokeTest() {
  group("smoke: full CRUD cycle", () => {
    const created = http.post(
      `${API}/tasks`,
      JSON.stringify({ title: "k6 smoke task", description: "created by the smoke scenario" }),
      { headers: JSON_HEADERS, tags: { endpoint: "tasks_create" } },
    );
    check(created, {
      "create returns 201": (r) => r.status === 201,
      "create returns an id": (r) => Number(r.json("id")) > 0,
      "create echoes a request id": (r) => Boolean(r.headers["X-Request-Id"]),
    });

    const list = http.get(`${API}/tasks`, { tags: { endpoint: "tasks_list" } });
    check(list, {
      "list returns 200": (r) => r.status === 200,
      "list is an envelope with items": (r) => Array.isArray(r.json("items")),
    });

    const id = created.json("id");
    const removed = http.del(`${API}/tasks/${id}`, null, { tags: { endpoint: "tasks_delete" } });
    check(removed, { "delete returns 204": (r) => r.status === 204 });

    const missing = http.del(`${API}/tasks/${id}`, null, { tags: { endpoint: "tasks_delete" } });
    check(missing, {
      "deleting twice returns 404": (r) => r.status === 404,
      "errors use the shared envelope": (r) => r.json("error.code") === "task_not_found",
    });
  });
}

/**
 * The load profile. Reads dominate, as they do in a real task list: roughly
 * 70% list, 30% create-then-delete.
 */
export function loadTest() {
  const listResponse = http.get(`${API}/tasks?limit=50`, { tags: { endpoint: "tasks_list" } });
  listLatency.add(listResponse.timings.duration);
  const listOk = check(listResponse, {
    "list returns 200": (r) => r.status === 200,
  });
  businessErrors.add(!listOk);

  // 30% of iterations perform a write.
  if (randomIntBetween(1, 10) <= 3) {
    const payload = JSON.stringify({
      title: `k6 task ${__VU}-${__ITER}`,
      description: "generated by the k6 load scenario",
    });

    const createResponse = http.post(`${API}/tasks`, payload, {
      headers: JSON_HEADERS,
      tags: { endpoint: "tasks_create" },
    });
    createLatency.add(createResponse.timings.duration);

    const createOk = check(createResponse, {
      "create returns 201": (r) => r.status === 201,
    });
    businessErrors.add(!createOk);

    if (createOk) {
      tasksCreated.add(1);
      // Clean up immediately so the table does not grow without bound during
      // the run, which would otherwise skew list latency over time.
      const deleteResponse = http.del(`${API}/tasks/${createResponse.json("id")}`, null, {
        tags: { endpoint: "tasks_delete" },
      });
      deleteLatency.add(deleteResponse.timings.duration);
      const deleteOk = check(deleteResponse, { "delete returns 204": (r) => r.status === 204 });
      businessErrors.add(!deleteOk);
      if (deleteOk) tasksDeleted.add(1);
    }
  }

  // Think time: without it 100 VUs behave like 100 tight loops, which measures
  // the client more than the service.
  sleep(randomIntBetween(1, 3) / 10);
}

/** Remove anything an aborted iteration left in the database. */
export function teardown() {
  const response = http.get(`${API}/tasks?limit=200`, { tags: { endpoint: "tasks_list" } });
  if (response.status !== 200) return;

  for (const task of response.json("items")) {
    if (typeof task.title === "string" && task.title.startsWith("k6 ")) {
      http.del(`${API}/tasks/${task.id}`, null, { tags: { endpoint: "tasks_delete" } });
    }
  }
}
