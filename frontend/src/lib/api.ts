/**
 * Thin client for the Task Manager API.
 *
 * The base URL comes from the environment so the same image runs against a
 * local backend, a staging host or production without a rebuild. It defaults
 * to the relative `/api`, which the edge routes to the backend — an ALB
 * listener rule in production, a Traefik router locally — so the browser talks
 * to a single origin and no CORS negotiation is involved.
 */

import type { ApiErrorBody, HealthResponse, Task, TaskListResponse } from "./types";

export const API_BASE_URL = (process.env.NEXT_PUBLIC_API_BASE_URL ?? "/api").replace(/\/+$/, "");

/** Milliseconds before a request is abandoned, so the UI can never hang. */
const REQUEST_TIMEOUT_MS = Number(process.env.NEXT_PUBLIC_REQUEST_TIMEOUT_MS ?? 8000);

/** An error carrying the backend's error code and correlation id. */
export class ApiError extends Error {
  readonly status: number;
  readonly code: string;
  readonly requestId: string | null;

  constructor(message: string, status: number, code: string, requestId: string | null) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
    this.requestId = requestId;
  }
}

function isApiErrorBody(value: unknown): value is ApiErrorBody {
  return (
    typeof value === "object" &&
    value !== null &&
    "error" in value &&
    typeof (value as ApiErrorBody).error?.message === "string"
  );
}

async function request<T>(path: string, init: RequestInit = {}): Promise<T> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);

  let response: Response;
  try {
    response = await fetch(`${API_BASE_URL}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        Accept: "application/json",
        ...(init.body ? { "Content-Type": "application/json" } : {}),
        ...init.headers,
      },
      cache: "no-store",
    });
  } catch (cause) {
    // Network failure or timeout: the backend may be restarting.
    const aborted = cause instanceof DOMException && cause.name === "AbortError";
    throw new ApiError(
      aborted ? "The request timed out." : "Could not reach the API.",
      0,
      aborted ? "timeout" : "network_error",
      null,
    );
  } finally {
    clearTimeout(timeout);
  }

  const requestId = response.headers.get("x-request-id");

  if (response.status === 204) {
    return undefined as T;
  }

  const payload: unknown = await response.json().catch(() => null);

  if (!response.ok) {
    const message = isApiErrorBody(payload)
      ? payload.error.message
      : `Request failed with status ${response.status}.`;
    const code = isApiErrorBody(payload) ? payload.error.code : `http_${response.status}`;
    throw new ApiError(message, response.status, code, requestId);
  }

  return payload as T;
}

export function listTasks(): Promise<TaskListResponse> {
  return request<TaskListResponse>("/tasks?limit=200");
}

export function createTask(input: { title: string; description?: string }): Promise<Task> {
  return request<Task>("/tasks", {
    method: "POST",
    body: JSON.stringify({
      title: input.title,
      description: input.description?.trim() ? input.description.trim() : null,
    }),
  });
}

export function deleteTask(id: number): Promise<void> {
  return request<void>(`/tasks/${id}`, { method: "DELETE" });
}

export function fetchHealth(): Promise<HealthResponse> {
  return request<HealthResponse>("/health");
}
