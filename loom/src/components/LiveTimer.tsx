import { useState, useEffect } from "react";

function fmtElapsed(ms: number): string {
  if (ms < 0) return "0s";
  if (ms < 60_000) return `${Math.floor(ms / 1000)}s`;
  const m = Math.floor(ms / 60_000);
  const s = Math.floor((ms % 60_000) / 1000);
  return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

/**
 * Displays a live-ticking elapsed duration since `startIso`.
 * Ticks every second. Returns null on the first (server-side) render to avoid
 * hydration mismatches.
 *
 * @param startIso  ISO 8601 timestamp to count from.
 * @param className Optional extra classes on the wrapping span.
 */
export function LiveTimer({
  startIso,
  className,
}: {
  startIso: string;
  className?: string;
}) {
  const [elapsed, setElapsed] = useState<number | null>(null);

  useEffect(() => {
    const start = new Date(startIso).getTime();
    const tick = () => setElapsed(Date.now() - start);
    tick(); // run immediately so there's no 1-second blank
    const id = setInterval(tick, 1_000);
    return () => clearInterval(id);
  }, [startIso]);

  if (elapsed === null) return null;
  return <span className={className}>{fmtElapsed(elapsed)}</span>;
}
