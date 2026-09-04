import { TaskBoard } from "@/components/TaskBoard";
import { BackendStatus } from "@/components/BackendStatus";

/**
 * The shell is a server component; everything that needs interactivity is a
 * client island below it. Tasks are fetched in the browser so the page itself
 * stays static and cacheable, and so a backend outage degrades to an error
 * banner instead of a failed render.
 */
export default function HomePage() {
  return (
    <div className="mx-auto flex min-h-full max-w-3xl flex-col gap-8 px-5 py-10 sm:py-16">
      <header className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold tracking-tight sm:text-3xl">Task Manager</h1>
          <p className="mt-1 text-sm text-slate-600 dark:text-slate-400">
            Next.js frontend, FastAPI backend, PostgreSQL persistence.
          </p>
        </div>
        <BackendStatus />
      </header>

      <main className="flex-1">
        <TaskBoard />
      </main>

      <footer className="border-t border-slate-200 pt-5 text-xs text-slate-500 dark:border-slate-800 dark:text-slate-500">
        Same-origin API · health at <code className="font-mono">/api/health</code> · metrics served
        at <code className="font-mono">/metrics</code>, restricted to an allowlist
      </footer>
    </div>
  );
}
