import { useState, useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams } from "@tanstack/react-router";
import { api } from "@/api/client";
import { RelativeTime } from "@/components/RelativeTime";
import { StatusBadge } from "@/components/ui/badge";
import { Server } from "lucide-react";
import type { TaskState } from "@/api/types";

// ── Types ─────────────────────────────────────────────────────────────────────

interface WorkerTask {
    taskID: string;
    taskName: string;
    kind: string;
    queue: string;
    state: string;
    attempt: number;
    startedAt: string | null;
    finishedAt: string | null;
    durationMs: number | null;
    failureReason: string | null;
}

interface WorkerDetail {
    workerID: string;
    queue: string;
    concurrency: number;
    runningTasks: number;
    completedRecently: number;
    startedAt: string | null;
    lastSeenAt: string | null;
    leaseExpiresAt: string | null;
    isHealthy: boolean;
    recentTasks: WorkerTask[];
}

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmtDuration(ms: number): string {
    if (ms < 1_000) return `${ms.toFixed(0)}ms`;
    if (ms < 60_000) return `${(ms / 1_000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1_000);
    return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

function KindBadge({ kind }: { kind: string }) {
    const isWorkflow = kind === "WORKFLOW";
    return (
        <span
            className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium border ${
                isWorkflow
                    ? "bg-blue-500/15 text-blue-400 border-blue-500/20"
                    : "bg-amber-500/15 text-amber-400 border-amber-500/20"
            }`}
        >
            {isWorkflow ? "W" : "A"}
        </span>
    );
}

// ── Live elapsed timer ────────────────────────────────────────────────────────

function useElapsed(startIso: string | null): string {
    const [, tick] = useState(0);
    useEffect(() => {
        if (!startIso) return;
        const id = setInterval(() => tick((n) => n + 1), 1000);
        return () => clearInterval(id);
    }, [startIso]);
    if (!startIso) return "—";
    const ms = Date.now() - new Date(startIso).getTime();
    const s = Math.floor(ms / 1000);
    const m = Math.floor(s / 60);
    const h = Math.floor(m / 60);
    if (h > 0) return `${h}h ${m % 60}m`;
    if (m > 0) return `${m}m ${s % 60}s`;
    return `${s}s`;
}

// ── Shared table header ───────────────────────────────────────────────────────

