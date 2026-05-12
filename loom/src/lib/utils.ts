import { type ClassValue, clsx } from "clsx";
import { twMerge } from "tailwind-merge";

export function cn(...inputs: ClassValue[]) {
    return twMerge(clsx(inputs));
}

/**
 * Format a millisecond duration as a compact human-readable string.
 *
 * Examples: 500 → "500ms", 29_991 → "30s", 90_000 → "1m 30s"
 *
 * Accepts `null | undefined` so callers don't need a guard before every call;
 * those cases return "—".
 */
export function fmtDuration(ms: number | null | undefined): string {
    if (ms == null || !isFinite(ms) || ms < 0) return "—";
    if (ms < 1_000) return `${Math.round(ms)}ms`;
    if (ms < 60_000) {
        const s = ms / 1_000;
        return Number.isInteger(s) ? `${s}s` : `${s.toFixed(1)}s`;
    }
    if (ms < 3_600_000) {
        const m = Math.floor(ms / 60_000);
        const s = Math.floor((ms % 60_000) / 1_000);
        return s > 0 ? `${m}m ${s}s` : `${m}m`;
    }
    if (ms < 86_400_000) {
        const h = Math.floor(ms / 3_600_000);
        const m = Math.floor((ms % 3_600_000) / 60_000);
        return m > 0 ? `${h}h ${m}m` : `${h}h`;
    }
    const d = Math.floor(ms / 86_400_000);
    const h = Math.floor((ms % 86_400_000) / 3_600_000);
    return h > 0 ? `${d}d ${h}h` : `${d}d`;
}
