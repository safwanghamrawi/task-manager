"use client";

import { useCallback, useEffect, useState } from "react";
import { fetchHealth } from "@/lib/api";
import type { HealthResponse } from "@/lib/types";

type Status = "checking" | "healthy" | "degraded" | "unreachable";

const POLL_INTERVAL_MS = 15_000;

const PRESENTATION: Record<Status, { label: string; dot: string; text: string }> = {
  checking: {
    label: "Checking…",
    dot: "bg-slate-400",
    text: "text-slate-600 dark:text-slate-400",
  },
  healthy: {
    label: "Backend healthy",
    dot: "bg-emerald-500",
    text: "text-emerald-700 dark:text-emerald-400",
  },
  degraded: {
    label: "Backend degraded",
    dot: "bg-amber-500",
    text: "text-amber-700 dark:text-amber-400",
  },
  unreachable: {
    label: "Backend unreachable",
    dot: "bg-rose-500",
    text: "text-rose-700 dark:text-rose-400",
  },
};

/** Polls the backend health endpoint and shows the result as a status pill. */
export function BackendStatus() {
  const [status, setStatus] = useState<Status>("checking");
  const [health, setHealth] = useState<HealthResponse | null>(null);

  const check = useCallback(async (): Promise<void> => {
    try {
      const body = await fetchHealth();
      setHealth(body);
      setStatus(body.status === "ok" ? "healthy" : "degraded");
    } catch {
      setHealth(null);
      setStatus("unreachable");
    }
  }, []);

  useEffect(() => {
    void check();
    const timer = setInterval(() => void check(), POLL_INTERVAL_MS);
    // Re-check as soon as the tab is focused again, rather than showing a
    // status that went stale while the tab was in the background.
    const onFocus = () => void check();
    window.addEventListener("focus", onFocus);
    return () => {
      clearInterval(timer);
      window.removeEventListener("focus", onFocus);
    };
  }, [check]);

  const presentation = PRESENTATION[status];
  const latency = health?.checks?.database?.latency_ms;

  return (
    <div
      className="flex items-center gap-2 rounded-full border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium shadow-sm dark:border-slate-800 dark:bg-slate-900"
      role="status"
      aria-live="polite"
    >
      <span className="relative flex h-2 w-2" aria-hidden="true">
        {status === "healthy" && (
          <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-400 opacity-60" />
        )}
        <span className={`relative inline-flex h-2 w-2 rounded-full ${presentation.dot}`} />
      </span>
      <span className={presentation.text}>{presentation.label}</span>
      {health && (
        <span className="hidden text-slate-400 sm:inline dark:text-slate-500">
          v{health.version}
          {typeof latency === "number" ? ` · db ${latency.toFixed(0)} ms` : ""}
        </span>
      )}
    </div>
  );
}
