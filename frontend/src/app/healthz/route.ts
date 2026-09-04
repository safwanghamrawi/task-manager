import { NextResponse } from "next/server";

/**
 * Container-level liveness probe for the frontend.
 *
 * Deliberately does not call the backend: this answers "is this Next.js server
 * able to serve?", and nothing more. If it also checked the API, a backend
 * outage would take down a perfectly healthy frontend with it — on ECS the
 * scheduler would replace every task; locally Docker would restart them.
 *
 * This path IS publicly reachable. It matches no ALB rule, so it falls through
 * to the frontend like any other page, and Traefik's catch-all does the same
 * locally. That is fine: it discloses only that this server is up. The
 * endpoints worth restricting — /docs and /metrics — are handled at the edge.
 */
export const dynamic = "force-dynamic";

export function GET() {
  return NextResponse.json({
    status: "ok",
    service: "task-manager-web",
    uptime_seconds: Math.round(process.uptime()),
  });
}
