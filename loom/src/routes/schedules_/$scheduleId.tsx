import { useState } from "react";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, Trash2, RotateCcw } from "lucide-react";
import {
    getSchedule,
    getScheduleRuns,
    pauseSchedule,
    resumeSchedule,
    deleteSchedule,
    getScheduleUpcoming,
    type ScheduleRun,
    type UpcomingSlot,
} from "@/api/schedules";
import type { TaskStatus } from "@/api/types";
import { qk } from "@/lib/queryKeys";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/badge";
import { RelativeTime } from "@/components/RelativeTime";
import {
    createBackfill,
    getBackfills,
    haltBackfill,
    resumeBackfill,
    type BackfillResponse,
} from "@/api/backfills";
import { runSchedulePartition } from "@/api/schedules";
import { Play } from "lucide-react";
import { PartitionGrid } from "@/components/PartitionGrid";

// ── ISO 8601 helpers ──────────────────────────────────────────────────────────

/** Placeholder / format hint for a given schedule pattern type.
 *  Schedule Pattern: hourly → YYYY-MM-DDTHH, daily → YYYY-MM-DD, etc. */
function isoPlaceholderFor(patternType: string): string {
    switch (patternType.toLocaleLowerCase()) {
        case "daily":
        case "weekly":
            return "2026-04-29";
        case "monthly":
            return "2026-05";
        case "yearly":
            return "2025";
        default:
            return "2026-05-12T15"; // interval / cron
    }
}

/** Expands a partial ISO 8601 string to a full UTC ISO string that Date can parse.
 *  "2025"          → "2025-01-01T00:00:00Z"
 *  "2026-05"       → "2026-05-01T00:00:00Z"
 *  "2026-04-29"    → "2026-04-29T00:00:00Z"
 *  "2026-05-12T15" → "2026-05-12T15:00:00Z"
 */
function expandPartialISO(v: string): string {
    const s = v.trim();
    if (/^\d{4}$/.test(s)) return `${s}-01-01T00:00:00Z`;
    if (/^\d{4}-\d{2}$/.test(s)) return `${s}-01T00:00:00Z`;
    if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return `${s}T00:00:00Z`;
    if (/^\d{4}-\d{2}-\d{2}T\d{2}$/.test(s)) return `${s}:00:00Z`;
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}$/.test(s)) return `${s}:00Z`;
    return s.includes("Z") || s.includes("+") ? s : `${s}Z`;
}

function parsePartialISO(v: string): Date | null {
    if (!v.trim()) return null;
    const d = new Date(expandPartialISO(v));
    return isNaN(d.getTime()) ? null : d;
}

const TYPE_LABEL: Record<string, string> = {
    cron: "Cron",
    interval: "Interval",
    daily: "Daily",
    weekly: "Weekly",
    monthly: "Monthly",
    once: "Once",
};

function DetailRow({
    label,
    children,
}: {
    label: string;
    children: React.ReactNode;
}) {
    return (
        <div className="flex items-start gap-4 py-2.5 border-b border-border/40 last:border-0">
            <span className="w-36 shrink-0 text-xs text-muted-foreground font-medium">
                {label}
            </span>
            <span className="text-sm text-foreground">{children}</span>
        </div>
    );
}

