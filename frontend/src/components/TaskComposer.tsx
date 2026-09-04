"use client";

import { useState, type FormEvent } from "react";

const MAX_TITLE_LENGTH = 200;

interface TaskComposerProps {
  onCreate: (input: { title: string; description?: string }) => Promise<void>;
  disabled: boolean;
}

/** The "add a task" form. Validation mirrors the backend's constraints. */
export function TaskComposer({ onCreate, disabled }: TaskComposerProps) {
  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const trimmedTitle = title.trim();
  const canSubmit = trimmedTitle.length > 0 && !submitting && !disabled;

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!canSubmit) return;

    setSubmitting(true);
    try {
      await onCreate({ title: trimmedTitle, description });
      // Only clear the form once the write has been acknowledged, so a failed
      // request never loses what the user typed.
      setTitle("");
      setDescription("");
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm dark:border-slate-800 dark:bg-slate-900"
    >
      <div className="flex flex-col gap-3">
        <div>
          <label htmlFor="task-title" className="sr-only">
            Task title
          </label>
          <input
            id="task-title"
            name="title"
            value={title}
            onChange={(event) => setTitle(event.target.value)}
            maxLength={MAX_TITLE_LENGTH}
            placeholder="What needs doing?"
            autoComplete="off"
            required
            className="w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm placeholder:text-slate-400 focus:border-sky-500 focus:outline-none dark:border-slate-700 dark:bg-slate-950 dark:placeholder:text-slate-600"
          />
        </div>

        <div>
          <label htmlFor="task-description" className="sr-only">
            Description (optional)
          </label>
          <textarea
            id="task-description"
            name="description"
            value={description}
            onChange={(event) => setDescription(event.target.value)}
            maxLength={2000}
            rows={2}
            placeholder="Add a note (optional)"
            className="w-full resize-y rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm placeholder:text-slate-400 focus:border-sky-500 focus:outline-none dark:border-slate-700 dark:bg-slate-950 dark:placeholder:text-slate-600"
          />
        </div>

        <div className="flex items-center justify-between gap-3">
          <span className="text-xs text-slate-400 dark:text-slate-600">
            {trimmedTitle.length}/{MAX_TITLE_LENGTH}
          </span>
          <button
            type="submit"
            disabled={!canSubmit}
            className="inline-flex items-center gap-2 rounded-lg bg-slate-900 px-4 py-2 text-sm font-medium text-white transition hover:bg-slate-700 disabled:cursor-not-allowed disabled:opacity-40 dark:bg-white dark:text-slate-900 dark:hover:bg-slate-200"
          >
            {submitting ? "Adding…" : "Add task"}
          </button>
        </div>
      </div>
    </form>
  );
}
