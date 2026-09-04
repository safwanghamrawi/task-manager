/** Small presentation helpers. */

const RELATIVE = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

const DIVISIONS: { amount: number; unit: Intl.RelativeTimeFormatUnit }[] = [
  { amount: 60, unit: "second" },
  { amount: 60, unit: "minute" },
  { amount: 24, unit: "hour" },
  { amount: 7, unit: "day" },
  { amount: 4.34524, unit: "week" },
  { amount: 12, unit: "month" },
  { amount: Number.POSITIVE_INFINITY, unit: "year" },
];

/** Render an ISO timestamp as e.g. "3 minutes ago". */
export function relativeTime(isoTimestamp: string): string {
  const timestamp = new Date(isoTimestamp).getTime();
  if (Number.isNaN(timestamp)) return "unknown";

  let duration = (timestamp - Date.now()) / 1000;
  for (const division of DIVISIONS) {
    if (Math.abs(duration) < division.amount) {
      return RELATIVE.format(Math.round(duration), division.unit);
    }
    duration /= division.amount;
  }
  return "a long time ago";
}

/** Absolute timestamp for the element's tooltip. */
export function absoluteTime(isoTimestamp: string): string {
  const date = new Date(isoTimestamp);
  return Number.isNaN(date.getTime()) ? isoTimestamp : date.toLocaleString();
}