/** Formats a Date as `YYYY-MM-DDTHH:MM UTC` — no seconds, always UTC. */
function fmtUTC(iso: string): string {
    const d = new Date(iso);
    const pad = (n: number) => String(n).padStart(2, "0");
    return (
        `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
        `T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`
    );
}

function OptionalTime({
    iso,
    warnIfPast = false,
}: {
    iso: string | null;
    /** When true, renders an amber "overdue" badge if the timestamp is in the past.
     *  Use on "Next run" so a missed slot is immediately visible. */
    warnIfPast?: boolean;
}) {
    if (!iso) return <span className="text-muted-foreground">—</span>;
    const isPast = warnIfPast && new Date(iso).getTime() < Date.now();
    return (
        <span className="flex items-center gap-2 flex-wrap">
            <span
                className={`font-mono text-xs ${
                    isPast ? "text-amber-400" : "text-foreground"
                }`}
            >
                {fmtUTC(iso)}
            </span>
            {isPast ? (
                <span className="text-[10px] px-1.5 py-0.5 rounded border bg-amber-500/10 text-amber-400 border-amber-500/25">
                    overdue · <RelativeTime iso={iso} />
                </span>
            ) : (
                <RelativeTime iso={iso} />
            )}
        </span>
    );
}

// ── BackfillDialog ────────────────────────────────────────────────────────────

function BackfillDialog({
    open,
    onClose,
    namespace,
    scheduleId,
    patternType,
    onCreated,
}: {
    open: boolean;
    onClose: () => void;
    namespace: string;
    scheduleId: string;
    patternType: string;
    onCreated: () => void;
}) {
    const [rangeStart, setRangeStart] = useState("");
    const [rangeEnd, setRangeEnd] = useState("");
    const [concurrency, setConcurrency] = useState(1);
    const [allowOverwrite, setAllowOverwrite] = useState(false);
    const [description, setDescription] = useState("");
    const [error, setError] = useState<string | null>(null);
    const ph = isoPlaceholderFor(patternType);

    const mutation = useMutation({
        mutationFn: () => {
            const start = parsePartialISO(rangeStart);
            const end = parsePartialISO(rangeEnd);
            if (!start) {
                setError("Invalid start — use ISO 8601 e.g. " + ph);
                return Promise.reject();
            }
            if (!end) {
                setError("Invalid end — use ISO 8601 e.g. " + ph);
                return Promise.reject();
            }
            if (end <= start) {
                setError("End must be after start");
                return Promise.reject();
            }
            setError(null);
            return createBackfill(namespace, scheduleId, {
                rangeStart: start.toISOString(),
                rangeEnd: end.toISOString(),
                concurrency,
                allowOverwrite,
                description: description || undefined,
            });
        },
        onSuccess: () => {
            onClose();
            onCreated();
        },
        onError: (e: unknown) => {
            if (error) return; // already set inline
            setError(
                e instanceof Error ? e.message : "Failed to create backfill",
            );
        },
    });

    if (!open) return null;
    return (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
            <div className="bg-card border border-border rounded-lg p-6 w-full max-w-md shadow-xl space-y-4">
                <div>
                    <h2 className="text-base font-semibold">Create Backfill</h2>
                    <p className="text-xs text-muted-foreground mt-1">
                        Retroactively execute this schedule for a historical
                        range. The scheduler drives slots — no worker
                        concurrency consumed for orchestration.
                    </p>
                </div>

                {/* Start */}
                <div className="space-y-1">
                    <label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        Start (inclusive)
                    </label>
                    <input
                        autoFocus
                        type="text"
                        placeholder={ph}
                        value={rangeStart}
                        onChange={(e) => setRangeStart(e.target.value)}
                        className="w-full rounded border border-border bg-secondary/20 px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/40"
                    />
                    <p className="text-[10px] text-muted-foreground">
                        ISO 8601 — e.g. {ph}
                    </p>
                </div>

                {/* End */}
                <div className="space-y-1">
                    <label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        End (exclusive)
                    </label>
                    <input
                        type="text"
                        placeholder={ph}
                        value={rangeEnd}
                        onChange={(e) => setRangeEnd(e.target.value)}
                        className="w-full rounded border border-border bg-secondary/20 px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/40"
                    />
                    <p className="text-[10px] text-muted-foreground">
                        ISO 8601 — e.g. {ph}
                    </p>
                </div>

                {/* Concurrency */}
                <div className="space-y-1">
                    <label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        Concurrency
                    </label>
                    <input
                        type="number"
                        min={1}
                        max={100}
                        value={concurrency}
                        onChange={(e) =>
                            setConcurrency(
                                Math.max(1, parseInt(e.target.value) || 1),
                            )
                        }
                        className="w-full rounded border border-border bg-secondary/20 px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-ring"
                    />
                    <p className="text-[10px] text-muted-foreground">
                        Max simultaneous slots. Does not affect normal scheduled
                        executions.
                    </p>
                </div>

                {/* Description */}
                <div className="space-y-1">
                    <label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        Description
                    </label>
                    <input
                        type="text"
                        placeholder="Why is this backfill being created?"
                        value={description}
                        onChange={(e) => setDescription(e.target.value)}
                        className="w-full rounded border border-border bg-secondary/20 px-3 py-1.5 text-sm focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/50"
                    />
                </div>

                <label className="flex items-center gap-2 cursor-pointer">
                    <input
                        type="checkbox"
                        checked={allowOverwrite}
                        onChange={(e) => setAllowOverwrite(e.target.checked)}
                        className="rounded"
                    />
                    <span className="text-xs text-muted-foreground">
                        Allow overwrite — re-run slots that already completed
                    </span>
                </label>

                {error && (
                    <p className="text-xs text-red-400 bg-red-500/10 rounded px-3 py-2">
                        {error}
                    </p>
                )}

                <div className="flex justify-end gap-2 pt-1">
                    <Button variant="outline" size="sm" onClick={onClose}>
                        Cancel
                    </Button>
                    <Button
                        size="sm"
                        onClick={() => mutation.mutate()}
                        disabled={
                            !rangeStart.trim() ||
                            !rangeEnd.trim() ||
                            mutation.isPending
                        }
                    >
                        {mutation.isPending ? "Creating…" : "Create backfill"}
                    </Button>
                </div>
            </div>
        </div>
    );
}

// ── RunDialog — fire a single partition slot ──────────────────────────────────

function RunDialog({
    open,
    onClose,
    namespace,
    scheduleId,
    patternType,
    onSuccess,
}: {
    open: boolean;
    onClose: () => void;
    namespace: string;
    scheduleId: string;
    patternType: string;
    onSuccess: (taskId: string) => void;
}) {
    const [partitionTime, setPartitionTime] = useState("");
    const [allowOverwrite, setAllowOverwrite] = useState(false);
    const [error, setError] = useState<string | null>(null);
    const ph = isoPlaceholderFor(patternType);

    const mutation = useMutation({
        mutationFn: () => {
            const pt = parsePartialISO(partitionTime);
            if (!pt) {
                setError("Invalid partition time — use ISO 8601 e.g. " + ph);
                return Promise.reject();
            }
            setError(null);
            return runSchedulePartition(namespace, scheduleId, {
                partitionTime: pt.toISOString(),
                allowOverwrite,
            });
        },
        onSuccess: (data) => {
            onClose();
            onSuccess(data.taskId);
        },
        onError: (e: unknown) => {
            if (error) return;
            setError(e instanceof Error ? e.message : "Failed to trigger run");
        },
    });

    if (!open) return null;
    return (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40">
            <div className="bg-card border border-border rounded-lg p-6 w-full max-w-md shadow-xl space-y-4">
                <div>
                    <h2 className="text-base font-semibold">
                        Run for partition
                    </h2>
                    <p className="text-xs text-muted-foreground mt-1">
                        Fire a single execution for a specific historical
                        partition. Uses the scheduler’s idempotency key —
                        re-running an already-completed slot is blocked unless
                        overwrite is enabled.
                    </p>
                </div>

                <div className="space-y-1">
                    <label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        Partition time
                    </label>
                    <input
                        autoFocus
                        type="text"
                        placeholder={ph}
                        value={partitionTime}
                        onChange={(e) => setPartitionTime(e.target.value)}
                        onKeyDown={(e) => {
                            if (e.key === "Enter") mutation.mutate();
                        }}
                        className="w-full rounded border border-border bg-secondary/20 px-3 py-1.5 text-sm font-mono focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/40"
                    />
                    <p className="text-[10px] text-muted-foreground">
                        ISO 8601 — e.g. {ph}
                    </p>
                </div>

                <label className="flex items-center gap-2 cursor-pointer">
                    <input
                        type="checkbox"
                        checked={allowOverwrite}
                        onChange={(e) => setAllowOverwrite(e.target.checked)}
                        className="rounded"
                    />
                    <span className="text-xs text-muted-foreground">
                        Allow overwrite — re-run even if this partition already
                        completed
                    </span>
                </label>

                {error && (
                    <p className="text-xs text-red-400 bg-red-500/10 rounded px-3 py-2">
                        {error}
                    </p>
                )}

                <div className="flex justify-end gap-2 pt-1">
                    <Button variant="outline" size="sm" onClick={onClose}>
                        Cancel
                    </Button>
                    <Button
                        size="sm"
                        onClick={() => mutation.mutate()}
                        disabled={!partitionTime.trim() || mutation.isPending}
                    >
                        {mutation.isPending ? "Running…" : "Run"}
                    </Button>
                </div>
            </div>
        </div>
    );
}

function BackfillList({
    namespace,
    scheduleId,
}: {
    namespace: string;
    scheduleId: string;
}) {
    const qc = useQueryClient();
    const { data: backfills = [] } = useQuery({
        queryKey: ["backfills", namespace, scheduleId],
        queryFn: () => getBackfills(namespace, scheduleId),
        refetchInterval: 5_000,
    });

    const haltMut = useMutation({
        mutationFn: (id: string) => haltBackfill(namespace, id),
        onSuccess: () =>
            void qc.invalidateQueries({
                queryKey: ["backfills", namespace, scheduleId],
            }),
    });
    const resumeMut = useMutation({
        mutationFn: (id: string) => resumeBackfill(namespace, id),
        onSuccess: () =>
            void qc.invalidateQueries({
                queryKey: ["backfills", namespace, scheduleId],
            }),
    });

    if (backfills.length === 0)
        return (
            <p className="text-xs text-muted-foreground italic">
                No backfills yet.
            </p>
        );

    return (
        <div className="space-y-2">
            {backfills.map((b: BackfillResponse) => {
                const pct =
                    b.totalSlots > 0
                        ? Math.round((b.completedSlots / b.totalSlots) * 100)
                        : 0;
                const statusColor =
                    b.status === "COMPLETED"
                        ? "text-green-400"
                        : b.status === "FAILED"
                          ? "text-red-400"
                          : b.status === "HALTED"
                            ? "text-amber-400"
                            : "text-blue-400";
                return (
                    <div
                        key={b.id}
                        className="rounded-lg border border-border/40 bg-secondary/10 px-4 py-3 space-y-2"
                    >
                        <div className="flex items-start justify-between gap-2">
                            <div className="space-y-0.5 min-w-0">
                                <p className="text-xs font-mono text-muted-foreground truncate">
                                    {b.id}
                                </p>
                                {b.description && (
                                    <p className="text-xs text-foreground/70">
                                        {b.description}
                                    </p>
                                )}
                                <p className="text-[10px] text-muted-foreground">
                                    {new Date(b.rangeStart)
                                        .toISOString()
                                        .slice(0, 16)}{" "}
                                    →{" "}
                                    {new Date(b.rangeEnd)
                                        .toISOString()
                                        .slice(0, 16)}
                                    {" · "}concurrency {b.concurrency}
                                    {b.allowOverwrite && " · overwrite"}
                                </p>
                                <p className="text-[10px] text-muted-foreground/60">
                                    Created <RelativeTime iso={b.createdAt} />
                                    {b.completedAt && (
                                        <>
                                            {" · "}
                                            {b.status === "FAILED"
                                                ? "Failed"
                                                : "Completed"}{" "}
                                            <RelativeTime iso={b.completedAt} />
                                        </>
                                    )}
                                </p>
                            </div>
                            <span
                                className={`text-xs font-medium shrink-0 ${statusColor}`}
                            >
                                {b.status}
                            </span>
                        </div>

                        {/* Progress bar */}
                        {b.totalSlots > 0 && (
                            <div className="space-y-1">
                                <div className="h-1.5 rounded-full bg-secondary/40 overflow-hidden">
                                    <div
                                        className="h-full rounded-full bg-blue-500 transition-all"
                                        style={{ width: `${pct}%` }}
                                    />
                                </div>
                                <p className="text-[10px] text-muted-foreground">
                                    {b.completedSlots} / {b.totalSlots} slots (
                                    {pct}%)
                                </p>
                            </div>
                        )}

                        {/* Actions */}
                        <div className="flex items-center gap-1.5 justify-between">
                            <div className="flex gap-1.5">
                                {b.status === "RUNNING" && (
                                    <Button
                                        variant="outline"
                                        size="sm"
                                        onClick={() => haltMut.mutate(b.id)}
                                        disabled={haltMut.isPending}
                                        className="h-6 text-[10px] px-2"
                                    >
                                        Halt
                                    </Button>
                                )}
                                {b.status === "HALTED" && (
                                    <Button
                                        variant="outline"
                                        size="sm"
                                        onClick={() => resumeMut.mutate(b.id)}
                                        disabled={resumeMut.isPending}
                                        className="h-6 text-[10px] px-2"
                                    >
                                        Resume
                                    </Button>
                                )}
                            </div>

                            {b.completedSlots > 0 && (
                                <Link
                                    to="/$namespace/runs"
                                    params={{ namespace }}
                                    search={{
                                        backfillId: b.id,
                                        queue: b.queue,
                                        name: b.taskName,
                                    }}
                                    className="text-[11px] text-muted-foreground hover:text-foreground transition-colors"
                                >
                                    View {b.completedSlots} task
                                    {b.completedSlots !== 1 ? "s" : ""} →
                                </Link>
                            )}
                        </div>
                    </div>
                );
            })}
        </div>
    );
}

export function ScheduleDetailPage() {
    const { scheduleId, namespace } = useParams({ strict: false }) as {
        scheduleId: string;
        namespace: string;
    };
    const navigate = useNavigate();
    const qc = useQueryClient();
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    const {
        data: schedule,
        isLoading,
        error,
    } = useQuery({
        queryKey: qk.schedules.detail(namespace, scheduleId),
        queryFn: () => getSchedule(namespace, scheduleId),
        refetchInterval: intervalMs,
    });
    usePageTitle(schedule?.name ?? "Schedule");

    const { data: runs = [] } = useQuery({
        queryKey: qk.schedules.runs(namespace, scheduleId),
        queryFn: () => getScheduleRuns(namespace, scheduleId),
        refetchInterval: intervalMs,
    });

    const { data: upcoming = [] } = useQuery({
        queryKey: [...qk.schedules.detail(namespace, scheduleId), "upcoming"],
        queryFn: () => getScheduleUpcoming(namespace, scheduleId, 5),
        enabled: !!schedule?.isActive,
        refetchInterval: intervalMs,
    });

    const pauseMut = useMutation({
        mutationFn: () => pauseSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void qc.invalidateQueries({
                queryKey: qk.schedules.detail(namespace, scheduleId),
            });
        },
    });

    const resumeMut = useMutation({
        mutationFn: () => resumeSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void qc.invalidateQueries({
                queryKey: qk.schedules.detail(namespace, scheduleId),
            });
        },
    });

    const deleteMut = useMutation({
        mutationFn: () => deleteSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void navigate({
                to: "/$namespace/schedules",
                params: { namespace },
            });
        },
    });

    const [backfillOpen, setBackfillOpen] = useState(false);
    const [runOpen, setRunOpen] = useState(false);

    return (
        <div className="px-6 py-5">
            {/* Back link */}
            <div className="flex items-center gap-2 mb-5">
                <Link
                    to="/$namespace/schedules"
                    params={{ namespace }}
                    className="text-muted-foreground hover:text-foreground transition-colors"
                >
                    <ArrowLeft size={16} />
                </Link>
                <span className="text-muted-foreground text-sm">/</span>
                <span className="text-sm text-muted-foreground">Schedules</span>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {schedule && (
                <div className="space-y-5">
                    {/* Header */}
                    <div className="flex items-start justify-between gap-4">
                        <div className="space-y-1">
                            <div className="flex items-center gap-3">
                                <h1 className="text-lg font-semibold text-foreground">
                                    {schedule.name}
                                </h1>
                                <span
                                    className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${
                                        schedule.isActive
                                            ? "bg-green-500/20 text-green-300 border-green-500/30"
                                            : "bg-slate-500/20 text-slate-300 border-slate-500/30"
                                    }`}
                                >
                                    {schedule.isActive ? "Active" : "Paused"}
                                </span>
                            </div>
                            <p className="text-xs text-muted-foreground font-mono">
                                {scheduleId}
                            </p>
                        </div>

                        {/* Actions */}
                        <div className="flex items-center gap-2 shrink-0">
                            <AutoRefreshControl
                                intervalMs={intervalMs}
                                setIntervalMs={setIntervalMs}
                            />
                            {schedule.isActive ? (
                                <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => pauseMut.mutate()}
                                    disabled={pauseMut.isPending}
                                >
                                    Pause
                                </Button>
                            ) : (
                                <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => resumeMut.mutate()}
                                    disabled={resumeMut.isPending}
                                >
                                    Resume
                                </Button>
                            )}
                            <Button
                                size="sm"
                                variant="outline"
                                onClick={() => setRunOpen(true)}
                            >
                                <Play size={13} /> Run
                            </Button>
                            <Button
                                size="sm"
                                variant="outline"
                                onClick={() => setBackfillOpen(true)}
                            >
                                <RotateCcw size={13} /> Backfill
                            </Button>
                            <Button
                                variant="destructive"
                                size="sm"
                                onClick={() => {
                                    if (
                                        window.confirm(
                                            `Delete schedule "${schedule.name}"? This cannot be undone.`,
                                        )
                                    ) {
                                        deleteMut.mutate();
                                    }
                                }}
                                disabled={deleteMut.isPending}
                            >
                                <Trash2 size={13} />
                                Delete
                            </Button>
                        </div>
                    </div>

                    {/* Details card */}
                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                            Details
                        </h2>
                        <DetailRow label="Queue">
                            <span className="font-mono text-xs">
                                {schedule.queue}
                            </span>
                        </DetailRow>
                        <DetailRow label="Task name">
                            <span className="font-mono text-xs">
                                {schedule.taskName}
                            </span>
                        </DetailRow>
                        <DetailRow label="Pattern type">
                            <span className="inline-flex items-center rounded border px-2 py-0.5 text-xs bg-secondary/40 text-muted-foreground border-border/60">
                                {TYPE_LABEL[schedule.patternType] ??
                                    schedule.patternType}
                            </span>
                        </DetailRow>
                        <DetailRow label="Pattern">
                            <span className="font-mono text-xs">
                                {schedule.patternDescription}
                            </span>
                        </DetailRow>
                        <DetailRow label="Run count">
                            <span>{schedule.runCount.toLocaleString()}</span>
                        </DetailRow>
                    </section>

                    {/* Timing card */}
                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                            Timing
                        </h2>
                        <DetailRow label="Next run">
                            <OptionalTime iso={schedule.nextRunAt} warnIfPast />
                        </DetailRow>
                        <DetailRow label="Last run">
                            <OptionalTime iso={schedule.lastRunAt} />
                        </DetailRow>
                        <DetailRow label="Created">
                            <OptionalTime iso={schedule.createdAt} />
                        </DetailRow>
                        <DetailRow label="Starts at">
                            <OptionalTime iso={schedule.startsAt} />
                        </DetailRow>
                        <DetailRow label="Ends at">
                            <OptionalTime iso={schedule.endsAt} />
                        </DetailRow>
                    </section>

                    {/* Upcoming fire times */}
                    {upcoming.length > 0 && (
                        <section className="rounded-lg border border-border bg-card/40 p-4">
                            <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                                Upcoming fire times
                            </h2>
                            <ol className="space-y-1.5">
                                {upcoming.map((s: UpcomingSlot, i: number) => (
                                    <li
                                        key={s.slot}
                                        className="flex items-center gap-3 text-xs"
                                    >
                                        <span className="w-4 text-right text-muted-foreground/50 tabular-nums shrink-0">
                                            {i + 1}
                                        </span>
                                        <span className="font-mono text-foreground">
                                            {fmtUTC(s.slot)}
                                        </span>
                                        <span className="text-muted-foreground ml-auto shrink-0">
                                            <RelativeTime iso={s.slot} />
                                        </span>
                                    </li>
                                ))}
                            </ol>
                        </section>
                    )}

                    {/* Backfills */}
                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <h2 className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                            Backfills
                        </h2>
                        <BackfillList
                            namespace={namespace}
                            scheduleId={scheduleId}
                        />
                    </section>

                    {/* Partition Health Grid */}
                    {runs.length > 0 && schedule && (
                        <PartitionGrid
                            runs={runs}
                            upcoming={upcoming ?? []}
                            namespace={namespace}
                            scheduleId={scheduleId}
                            queue={schedule.queue}
                        />
                    )}

                    {/* Recent Runs */}
                    <section className="rounded-lg border border-border bg-card/40 overflow-hidden">
                        <div className="px-4 py-3 border-b border-border/50">
                            <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                                Recent Runs
                            </h2>
                        </div>
                        {runs.length === 0 ? (
                            <div className="px-4 py-8 text-center text-sm text-muted-foreground">
                                No runs yet.
                            </div>
                        ) : (
                            <table className="w-full text-sm">
                                <thead>
                                    <tr className="border-b border-border bg-secondary/20">
                                        {[
                                            "",
                                            "State",
                                            "Attempt",
                                            "Fired",
                                            "Completed",
                                        ].map((h) => (
                                            <th
                                                key={h}
                                                className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide"
                                            >
                                                {h}
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody>
                                    {runs.map((run: ScheduleRun) => (
                                        <tr
                                            key={run.id}
                                            className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                        >
                                            <td className="px-4 py-3 w-8">
                                                <Link
                                                    to="/$namespace/tasks/$taskId"
                                                    params={{
                                                        namespace,
                                                        taskId: run.id,
                                                    }}
                                                    search={
                                                        {
                                                            queue:
                                                                schedule?.queue ??
                                                                "",
                                                        } as never
                                                    }
                                                    className="text-muted-foreground hover:text-foreground transition-colors"
                                                    title={run.id}
                                                >
                                                    ↗
                                                </Link>
                                            </td>
                                            <td className="px-4 py-3">
                                                <StatusBadge
                                                    state={
                                                        run.state as TaskStatus
                                                    }
                                                />
                                            </td>
                                            <td className="px-4 py-3 text-muted-foreground">
                                                {run.attempt}
                                            </td>
                                            <td className="px-4 py-3">
                                                <RelativeTime
                                                    iso={run.createdAt}
                                                />
                                            </td>
                                            <td className="px-4 py-3">
                                                <RelativeTime
                                                    iso={run.completedAt}
                                                />
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        )}
                    </section>
                </div>
            )}

            <RunDialog
                open={runOpen}
                onClose={() => setRunOpen(false)}
                namespace={namespace}
                scheduleId={scheduleId}
                patternType={schedule?.patternType ?? "cron"}
                onSuccess={(taskId) =>
                    void navigate({
                        to: "/$namespace/tasks/$taskId",
                        params: { namespace, taskId },
                    })
                }
            />
            <BackfillDialog
                open={backfillOpen}
                onClose={() => setBackfillOpen(false)}
                namespace={namespace}
                scheduleId={scheduleId}
                patternType={schedule?.patternType ?? "cron"}
                onCreated={() =>
                    void qc.invalidateQueries({
                        queryKey: ["backfills", namespace, scheduleId],
                    })
                }
            />
        </div>
    );
}
