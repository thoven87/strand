import { useMemo, useState } from "react";
import { Link } from "@tanstack/react-router";
import { parseISO, format } from "date-fns";
import { cn } from "@/lib/utils";
import type { ScheduleRun, UpcomingSlot } from "@/api/schedules";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface PartitionGridProps {
    runs: ScheduleRun[];
    upcoming: UpcomingSlot[];
    namespace: string;
    scheduleId: string;
    queue: string;
}

type CellState =
    | "COMPLETED"
    | "FAILED"
    | "RUNNING"
    | "PENDING"
    | "CANCELLED"
    | "SLEEPING"
    | "WAITING"
    | "CONTINUED_AS_NEW"
    | "UPCOMING"
    | "MISSING";

interface CellData {
    state: CellState;
    runId: string | null;
    durationSec: number | null;
    isoLabel: string; // "2026-06-08T06:00 UTC"
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/**
 * Extract "YYYY-MM-DD" and "HH:MM" from an ISO string, always in UTC.
 *
 * NEVER pass UTC Date objects through date-fns `format()` for the date portion:
 * `format(new Date(Date.UTC(y, m, d)), "yyyy-MM-dd")` formats in *local* timezone,
 * so users outside UTC see dates shifted by ±1 day (e.g. midnight UTC appears
 * as 8 pm the previous evening in UTC-4, giving the wrong YYYY-MM-DD).
 *
 * Solution: extract UTC components and build the strings directly — no
 * timezone conversion involved at any point.
 */
function splitUTC(iso: string): { date: string; slot: string } {
    const d = parseISO(iso);
    const year = d.getUTCFullYear();
    const month = String(d.getUTCMonth() + 1).padStart(2, "0");
    const day = String(d.getUTCDate()).padStart(2, "0");
    const date = `${year}-${month}-${day}`;
    const slot = `${String(d.getUTCHours()).padStart(2, "0")}:${String(d.getUTCMinutes()).padStart(2, "0")}`;
    return { date, slot };
}

/**
 * Returns true when a specific `YYYY-MM-DD` + `HH:MM` UTC slot is strictly
 * in the past relative to the current UTC time.  Used so that today's already-
 * elapsed slots (e.g. 00:00 when it's now 14:00 UTC) are marked MISSING rather
 * than being left in an ambiguous state.
 */
function isSlotInPast(date: string, slot: string): boolean {
    const slotMs = new Date(`${date}T${slot}:00Z`).getTime();
    return slotMs < Date.now();
}

/** Friendly header label for a date string "YYYY-MM-DD" (UTC). */
function dateLabel(isoDate: string): string {
    const [y, m, d] = isoDate.split("-").map(Number);
    // Use noon UTC so the date is stable in every timezone (UTC−12 to UTC+14).
    // Midnight UTC would appear as the previous evening in UTC-negative zones
    // and format() would then give the wrong date label.
    return format(new Date(Date.UTC(y, m - 1, d, 12)), "MMM d  EEE");
}

// ── Cell styling map ──────────────────────────────────────────────────────────

const CELL_CONFIG: Record<
    CellState,
    { bg: string; text: string; border: string; glyph: string; pulse?: boolean }
> = {
    COMPLETED: {
        bg: "bg-green-500/25 hover:bg-green-500/40",
        text: "text-green-300",
        border: "border-green-500/35",
        glyph: "✓",
    },
    FAILED: {
        bg: "bg-red-500/25 hover:bg-red-500/40",
        text: "text-red-300",
        border: "border-red-500/35",
        glyph: "✗",
    },
    RUNNING: {
        bg: "bg-yellow-500/25 hover:bg-yellow-500/40",
        text: "text-yellow-300",
        border: "border-yellow-500/35",
        glyph: "●",
        pulse: true,
    },
    PENDING: {
        bg: "bg-slate-500/15 hover:bg-slate-500/25",
        text: "text-slate-400",
        border: "border-slate-500/25",
        glyph: "·",
    },
    CANCELLED: {
        bg: "bg-slate-500/15 hover:bg-slate-500/25",
        text: "text-slate-500",
        border: "border-slate-500/20",
        glyph: "✗",
    },
    // SLEEPING / WAITING / CONTINUED_AS_NEW map to PENDING visually —
    // these are live states that can briefly appear while the task runs.
    SLEEPING: {
        bg: "bg-indigo-500/15 hover:bg-indigo-500/25",
        text: "text-indigo-400",
        border: "border-indigo-500/25",
        glyph: "·",
    },
    WAITING: {
        bg: "bg-violet-500/15 hover:bg-violet-500/25",
        text: "text-violet-400",
        border: "border-violet-500/25",
        glyph: "·",
    },
    CONTINUED_AS_NEW: {
        bg: "bg-slate-500/15 hover:bg-slate-500/25",
        text: "text-slate-400",
        border: "border-slate-500/20",
        glyph: "↻",
    },
    UPCOMING: {
        bg: "bg-slate-500/8",
        text: "text-muted-foreground/40",
        border: "border-border/30 border-dashed",
        glyph: "–",
    },
    // MISSING = expected slot that never ran.
    // Amber (not red) so it's clearly distinct from actual failures.
    // Dagster uses a similar warm-orange convention for missing partitions.
    MISSING: {
        bg: "bg-amber-500/10 hover:bg-amber-500/20",
        text: "text-amber-500/60",
        border: "border-amber-500/30 border-dashed",
        glyph: "!",
    },
};

// ── Cell component ────────────────────────────────────────────────────────────

interface GridCellProps {
    cell: CellData;
    namespace: string;
    queue: string;
}

function GridCell({ cell, namespace, queue }: GridCellProps) {
    // Fallback: unknown task states (e.g. future additions) render as PENDING
    // rather than crashing with "cfg is undefined".
    const cfg = CELL_CONFIG[cell.state] ?? CELL_CONFIG["PENDING"];

    // inline-flex so text-center on the parent <td> centres the cell correctly.
    // flex (block) would ignore text-center and stay left-aligned.
    const inner = (
        <div
            className={cn(
                "inline-flex items-center justify-center rounded border w-8 h-7",
                "text-[11px] font-mono cursor-default select-none transition-colors",
                cfg.bg,
                cfg.text,
                cfg.border,
                cfg.pulse && "animate-pulse",
                cell.runId && "cursor-pointer",
            )}
            title={cell.isoLabel}
        >
            {cfg.glyph}
        </div>
    );

    if (!cell.runId) return inner;

    return (
        <Link
            to="/$namespace/tasks/$taskId"
            params={{ namespace, taskId: cell.runId }}
            search={{ queue }}
        >
            {inner}
        </Link>
    );
}

// ── Main component ────────────────────────────────────────────────────────────

export function PartitionGrid({
    runs,
    upcoming,
    namespace,
    queue,
}: PartitionGridProps) {
    const { uniqueSlots, uniqueDates, grid, columnTotals } = useMemo(() => {
        // ── Bug fix 1: canonical slots come from `upcoming`, not from run timestamps.
        //
        // Deriving columns from run.createdAt includes one-off manual triggers
        // (e.g. "11:34") that are not part of the cron pattern.  `upcoming` always
        // reflects exactly what the scheduler will fire next, so its time-of-day
        // values are the authoritative column set.
        //
        // Fallback A: schedule ended (no upcoming) → use slots that appear ≥2 times
        //             in recent runs (filters one-off manual triggers).
        // Fallback B: brand-new schedule with <2 runs → use all run slots.
        const canonicalSlots = new Set<string>();
        for (const up of upcoming) {
            const { slot } = splitUTC(up.slot);
            canonicalSlots.add(slot);
        }
        if (canonicalSlots.size === 0) {
            const slotCounts = new Map<string, number>();
            for (const run of runs) {
                const { slot } = splitUTC(run.createdAt);
                slotCounts.set(slot, (slotCounts.get(slot) ?? 0) + 1);
            }
            for (const [slot, count] of slotCounts) {
                if (count >= 2) canonicalSlots.add(slot);
            }
            // Fallback B
            if (canonicalSlots.size === 0) {
                for (const run of runs) {
                    const { slot } = splitUTC(run.createdAt);
                    canonicalSlots.add(slot);
                }
            }
        }
        const uniqueSlots = Array.from(canonicalSlots).sort();

        // ── Bug fix 2: today must be UTC, not local time.
        //
        // `format(new Date(), "yyyy-MM-dd")` uses the *local* timezone.  Slot
        // timestamps are UTC, so comparing them against a local-timezone date
        // can be off by up to ±12 hours.  Use the ISO string slice instead.
        const nowUTC = new Date().toISOString().slice(0, 10); // "YYYY-MM-DD" UTC

        // Collect dates from runs + upcoming.
        // Upcoming dates are capped at today: a partition health grid shows
        // completeness of past slots — dates beyond today have no health to
        // measure and would appear as an all-"upcoming" row at the top.
        const dateSet = new Set<string>();
        for (const run of runs) {
            const { date } = splitUTC(run.partitionTime ?? run.createdAt);
            dateSet.add(date);
        }
        for (const up of upcoming) {
            const { date } = splitUTC(up.slot);
            if (date <= nowUTC) dateSet.add(date); // today's future slots only
        }
        // Always include last 7 calendar days (UTC) for a full-week baseline
        for (let i = 0; i < 7; i++) {
            const d = new Date();
            d.setUTCDate(d.getUTCDate() - i);
            dateSet.add(d.toISOString().slice(0, 10));
        }
        const uniqueDates = Array.from(dateSet).sort((a, b) =>
            b.localeCompare(a),
        );

        // Index runs by "YYYY-MM-DD|HH:MM".
        //
        // Use partitionTime when available — backfill tasks are created at
        // wall-clock time (e.g. Jun 8 15:00) but belong to a past slot
        // (e.g. Jun 8 00:00).  Using createdAt would lose them entirely.
        // Fall back to createdAt for regular scheduled runs (partitionTime ≈ createdAt).
        const runIndex = new Map<string, ScheduleRun>();
        for (const run of runs) {
            const iso = run.partitionTime ?? run.createdAt;
            const { date, slot } = splitUTC(iso);
            if (!canonicalSlots.has(slot)) continue; // skip non-canonical (manual) runs
            const key = `${date}|${slot}`;
            if (!runIndex.has(key)) runIndex.set(key, run);
        }

        // Index upcoming by "YYYY-MM-DD|HH:MM"
        const upcomingSet = new Set<string>();
        for (const up of upcoming) {
            const { date, slot } = splitUTC(up.slot);
            upcomingSet.add(`${date}|${slot}`);
        }

        const nowISO = nowUTC; // renamed for clarity below

        // Build the full grid: rows = dates, cols = slots
        const grid: CellData[][] = uniqueDates.map((date) =>
            uniqueSlots.map((slot) => {
                const key = `${date}|${slot}`;
                const run = runIndex.get(key);
                const isUpcoming = upcomingSet.has(key);

                let state: CellState;
                let runId: string | null = null;
                let durationSec: number | null = null;

                if (run) {
                    runId = run.id;
                    state = run.state as CellState;
                    if (run.completedAt && run.createdAt) {
                        durationSec =
                            (parseISO(run.completedAt).getTime() -
                                parseISO(run.createdAt).getTime()) /
                            1000;
                    }
                } else if (isUpcoming) {
                    // The scheduler has this slot queued in the future.
                    state = "UPCOMING";
                } else if (date < nowISO || isSlotInPast(date, slot)) {
                    // Past date, OR today but the slot time has already elapsed
                    // (e.g. 00:00 when it is now 14:00 UTC) — should have run.
                    state = "MISSING";
                } else {
                    // Future slot not yet known to the scheduler (beyond the
                    // upcoming window). Treat as upcoming for display purposes.
                    state = "UPCOMING";
                }

                const durationStr =
                    durationSec !== null
                        ? durationSec >= 60
                            ? `${Math.round(durationSec / 60)}m ${Math.round(durationSec % 60)}s`
                            : `${durationSec.toFixed(1)}s`
                        : null;

                const stateStr = run ? run.state : state;
                const isoLabel =
                    `${date}T${slot} UTC` +
                    (durationStr
                        ? `\n${stateStr} in ${durationStr}`
                        : `\n${stateStr}`);

                return { state, runId, durationSec, isoLabel };
            }),
        );

        // Column totals: count of COMPLETED per slot
        const columnTotals = uniqueSlots.map((_, colIdx) => {
            const completed = grid.filter(
                (row) => row[colIdx].state === "COMPLETED",
            ).length;
            const total = grid.filter(
                (row) => row[colIdx].state !== "MISSING",
            ).length;
            return { completed, total };
        });

        return { uniqueSlots, uniqueDates, grid, columnTotals };
    }, [runs, upcoming]);

    // Default: show 14 rows (two weeks). User can expand.
    const DEFAULT_ROWS = 14;
    const [showAll, setShowAll] = useState(false);
    const visibleDates = showAll
        ? uniqueDates
        : uniqueDates.slice(0, DEFAULT_ROWS);
    const hiddenCount = uniqueDates.length - DEFAULT_ROWS;

    if (uniqueDates.length === 0) return null;

    return (
        <section className="rounded-lg border border-border bg-card/40 overflow-hidden">
            {/* Header */}
            <div className="px-4 py-3 border-b border-border/50 flex items-center justify-between">
                <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                    Partition Health
                </h2>
                <span className="text-[10px] text-muted-foreground/60">
                    {uniqueSlots.length} slot
                    {uniqueSlots.length !== 1 ? "s" : ""} &middot; last{" "}
                    {uniqueDates.length} days
                </span>
            </div>

            {/* Full-width table — slot columns fill the remaining space equally.
                 Separate overflow wrapper from padding wrapper so horizontal
                 padding is never swallowed when overflow-x: auto is set. */}
            <div className="overflow-x-auto">
                <div className="px-4 pb-4 pt-3">
                    <table className="w-full table-fixed border-separate border-spacing-x-1 border-spacing-y-1">
                        <thead>
                            <tr>
                                {/* Fixed date column */}
                                <th className="w-22 shrink-0" />
                                {/* Slot columns — auto-fill; cells are centred within */}
                                {uniqueSlots.map((slot) => (
                                    <th
                                        key={slot}
                                        className="text-[10px] font-mono text-muted-foreground text-center pb-1"
                                    >
                                        {slot}
                                    </th>
                                ))}
                                {/* Fixed health-bar column */}
                                <th className="w-22 shrink-0" />
                                {/* Right spacer — guarantees trailing space after the health bar
                                     even when the table overflows its container. */}
                                <th className="w-6 shrink-0" />
                            </tr>
                        </thead>

                        <tbody>
                            {visibleDates.map((date, rowIdx) => {
                                const row = grid[rowIdx];
                                const completedCount = row.filter(
                                    (c) => c.state === "COMPLETED",
                                ).length;
                                const hasUpcomingCell = row.some(
                                    (c) => c.state === "UPCOMING",
                                );
                                const hasMissingCell = row.some(
                                    (c) => c.state === "MISSING",
                                );
                                const hasNonFutureCell = row.some(
                                    (c) =>
                                        c.state !== "UPCOMING" &&
                                        c.state !== "MISSING",
                                );
                                // Pure-future: UPCOMING only, no past/missing slots
                                const isAllFuture =
                                    hasUpcomingCell &&
                                    !hasNonFutureCell &&
                                    !hasMissingCell;
                                // Denominator = total canonical slots for this schedule
                                // pattern (uniqueSlots.length), not just the past ones.
                                // Using only non-UPCOMING cells gives a misleading "3/3"
                                // for today when the 4th slot is simply in the future.
                                // "3/4" is honest: 75% of today's slots have fired.
                                const expectedCount = isAllFuture
                                    ? 0
                                    : uniqueSlots.length;
                                const healthPct =
                                    expectedCount > 0
                                        ? completedCount / expectedCount
                                        : 0;

                                return (
                                    <tr key={date}>
                                        {/* Date label — fixed width, right-padded */}
                                        <td className="pr-3 text-[11px] font-mono text-muted-foreground whitespace-nowrap align-middle">
                                            {dateLabel(date)}
                                        </td>

                                        {/* Slot cells — centred within their auto-width column */}
                                        {row.map((cell, colIdx) => (
                                            <td
                                                key={colIdx}
                                                className="text-center align-middle py-0.5"
                                            >
                                                <GridCell
                                                    cell={cell}
                                                    namespace={namespace}
                                                    queue={queue}
                                                />
                                            </td>
                                        ))}

                                        {/* Health bar — padded on both sides */}
                                        <td className="pl-4 align-middle">
                                            {isAllFuture ? (
                                                <span className="text-[10px] text-muted-foreground/40 whitespace-nowrap">
                                                    upcoming
                                                </span>
                                            ) : (
                                                <div className="flex items-center gap-2">
                                                    <div className="w-20 h-1.5 rounded-full bg-border/30 relative overflow-hidden shrink-0">
                                                        <div
                                                            className="absolute inset-y-0 left-0 rounded-full bg-green-500/60 transition-all"
                                                            style={{
                                                                width: `${healthPct * 100}%`,
                                                            }}
                                                        />
                                                    </div>
                                                    <span className="text-[10px] text-muted-foreground whitespace-nowrap tabular-nums">
                                                        {completedCount}/
                                                        {expectedCount}
                                                    </span>
                                                </div>
                                            )}
                                        </td>
                                        {/* Right spacer cell */}
                                        <td />
                                    </tr>
                                );
                            })}
                        </tbody>

                        {/* Summary footer — only for the visible rows */}
                        {uniqueSlots.length > 0 && (
                            <tfoot>
                                <tr>
                                    <td className="pt-3 text-[10px] text-muted-foreground pr-3 whitespace-nowrap">
                                        Total
                                    </td>
                                    {columnTotals.map(
                                        ({ completed, total }, colIdx) => (
                                            <td
                                                key={colIdx}
                                                className="pt-3 text-center"
                                            >
                                                <div className="flex flex-col items-center gap-0.5">
                                                    <span className="text-[10px] font-mono text-muted-foreground tabular-nums">
                                                        {completed}
                                                    </span>
                                                    <span className="text-[9px] text-muted-foreground/50 tabular-nums">
                                                        {total > 0
                                                            ? `${Math.round((completed / total) * 100)}%`
                                                            : "—"}
                                                    </span>
                                                </div>
                                            </td>
                                        ),
                                    )}
                                    <td />
                                    <td />
                                </tr>
                            </tfoot>
                        )}
                    </table>
                </div>
            </div>

            {/* Show more / less toggle */}
            {hiddenCount > 0 && (
                <div className="border-t border-border/40 px-4 py-2.5">
                    <button
                        type="button"
                        onClick={() => setShowAll((v) => !v)}
                        className="text-[11px] text-muted-foreground hover:text-foreground transition-colors"
                    >
                        {showAll
                            ? `Show fewer (last ${DEFAULT_ROWS} days)`
                            : `Show ${hiddenCount} more day${hiddenCount !== 1 ? "s" : ""} →`}
                    </button>
                </div>
            )}
        </section>
    );
}