function TaskTableHead() {
    return (
        <thead>
            <tr className="border-b border-border bg-secondary/20">
                {[
                    "Name",
                    "Kind",
                    "Queue",
                    "State",
                    "Attempt",
                    "Duration",
                    "Started",
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
    );
}

// ── Active task row (live elapsed timer) ─────────────────────────────────────

function ActiveTaskRow({ t, namespace }: { t: WorkerTask; namespace: string }) {
    const elapsed = useElapsed(t.startedAt);
    return (
        <tr className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors">
            <td className="px-4 py-2.5">
                <Link
                    to="/$namespace/tasks/$taskId"
                    params={{ namespace, taskId: t.taskID }}
                    search={{ queue: t.queue }}
                    className="font-medium text-foreground hover:text-brand transition-colors"
                >
                    {t.taskName}
                </Link>
            </td>
            <td className="px-4 py-2.5">
                <KindBadge kind={t.kind} />
            </td>
            <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">
                {t.queue}
            </td>
            <td className="px-4 py-2.5">
                <StatusBadge state={t.state as TaskState} />
            </td>
            <td className="px-4 py-2.5 text-muted-foreground">{t.attempt}</td>
            <td className="px-4 py-2.5 text-xs tabular-nums">
                <span className="flex items-center gap-1.5">
                    <span className="size-1.5 rounded-full bg-green-400 animate-pulse" />
                    <span className="text-green-400 font-medium">
                        {elapsed}
                    </span>
                </span>
            </td>
            <td className="px-4 py-2.5">
                <RelativeTime iso={t.startedAt} />
            </td>
        </tr>
    );
}

// ── Page ──────────────────────────────────────────────────────────────────────

export function WorkerDetailPage() {
    const { workerId, namespace } = useParams({ strict: false }) as {
        workerId: string;
        namespace: string;
    };

    // The workerId in the URL is encodeURIComponent'd — decode it back.
    const workerID = decodeURIComponent(workerId);
    usePageTitle(`Worker · ${workerID ?? "\u2026"}`);
    // Human-readable short name: "hostname:pid" → "hostname"
    const shortName = workerID.split(":")[0] ?? workerID;
    const pid = workerID.split(":")[1];

    const { data, isLoading, error } = useQuery({
        queryKey: ["worker-detail", namespace, workerID],
        queryFn: () =>
            api
                .get<WorkerDetail | null>(
                    `/api/${namespace}/workers/${encodeURIComponent(workerID)}`,
                )
                .then((r) => r.data),
        refetchInterval: 5_000,
    });

    const activeTasks =
        data?.recentTasks.filter((t) => t.state === "RUNNING") ?? [];
    const recentTasks =
        data?.recentTasks.filter((t) => t.state !== "RUNNING") ?? [];

    return (
        <div className="px-6 py-5 space-y-5">
            {/* ── Header ──────────────────────────────────────────────────────── */}
            <div>
                <div className="flex items-center gap-1.5 text-xs text-muted-foreground mb-2 font-mono">
                    <Link
                        to="/$namespace/workers"
                        params={{ namespace }}
                        className="hover:text-foreground transition-colors"
                    >
                        Workers
                    </Link>
                    <span>/</span>
                    <span className="text-foreground">{shortName}</span>
                </div>

                <div className="flex items-center gap-3">
                    <div className="w-8 h-8 rounded-lg bg-slate-800 border border-slate-700/60 flex items-center justify-center shrink-0">
                        <Server size={14} className="text-slate-400" />
                    </div>
                    <div>
                        <h1 className="text-base font-semibold text-foreground font-mono">
                            {shortName}
                            {pid && (
                                <span className="text-muted-foreground font-normal">
                                    :{pid}
                                </span>
                            )}
                        </h1>
                        <p className="text-[11px] font-mono text-muted-foreground/60 select-all mt-0.5">
                            {workerID}
                        </p>
                    </div>

                    {data && (
                        <span
                            className={`ml-2 inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${
                                data.isHealthy
                                    ? "bg-green-500/20 text-green-300 border-green-500/30"
                                    : "bg-slate-500/20 text-slate-300 border-slate-500/30"
                            }`}
                        >
                            {data.isHealthy ? "Active" : "Idle"}
                        </span>
                    )}
                </div>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && (
                <p className="text-sm text-red-400">Failed to load worker.</p>
            )}
            {/* null = worker existed but has no activity in the last 24 h */}
            {!isLoading && !error && data === null && (
                <div className="rounded-lg border border-border bg-card/40 px-4 py-8 text-center">
                    <p className="text-sm text-muted-foreground">
                        This worker has no recent activity (last 24 h).
                    </p>
                    <p className="text-xs text-muted-foreground/60 mt-1">
                        It may have stopped or been replaced by a new process.
                    </p>
                </div>
            )}

            {data && (
                <>
                    {/* ── Stats strip ────────────────────────────────────────────── */}
                    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
                        {[
                            {
                                label: "Running",
                                value: data.runningTasks,
                                accent:
                                    data.runningTasks > 0
                                        ? "text-yellow-300"
                                        : "text-foreground",
                            },
                            {
                                label: "Queue",
                                value: (
                                    <span className="font-mono text-xs">
                                        {data.queue}
                                    </span>
                                ),
                                accent: "text-foreground",
                            },
                            {
                                label: "Concurrency",
                                value: data.concurrency,
                                accent: "text-foreground",
                            },
                            {
                                label: "Completed (5 min)",
                                value: data.completedRecently,
                                accent: "text-foreground",
                            },
                            {
                                label: "Last seen",
                                value: <RelativeTime iso={data.lastSeenAt} />,
                                accent: "text-foreground",
                            },
                            {
                                label: "Lease expires",
                                value: data.leaseExpiresAt ? (
                                    <RelativeTime iso={data.leaseExpiresAt} />
                                ) : (
                                    "—"
                                ),
                                accent: data.isHealthy
                                    ? "text-green-400"
                                    : "text-slate-400",
                            },
                        ].map(({ label, value, accent }) => (
                            <div
                                key={label}
                                className="rounded-lg border border-border bg-card/40 px-4 py-3"
                            >
                                <p className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-1">
                                    {label}
                                </p>
                                <p
                                    className={`text-sm font-semibold tabular-nums ${accent}`}
                                >
                                    {value}
                                </p>
                            </div>
                        ))}
                    </div>

                    {/* ── Active Tasks ────────────────────────────────────────────── */}
                    <section>
                        <div className="flex items-center gap-2 mb-2">
                            <h2 className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground">
                                Active Tasks
                            </h2>
                            {activeTasks.length > 0 && (
                                <span className="inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[10px] font-medium bg-green-500/15 text-green-300 border-green-500/25">
                                    <span className="size-1.5 rounded-full bg-green-400 animate-pulse" />
                                    {activeTasks.length} Running
                                </span>
                            )}
                        </div>

                        {activeTasks.length === 0 ? (
                            <p className="text-xs text-muted-foreground/60 py-1">
                                No active tasks
                            </p>
                        ) : (
                            <div className="rounded-lg border border-border overflow-hidden">
                                <table className="w-full text-sm">
                                    <TaskTableHead />
                                    <tbody>
                                        {activeTasks.map((t) => (
                                            <ActiveTaskRow
                                                key={t.taskID}
                                                t={t}
                                                namespace={namespace}
                                            />
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        )}
                    </section>

                    {/* ── Recent Tasks ────────────────────────────────────────────── */}
                    <section>
                        <h2 className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                            Recent Tasks ({recentTasks.length})
                        </h2>

                        {recentTasks.length === 0 ? (
                            <div className="rounded-lg border border-border bg-card/40 px-4 py-8 text-center">
                                <p className="text-sm text-muted-foreground">
                                    No completed tasks in the last 24 hours.
                                </p>
                            </div>
                        ) : (
                            <div className="rounded-lg border border-border overflow-hidden">
                                <table className="w-full text-sm">
                                    <TaskTableHead />
                                    <tbody>
                                        {recentTasks.map((t) => (
                                            <tr
                                                key={`${t.taskID}-${t.attempt}`}
                                                className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                            >
                                                <td className="px-4 py-2.5">
                                                    <Link
                                                        to="/$namespace/tasks/$taskId"
                                                        params={{
                                                            namespace,
                                                            taskId: t.taskID,
                                                        }}
                                                        search={{
                                                            queue: t.queue,
                                                        }}
                                                        className="font-medium text-foreground hover:text-brand transition-colors"
                                                    >
                                                        {t.taskName}
                                                    </Link>
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <KindBadge kind={t.kind} />
                                                </td>
                                                <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">
                                                    {t.queue}
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <StatusBadge
                                                        state={
                                                            t.state as TaskState
                                                        }
                                                    />
                                                </td>
                                                <td className="px-4 py-2.5 text-muted-foreground">
                                                    {t.attempt}
                                                </td>
                                                <td className="px-4 py-2.5 text-xs text-muted-foreground tabular-nums">
                                                    {t.durationMs != null
                                                        ? fmtDuration(
                                                              t.durationMs,
                                                          )
                                                        : "—"}
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <RelativeTime
                                                        iso={t.startedAt}
                                                    />
                                                </td>
                                            </tr>
                                        ))}
                                    </tbody>
                                </table>
                            </div>
                        )}
                    </section>
                </>
            )}
        </div>
    );
}
