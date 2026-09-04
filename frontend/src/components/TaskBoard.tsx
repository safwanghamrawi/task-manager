"use client";

import { useCallback, useEffect, useState } from "react";
import { ApiError, createTask, deleteTask, listTasks } from "@/lib/api";
import type { Task } from "@/lib/types";
import { TaskComposer } from "./TaskComposer";
import { TaskItem } from "./TaskItem";

interface Banner {
  message: string;
  requestId: string | null;
}

function toBanner(error: unknown, fallback: string): Banner {
  if (error instanceof ApiError) {
    return { message: error.message, requestId: error.requestId };
  }
  return { message: fallback, requestId: null };
}

/**
 * Owns the task list state and every write against the API.
 *
 * Writes are not applied optimistically: the list is refreshed from the server
 * after each mutation, so what is on screen is always what is in PostgreSQL.
 * For a list of this size that is one cheap request, and it keeps two browser
 * tabs from drifting apart.
 */
export function TaskBoard() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [loading, setLoading] = useState(true);
  const [banner, setBanner] = useState<Banner | null>(null);
  const [deletingIds, setDeletingIds] = useState<ReadonlySet<number>>(new Set());

  const refresh = useCallback(async (): Promise<void> => {
    try {
      const body = await listTasks();
      setTasks(body.items);
      setBanner(null);
    } catch (error) {
      setBanner(toBanner(error, "Could not load tasks."));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleCreate = useCallback(
    async (input: { title: string; description?: string }): Promise<void> => {
      try {
        const created = await createTask(input);
        setTasks((current) => [created, ...current]);
        setBanner(null);
      } catch (error) {
        setBanner(toBanner(error, "Could not create the task."));
        throw error;
      }
    },
    [],
  );

  const handleDelete = useCallback(
    async (id: number): Promise<void> => {
      setDeletingIds((current) => new Set(current).add(id));
      try {
        await deleteTask(id);
        setTasks((current) => current.filter((task) => task.id !== id));
        setBanner(null);
      } catch (error) {
        // A 404 means someone else already deleted it; reconcile rather than
        // leaving a phantom row on screen.
        if (error instanceof ApiError && error.status === 404) {
          setTasks((current) => current.filter((task) => task.id !== id));
          return;
        }
        setBanner(toBanner(error, "Could not delete the task."));
      } finally {
        setDeletingIds((current) => {
          const next = new Set(current);
          next.delete(id);
          return next;
        });
      }
    },
    [],
  );

  return (
    <section className="flex flex-col gap-5">
      <TaskComposer onCreate={handleCreate} disabled={loading && tasks.length === 0} />

      {banner && (
        <div
          role="alert"
          className="flex items-start justify-between gap-4 rounded-xl border border-rose-200 bg-rose-50 p-4 text-sm text-rose-800 dark:border-rose-900 dark:bg-rose-950 dark:text-rose-200"
        >
          <div>
            <p className="font-medium">{banner.message}</p>
            {banner.requestId && (
              <p className="mt-1 font-mono text-xs opacity-70">request {banner.requestId}</p>
            )}
          </div>
          <button
            type="button"
            onClick={() => void refresh()}
            className="shrink-0 rounded-lg border border-rose-300 px-3 py-1.5 text-xs font-medium transition hover:bg-rose-100 dark:border-rose-800 dark:hover:bg-rose-900"
          >
            Retry
          </button>
        </div>
      )}

      <div className="flex items-center justify-between">
        <h2 className="text-sm font-semibold text-slate-700 dark:text-slate-300">
          Tasks{!loading && ` (${tasks.length})`}
        </h2>
        <button
          type="button"
          onClick={() => void refresh()}
          className="text-xs font-medium text-slate-500 underline-offset-4 transition hover:text-slate-900 hover:underline dark:text-slate-400 dark:hover:text-slate-100"
        >
          Refresh
        </button>
      </div>

      {loading ? (
        <ul className="flex flex-col gap-3" aria-busy="true">
          {[0, 1, 2].map((index) => (
            <li
              key={index}
              className="h-20 animate-pulse rounded-xl border border-slate-200 bg-white dark:border-slate-800 dark:bg-slate-900"
            />
          ))}
        </ul>
      ) : tasks.length === 0 ? (
        <p className="rounded-xl border border-dashed border-slate-300 p-8 text-center text-sm text-slate-500 dark:border-slate-700 dark:text-slate-400">
          No tasks yet. Add the first one above.
        </p>
      ) : (
        <ul className="flex flex-col gap-3">
          {tasks.map((task) => (
            <TaskItem
              key={task.id}
              task={task}
              onDelete={handleDelete}
              deleting={deletingIds.has(task.id)}
            />
          ))}
        </ul>
      )}
    </section>
  );
}
