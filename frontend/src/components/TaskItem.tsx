"use client";

import { absoluteTime, relativeTime } from "@/lib/format";
import type { Task } from "@/lib/types";

interface TaskItemProps {
  task: Task;
  onDelete: (id: number) => Promise<void>;
  deleting: boolean;
}

export function TaskItem({ task, onDelete, deleting }: TaskItemProps) {
  return (
    <li
      className={`flex items-start justify-between gap-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm transition dark:border-slate-800 dark:bg-slate-900 ${
        deleting ? "opacity-50" : ""
      }`}
    >
      <div className="min-w-0">
        <p className="truncate text-sm font-medium text-slate-900 dark:text-slate-100">
          {task.title}
        </p>
        {task.description && (
          <p className="mt-1 whitespace-pre-wrap text-sm text-slate-600 dark:text-slate-400">
            {task.description}
          </p>
        )}
        <p className="mt-2 text-xs text-slate-400 dark:text-slate-600">
          <time dateTime={task.created_at} title={absoluteTime(task.created_at)}>
            created {relativeTime(task.created_at)}
          </time>
          <span className="mx-1.5">·</span>
          <span className="font-mono">#{task.id}</span>
        </p>
      </div>

      <button
        type="button"
        onClick={() => void onDelete(task.id)}
        disabled={deleting}
        aria-label={`Delete task: ${task.title}`}
        className="shrink-0 rounded-lg border border-slate-200 px-3 py-1.5 text-xs font-medium text-slate-600 transition hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700 disabled:cursor-not-allowed disabled:opacity-50 dark:border-slate-700 dark:text-slate-400 dark:hover:border-rose-800 dark:hover:bg-rose-950 dark:hover:text-rose-400"
      >
        {deleting ? "Deleting…" : "Delete"}
      </button>
    </li>
  );
}
