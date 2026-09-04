/** Wire types shared with the FastAPI backend. */

export interface Task {
  id: number;
  title: string;
  description: string | null;
  completed: boolean;
  created_at: string;
  updated_at: string;
}

export interface TaskListResponse {
  items: Task[];
  total: number;
}

export interface HealthComponent {
  status: string;
  detail: string | null;
  latency_ms: number | null;
}

export interface HealthResponse {
  status: string;
  service: string;
  version: string;
  environment: string;
  checks: Record<string, HealthComponent>;
}

/** The single error envelope every non-2xx backend response uses. */
export interface ApiErrorBody {
  error: {
    code: string;
    message: string;
    request_id: string;
    details?: unknown[];
  };
}
