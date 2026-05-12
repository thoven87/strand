import React, { useState, useEffect, useMemo, useCallback } from "react";
import { useQuery } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { useParams } from "@tanstack/react-router";
import {
    BarChart,
    Bar,
    XAxis,
    YAxis,
    Tooltip,
    ResponsiveContainer,
    CartesianGrid,
    PieChart,
    Pie,
    Cell,
} from "recharts";
import { RefreshCw, Activity, TrendingDown } from "lucide-react";
import { getMetrics } from "@/api/metrics";

import { getTaskDefinitionActivity, getTaskKinds } from "@/api/workflows";
import type { DailyActivity, TaskKindEntry } from "@/api/workflows";
import { getWorkers } from "@/api/workers";
import type { Worker } from "@/api/workers";
import { qk } from "@/lib/queryKeys";
import { fmtDuration } from "@/lib/utils";

// ── Formatters ────────────────────────────────────────────────────────────

function fmtHour(iso: string): string {
    try {
        const d = new Date(iso);
        return d.toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
            hour12: false,
        });
    } catch {
        return iso;
    }
}

function fmtDate(iso: string): string {
    try {
        return new Date(iso).toLocaleDateString([], {
            month: "short",
            day: "numeric",
        });
    } catch {
        return iso;
    }
}

function fmtRate(ratePerSec: number | null | undefined): string {
    if (ratePerSec == null || !isFinite(ratePerSec) || ratePerSec < 0)
        return "—";
    const perMin = ratePerSec * 60;
    if (perMin < 1) return "< 1/min";
    if (ratePerSec < 1) return `${perMin.toFixed(perMin < 10 ? 1 : 0)}/min`;
    return `${ratePerSec >= 10 ? ratePerSec.toFixed(0) : ratePerSec.toFixed(1)}/s`;
}

function fmtPct(ratio: number): string {
    if (!isFinite(ratio)) return "—";
    return `${(ratio * 100).toFixed(1)}%`;
}

function fmtSecondsAgo(secs: number): string {
    if (secs < 5) return "just now";
    if (secs < 60) return `${secs}s ago`;
    return `${Math.floor(secs / 60)}m ago`;
}

// ── Derived data types ────────────────────────────────────────────────────

interface TaskSummary {
    name: string;
    queue: string;
    completedCount: number;
    failedCount: number;
    ratePerSec: number | null;
    p50Ms: number | null;
    p95Ms: number | null;
    p99Ms: number | null;
    p50WaitMs: number | null;
    p95WaitMs: number | null;
}

// ── Status donut ──────────────────────────────────────────────────────────

const DONUT_COLORS: Record<string, string> = {
    Completed: "#4ade80",
    Failed: "#f87171",
    Cancelled: "#94a3b8",
    Running: "#60a5fa",
    Pending: "#facc15",
};

interface DonutSlice {
    name: string;
    value: number;
    color: string;
}

function StatusDonut({
    slices,
    total,
}: {
    slices: DonutSlice[];
    total: number;
}) {
    const [activeIndex, setActiveIndex] = useState<number | null>(null);

    return (
        <div className="flex items-center gap-6">
            {/* Ring */}
            <div
                className="relative shrink-0"
                style={{ width: 160, height: 160 }}
            >
                <ResponsiveContainer width="100%" height="100%">
                    <PieChart>
                        <Pie
                            data={slices}
                            cx="50%"
                            cy="50%"
                            innerRadius={52}
                            outerRadius={72}
                            paddingAngle={slices.length > 1 ? 2 : 0}
                            dataKey="value"
                            onMouseEnter={(_, index) => setActiveIndex(index)}
                            onMouseLeave={() => setActiveIndex(null)}
                            stroke="none"
                        >
                            {slices.map((entry, index) => (
                                <Cell
                                    key={entry.name}
                                    fill={entry.color}
                                    opacity={
                                        activeIndex === null ||
                                        activeIndex === index
                                            ? 1
                                            : 0.4
                                    }
                                />
                            ))}
                        </Pie>
                        <Tooltip
                            content={({ active, payload }) => {
                                if (!active || !payload?.length) return null;
                                const d = payload[0].payload as DonutSlice;
                                return (
                                    <div className="rounded border border-border bg-background px-2.5 py-1.5 text-xs shadow-lg">
                                        <span
                                            className="font-medium"
                                            style={{ color: d.color }}
                                        >
                                            {d.name}
                                        </span>
                                        <span className="ml-2 tabular-nums text-foreground">
                                            {d.value.toLocaleString()}
                                        </span>
                                    </div>
                                );
                            }}
                        />
                    </PieChart>
                </ResponsiveContainer>
                {/* Centre label */}
                <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none">
                    <span className="text-xl font-bold tabular-nums text-foreground leading-none">
                        {total.toLocaleString()}
                    </span>
                    <span className="text-[9px] text-muted-foreground uppercase tracking-wide mt-0.5">
                        total
                    </span>
                </div>
            </div>

            {/* Legend */}
            <div className="flex flex-col gap-2 min-w-0">
                {slices.map((s) => (
                    <div key={s.name} className="flex items-center gap-2">
                        <span
                            className="w-2.5 h-2.5 rounded-full shrink-0"
                            style={{ backgroundColor: s.color }}
                        />
                        <span className="text-xs text-muted-foreground truncate">
                            {s.name}
                        </span>
                        <span
                            className="ml-auto text-xs tabular-nums font-medium pl-2"
                            style={{ color: s.color }}
                        >
                            {s.value.toLocaleString()}
                        </span>
                    </div>
                ))}
            </div>
        </div>
    );
}

// ── Stat tile ─────────────────────────────────────────────────────────────

function StatTile({
    label,
    value,
    sub,
    colorClass = "text-foreground",
}: {
    label: string;
    value: string;
    sub?: string;
    colorClass?: string;
}) {
    return (
        <div className="rounded-lg border border-border/60 bg-card/30 px-4 py-3 flex flex-col gap-0.5">
            <span
                className={`text-2xl font-bold tabular-nums leading-tight ${colorClass}`}
            >
                {value}
            </span>
            <span className="text-[10px] text-muted-foreground uppercase tracking-wide font-medium">
                {label}
            </span>
            {sub && (
                <span className="text-[9px] text-muted-foreground/60">
                    {sub}
                </span>
            )}
        </div>
    );
}

// ── Combined throughput chart ─────────────────────────────────────────────

interface CombinedBucket {
    label: string;
    completed: number;
    failed: number;
}

function ThroughputChart({ data }: { data: CombinedBucket[] }) {
    const CustomTooltip = ({
        active,
        payload,
        label,
    }: {
        active?: boolean;
        payload?: { name: string; value: number; fill: string }[];
        label?: string;
    }) => {
        if (!active || !payload?.length) return null;
        return (
            <div className="rounded-md border border-border bg-background px-3 py-2 text-xs shadow-xl space-y-1">
                <p className="text-muted-foreground">{label}</p>
                {payload.map((p) => (
                    <p
                        key={p.name}
                        style={{ color: p.fill }}
                        className="font-medium"
                    >
                        {p.name.charAt(0).toUpperCase() + p.name.slice(1)}:{" "}
                        {p.value}
                    </p>
                ))}
            </div>
        );
    };

    if (data.length === 0) {
        return (
            <p className="text-xs text-muted-foreground text-center py-8">
                No data yet.
            </p>
        );
    }

    return (
        <ResponsiveContainer width="100%" height={200}>
            <BarChart
                data={data}
                margin={{ top: 4, right: 4, bottom: 0, left: -10 }}
            >
                <CartesianGrid
                    strokeDasharray="3 3"
                    stroke="rgba(255,255,255,0.04)"
                    vertical={false}
                />
                <XAxis
                    dataKey="label"
                    tick={{ fontSize: 10, fill: "#64748b" }}
                    axisLine={false}
                    tickLine={false}
                    interval="preserveStartEnd"
                />
                <YAxis
                    tick={{ fontSize: 10, fill: "#64748b" }}
                    axisLine={false}
                    tickLine={false}
                    allowDecimals={false}
                />
                <Tooltip
                    content={<CustomTooltip />}
                    cursor={{ fill: "rgba(255,255,255,0.04)" }}
                />
                <Bar
                    dataKey="completed"
                    stackId="a"
                    fill="#4ade80"
                    maxBarSize={28}
                    radius={[0, 0, 0, 0]}
                />
                <Bar
                    dataKey="failed"
                    stackId="a"
                    fill="#f87171"
                    maxBarSize={28}
                    radius={[3, 3, 0, 0]}
                />
            </BarChart>
        </ResponsiveContainer>
    );
}

// ── 7-day per-task chart (inline expansion) ───────────────────────────────

function TaskDailyChart({
    namespace,
    taskName,
}: {
    namespace: string;
    taskName: string;
}) {
    const { data = [] } = useQuery<DailyActivity[]>({
        queryKey: [...qk.tasks.activity(namespace, taskName)],
        queryFn: () => getTaskDefinitionActivity(namespace, taskName, 7),
        staleTime: 5 * 60_000,
    });

    if (data.length === 0) {
        return (
            <p className="text-xs text-muted-foreground italic">
                No 7-day history yet.
            </p>
        );
    }

    const chartData = data.map((d) => ({
        label: fmtDate(d.date),
        completed: d.total - d.failed,
        failed: d.failed,
    }));

    return (
        <ResponsiveContainer width="100%" height={100}>
            <BarChart
                data={chartData}
                margin={{ top: 4, right: 4, bottom: 0, left: -20 }}
            >
                <XAxis
                    dataKey="label"
                    tick={{ fontSize: 9, fill: "#64748b" }}
                    axisLine={false}
                    tickLine={false}
                />
                <YAxis
                    tick={{ fontSize: 9, fill: "#64748b" }}
                    axisLine={false}
                    tickLine={false}
                    allowDecimals={false}
                />
                <Tooltip
                    content={({ active, payload, label }) => {
                        if (!active || !payload?.length) return null;
                        return (
                            <div className="rounded border border-border bg-background px-2 py-1 text-[10px] shadow-lg">
                                <p className="text-muted-foreground mb-0.5">
                                    {label}
                                </p>
                                {payload.map((p, i) => (
                                    <p
                                        key={String(p.name ?? i)}
                                        style={{ color: p.fill as string }}
                                    >
                                        {String(p.name ?? "")}: {p.value}
                                    </p>
                                ))}
                            </div>
                        );
                    }}
                    cursor={{ fill: "rgba(255,255,255,0.04)" }}
                />
                <Bar
                    dataKey="completed"
                    stackId="a"
                    fill="#4ade80"
                    maxBarSize={20}
                />
                <Bar
                    dataKey="failed"
                    stackId="a"
                    fill="#f87171"
                    maxBarSize={20}
                    radius={[2, 2, 0, 0]}
                />
            </BarChart>
        </ResponsiveContainer>
    );
}

// ── Task inline expansion ─────────────────────────────────────────────────

function TaskExpansion({
    task,
    namespace,
}: {
    task: TaskSummary;
    namespace: string;
}) {
    const metrics = [
        {
            label: "p50 exec",
            value: task.p50Ms,
            color: "text-green-400 dark:text-green-400",
        },
        {
            label: "p95 exec",
            value: task.p95Ms,
            color: "text-yellow-600 dark:text-yellow-400",
        },
        {
            label: "p99 exec",
            value: task.p99Ms,
            color: "text-orange-600 dark:text-orange-400",
        },
        {
            label: "p50 wait",
            value: task.p50WaitMs,
            color: "text-sky-600 dark:text-sky-400",
        },
        {
            label: "p95 wait",
            value: task.p95WaitMs,
            color: "text-blue-600 dark:text-blue-400",
        },
    ];

    const total = task.completedCount + task.failedCount;
    const failRate = total > 0 ? task.failedCount / total : 0;

    return (
        <div className="border-t border-border/30 bg-secondary/5 px-4 py-4 space-y-4">
            <div className="flex items-start justify-between gap-4 flex-wrap">
                <div>
                    <p className="text-[10px] text-muted-foreground uppercase tracking-wider mb-1">
                        Live latency percentiles · ±2% error
                    </p>
                    <div className="flex flex-wrap gap-3">
                        {metrics.map(({ label, value, color }) => (
                            <div
                                key={label}
                                className="rounded border border-border/40 bg-card/40 px-3 py-2 min-w-[80px]"
                            >
                                <p
                                    className={`text-base font-bold tabular-nums ${color}`}
                                >
                                    {fmtDuration(value)}
                                </p>
                                <p className="text-[9px] text-muted-foreground uppercase tracking-wide mt-0.5">
                                    {label}
                                </p>
                            </div>
                        ))}
                        <div className="rounded border border-border/40 bg-card/40 px-3 py-2 min-w-[80px]">
                            <p
                                className={`text-base font-bold tabular-nums ${
                                    failRate > 0.1
                                        ? "text-red-600 dark:text-red-400"
                                        : failRate > 0
                                          ? "text-orange-600 dark:text-orange-400"
                                          : "text-muted-foreground"
                                }`}
                            >
                                {task.failedCount.toLocaleString()}
                            </p>
                            <p className="text-[9px] text-muted-foreground uppercase tracking-wide mt-0.5">
                                failures
                            </p>
                        </div>
                    </div>
                </div>

                {/* Rate */}
                {task.ratePerSec != null && (
                    <div className="text-right shrink-0">
                        <p className="text-xl font-bold tabular-nums text-violet-600 dark:text-violet-400">
                            {fmtRate(task.ratePerSec)}
                        </p>
                        <p className="text-[9px] text-muted-foreground uppercase tracking-wide">
                            throughput
                        </p>
                    </div>
                )}
            </div>

            {/* 7-day chart */}
            <div>
                <p className="text-[10px] text-muted-foreground uppercase tracking-wider mb-2">
                    7-day activity · completed{" "}
                    <span className="text-green-400">■</span> failed{" "}
                    <span className="text-red-400">■</span>
                </p>
                <TaskDailyChart namespace={namespace} taskName={task.name} />
            </div>
        </div>
    );
}

// ── Latency table ───────────────────────────────────────────────────────────

function LatencyTable({
    tasks,
    maxP95Ms,
    selectedTask,
    onSelectTask,
    namespace,
    kindMap,
}: {
    tasks: TaskSummary[];
    maxP95Ms: number;
    selectedTask: string | null;
    onSelectTask: (name: string | null) => void;
    namespace: string;
    kindMap: Map<string, "WORKFLOW" | "ACTIVITY">;
}) {
    const isEmpty = tasks.length === 0;

    return (
        <div className="rounded-lg border border-border overflow-hidden">
            {/* Table header bar */}
            <div className="px-4 py-3 border-b border-border/50 flex items-center justify-between bg-card/40">
                <div className="flex items-center gap-2">
                    <h2 className="text-sm font-medium text-foreground">
                        Task Latency
                    </h2>
                    <span className="inline-flex items-center gap-1 rounded-full border border-green-500/30 bg-green-500/10 px-2 py-0.5 text-[9px] font-medium text-green-600 dark:text-green-400 uppercase tracking-wide">
                        <span className="w-1.5 h-1.5 rounded-full bg-green-500 animate-pulse" />
                        Live
                    </span>
                </div>
                <div className="flex items-center gap-3">
                    {selectedTask && (
                        <button
                            onClick={() => onSelectTask(null)}
                            className="text-[10px] text-muted-foreground hover:text-foreground transition-colors"
                        >
                            ✕ Clear filter
                        </button>
                    )}
                    <span className="text-[10px] text-muted-foreground/70">
                        ±2% approx · click a row to drill down
                    </span>
                </div>
            </div>

            {isEmpty ? (
                <div className="py-10 text-center space-y-1">
                    <p className="text-sm text-muted-foreground">
                        No recent activity
                    </p>
                    <p className="text-xs text-muted-foreground/60">
                        Latency percentiles appear here while tasks are running.
                        Updates every few seconds automatically.
                    </p>
                </div>
            ) : (
                <table className="w-full text-sm">
                    <thead>
                        <tr className="border-b border-border bg-secondary/20">
                            {[
                                ["Task", "text-left"],
                                ["Queue", "text-left"],
                                ["Count", "text-right"],
                                ["Rate", "text-right"],
                                ["p50", "text-right"],
                                ["p95 ▸", "text-right"],
                                ["p99", "text-right"],
                                ["wait p50", "text-right"],
                                ["Fail %", "text-right"],
                            ].map(([h, align]) => (
                                <th
                                    key={h}
                                    className={`px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide whitespace-nowrap ${align}`}
                                >
                                    {h}
                                </th>
                            ))}
                        </tr>
                    </thead>
                    <tbody>
                        {tasks.map((t) => {
                            const isSelected = selectedTask === t.name;
                            const total = t.completedCount + t.failedCount;
                            const failRate =
                                total > 0 ? t.failedCount / total : 0;
                            const p95Pct =
                                t.p95Ms != null && maxP95Ms > 0
                                    ? (t.p95Ms / maxP95Ms) * 100
                                    : 0;

                            return (
                                <React.Fragment key={t.name}>
                                    <tr
                                        className={`border-b border-border/40 last:border-0 cursor-pointer transition-colors ${
                                            isSelected
                                                ? "bg-brand/5 border-brand/20"
                                                : "hover:bg-secondary/10"
                                        }`}
                                        onClick={() =>
                                            onSelectTask(
                                                isSelected ? null : t.name,
                                            )
                                        }
                                    >
                                        {/* Task name */}
                                        <td className="px-4 py-3">
                                            <div className="flex items-center gap-1.5">
                                                <span
                                                    className={`transition-transform duration-150 text-muted-foreground/50 text-[10px] ${isSelected ? "rotate-90" : ""}`}
                                                >
                                                    ▶
                                                </span>
                                                <span className="font-mono text-xs text-foreground">
                                                    {t.name}
                                                </span>
                                                {(() => {
                                                    const kind = kindMap.get(
                                                        t.name,
                                                    );
                                                    if (!kind) return null;
                                                    return kind ===
                                                        "WORKFLOW" ? (
                                                        <span className="text-[9px] bg-blue-500/15 text-blue-600 dark:text-blue-300 border border-blue-500/20 rounded px-[4px] py-[2px] font-mono leading-none">
                                                            W
                                                        </span>
                                                    ) : (
                                                        <span className="text-[9px] bg-amber-500/15 text-amber-600 dark:text-amber-300 border border-amber-500/20 rounded px-[4px] py-[2px] font-mono leading-none">
                                                            A
                                                        </span>
                                                    );
                                                })()}
                                            </div>
                                        </td>
                                        {/* Queue */}
                                        <td className="px-4 py-3 font-mono text-xs text-muted-foreground">
                                            {t.queue}
                                        </td>
                                        {/* Count */}
                                        <td className="px-4 py-3 text-right tabular-nums text-muted-foreground text-xs">
                                            {total.toLocaleString()}
                                        </td>
                                        {/* Rate */}
                                        <td className="px-4 py-3 text-right tabular-nums text-violet-600 dark:text-violet-400 text-xs whitespace-nowrap">
                                            {fmtRate(t.ratePerSec)}
                                        </td>
                                        {/* p50 */}
                                        <td className="px-4 py-3 text-right tabular-nums text-green-600 dark:text-green-400 text-xs">
                                            {fmtDuration(t.p50Ms)}
                                        </td>
                                        {/* p95 — with background bar */}
                                        <td className="px-4 py-3 text-right relative">
                                            {p95Pct > 0 && (
                                                <div
                                                    className="absolute inset-y-1 left-2 rounded-sm bg-yellow-500/10"
                                                    style={{
                                                        width: `calc(${p95Pct}% - 8px)`,
                                                    }}
                                                />
                                            )}
                                            <span className="relative tabular-nums text-yellow-600 dark:text-yellow-400 text-xs">
                                                {fmtDuration(t.p95Ms)}
                                            </span>
                                        </td>
                                        {/* p99 */}
                                        <td className="px-4 py-3 text-right tabular-nums text-orange-600 dark:text-orange-400 text-xs">
                                            {fmtDuration(t.p99Ms)}
                                        </td>
                                        {/* wait p50 */}
                                        <td className="px-4 py-3 text-right tabular-nums text-sky-600 dark:text-sky-400 text-xs">
                                            {fmtDuration(t.p50WaitMs)}
                                        </td>
                                        {/* Fail % */}
                                        <td className="px-4 py-3 text-right">
                                            <span
                                                className={`text-xs tabular-nums font-medium ${
                                                    failRate > 0.1
                                                        ? "text-red-600 dark:text-red-400"
                                                        : failRate > 0
                                                          ? "text-orange-600 dark:text-orange-400"
                                                          : "text-muted-foreground/50"
                                                }`}
                                            >
                                                {t.failedCount > 0
                                                    ? fmtPct(failRate)
                                                    : "—"}
                                            </span>
                                        </td>
                                    </tr>
                                    {/* Inline expansion */}
                                    {isSelected && (
                                        <tr className="border-b border-border/40">
                                            <td colSpan={9} className="p-0">
                                                <TaskExpansion
                                                    task={t}
                                                    namespace={namespace}
                                                />
                                            </td>
                                        </tr>
                                    )}
                                </React.Fragment>
                            );
                        })}
                    </tbody>
                </table>
            )}
        </div>
    );
}

// ── Top failing tasks panel ───────────────────────────────────────────────

function TopFailing({ tasks }: { tasks: TaskSummary[] }) {
    const failing = useMemo(
        () =>
            [...tasks]
                .filter((t) => t.failedCount > 0)
                .sort((a, b) => {
                    const rA =
                        a.failedCount / (a.completedCount + a.failedCount);
                    const rB =
                        b.failedCount / (b.completedCount + b.failedCount);
                    return rB - rA;
                })
                .slice(0, 6),
        [tasks],
    );

    return (
        <div className="rounded-lg border border-border bg-card/40 overflow-hidden">
            <div className="px-4 py-3 border-b border-border/50 flex items-center gap-2">
                <TrendingDown
                    size={13}
                    className={
                        failing.length > 0
                            ? "text-red-500"
                            : "text-muted-foreground/40"
                    }
                />
                <h2 className="text-sm font-medium text-foreground">
                    Top failing tasks
                </h2>
                <span className="text-[10px] text-muted-foreground ml-auto">
                    by failure rate · from live counts
                </span>
            </div>

            {failing.length === 0 ? (
                <div className="px-4 py-8 flex flex-col items-center gap-2">
                    <span className="text-2xl">✓</span>
                    <p className="text-xs text-muted-foreground text-center">
                        No failures detected
                    </p>
                    <p className="text-[10px] text-muted-foreground/50 text-center">
                        Failure rates will appear here when tasks fail during
                        the current broadcast window.
                    </p>
                </div>
            ) : (
                <div className="divide-y divide-border/30">
                    {failing.map((t) => {
                        const total = t.completedCount + t.failedCount;
                        const rate = t.failedCount / total;
                        return (
                            <div
                                key={t.name}
                                className="px-4 py-2.5 flex items-center gap-3"
                            >
                                <span className="font-mono text-xs text-foreground truncate flex-1 min-w-0">
                                    {t.name}
                                </span>
                                <span className="text-xs tabular-nums text-muted-foreground whitespace-nowrap">
                                    {t.failedCount.toLocaleString()} failures
                                </span>
                                <span
                                    className={`text-xs font-semibold tabular-nums whitespace-nowrap ${
                                        rate > 0.5
                                            ? "text-red-600 dark:text-red-400"
                                            : rate > 0.1
                                              ? "text-orange-600 dark:text-orange-400"
                                              : "text-yellow-600 dark:text-yellow-400"
                                    }`}
                                >
                                    {fmtPct(rate)}
                                </span>
                                {/* Fail rate bar */}
                                <div className="w-16 h-1.5 rounded-full bg-secondary/40 shrink-0">
                                    <div
                                        className={`h-full rounded-full ${
                                            rate > 0.5
                                                ? "bg-red-500"
                                                : rate > 0.1
                                                  ? "bg-orange-400"
                                                  : "bg-yellow-400"
                                        }`}
                                        style={{
                                            width: `${Math.min(100, rate * 100)}%`,
                                        }}
                                    />
                                </div>
                            </div>
                        );
                    })}
                </div>
            )}
        </div>
    );
}

// ── Worker queue-pressure gauge ──────────────────────────────────────────
//
// WHY queue pressure and not running/capacity:
// Worker slot utilisation (running_tasks from strand.workers) is
// frequently 0 even when the system is busy because Strand workflows
// release their slot the moment they suspend on ctx.runActivity().
// The meaningful signal is: "how many tasks are queued relative to
// our capacity to drain them?" — i.e. pending / total-slots.
//
//  < 50 %  green   — workers comfortably ahead of the queue
//  50–99 %  yellow  — queue is building up
// ≥100 %   red     — at or over capacity (backlog accumulating)

function WorkerGauge({
    workers,
    pending,
}: {
    workers: Worker[];
    pending: number;
}) {
    const totalCapacity = workers.reduce((s, w) => s + w.concurrency, 0);
    const healthyCount = workers.filter((w) => w.isHealthy).length;
    const recentlyCompleted = workers.reduce(
        (s, w) => s + w.completedRecently,
        0,
    );

    // Queue pressure ratio: pending tasks vs total worker slots.
    // > 1.0 means more tasks are queued than there are slots to drain them.
    const ratio = totalCapacity > 0 ? pending / totalCapacity : 0;
    const pct = Math.min(1, ratio); // 0–1 for the ring arc

    const pressureColor =
        ratio >= 1.0
            ? "#f87171" // red — at or over capacity
            : ratio >= 0.5
              ? "#facc15" // yellow — building up
              : ratio > 0
                ? "#4ade80" // green — some queue but comfortable
                : "#334155"; // dim — queue is empty

    const gaugeData =
        totalCapacity > 0
            ? [
                  {
                      name: "Queued",
                      value: Math.min(pending, totalCapacity),
                      color: pressureColor,
                  },
                  {
                      name: "Free",
                      value: Math.max(0, totalCapacity - pending),
                      color: "transparent",
                  },
              ]
            : [{ name: "None", value: 1, color: "#334155" }];

    // Centre label
    let centreMain: string;
    let centreSub: string;
    if (pending === 0) {
        centreMain = "Clear";
        centreSub = "";
    } else if (ratio >= 1.0) {
        centreMain = `${ratio.toFixed(1)}×`;
        centreSub = "over cap";
    } else {
        centreMain = `${Math.round(pct * 100)}%`;
        centreSub = "load";
    }

    return (
        <div className="rounded-lg border border-border bg-card/40 p-4 flex items-center gap-5">
            {/* Pressure ring */}
            <div
                className="relative shrink-0"
                style={{ width: 80, height: 80 }}
            >
                <ResponsiveContainer width="100%" height="100%">
                    <PieChart>
                        <Pie
                            data={gaugeData}
                            cx="50%"
                            cy="50%"
                            innerRadius={26}
                            outerRadius={36}
                            startAngle={90}
                            endAngle={-270}
                            dataKey="value"
                            stroke="none"
                        >
                            {gaugeData.map((e) => (
                                <Cell key={e.name} fill={e.color} />
                            ))}
                        </Pie>
                    </PieChart>
                </ResponsiveContainer>
                <div className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none">
                    <span
                        className="text-sm font-bold tabular-nums leading-none"
                        style={{
                            color:
                                pending === 0 ? pressureColor : pressureColor,
                        }}
                    >
                        {centreMain}
                    </span>
                    {centreSub && (
                        <span className="text-[9px] text-muted-foreground mt-0.5">
                            {centreSub}
                        </span>
                    )}
                </div>
            </div>

            {/* Stats */}
            <div className="flex flex-col gap-1 min-w-0">
                <div className="flex items-center gap-1.5">
                    <p className="text-sm font-medium text-foreground">
                        Workers
                    </p>
                    {healthyCount < workers.length && (
                        <span className="text-[9px] text-yellow-500 font-medium">
                            ⚠ unhealthy
                        </span>
                    )}
                </div>
                <p className="text-xs text-muted-foreground">
                    {workers.length} active · {healthyCount} healthy ·{" "}
                    {totalCapacity} slots
                </p>
                <div className="flex items-center gap-3 mt-0.5">
                    <span
                        className={`text-[11px] tabular-nums font-medium ${
                            pending === 0
                                ? "text-muted-foreground/50"
                                : ratio >= 1.0
                                  ? "text-red-500"
                                  : ratio >= 0.5
                                    ? "text-yellow-500"
                                    : "text-green-500"
                        }`}
                    >
                        {pending.toLocaleString()} pending
                    </span>
                    {recentlyCompleted > 0 && (
                        <span className="text-[11px] text-muted-foreground/50 tabular-nums">
                            {recentlyCompleted} done recently
                        </span>
                    )}
                </div>
                <p className="text-[9px] text-muted-foreground/40 mt-0.5">
                    Queue pressure · pending ÷ slots
                </p>
            </div>
        </div>
    );
}

// ── Page ──────────────────────────────────────────────────────────────────

export function MetricsPage() {
    usePageTitle("Metrics");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const [selectedTask, setSelectedTask] = useState<string | null>(null);
    const [lastUpdated, setLastUpdated] = useState<Date | null>(null);
    const [secondsAgo, setSecondsAgo] = useState(0);
    const [hours, setHours] = useState<number>(24);

    const { data, isLoading, error, refetch } = useQuery({
        queryKey: [...qk.metrics.get(namespace), hours],
        queryFn: () => getMetrics(namespace, hours),
        refetchInterval: 30_000,
    });

    // Track when data last updated
    useEffect(() => {
        if (data) setLastUpdated(new Date());
    }, [data]);

    // Tick "updated X ago" every second
    useEffect(() => {
        if (!lastUpdated) return;
        const id = setInterval(() => {
            setSecondsAgo(
                Math.round((Date.now() - lastUpdated.getTime()) / 1000),
            );
        }, 1_000);
        return () => clearInterval(id);
    }, [lastUpdated]);

    // Collapse taskTimings into one row per task
    const taskSummaries = useMemo<TaskSummary[]>(() => {
        if (!data?.taskTimings) return [];
        const byName = new Map<string, TaskSummary>();
        for (const t of data.taskTimings) {
            const existing: TaskSummary = byName.get(t.taskName) ?? {
                name: t.taskName,
                queue: t.queue,
                completedCount: 0,
                failedCount: 0,
                ratePerSec: null,
                p50Ms: null,
                p95Ms: null,
                p99Ms: null,
                p50WaitMs: null,
                p95WaitMs: null,
            };
            if (t.state === "COMPLETED") {
                existing.completedCount = t.count;
                existing.ratePerSec = t.ratePerSec;
                existing.p50Ms = t.p50Ms;
                existing.p95Ms = t.p95Ms;
                existing.p99Ms = t.p99Ms;
                existing.p50WaitMs = t.p50WaitMs;
                existing.p95WaitMs = t.p95WaitMs;
            } else {
                existing.failedCount = t.count;
            }
            byName.set(t.taskName, existing);
        }
        return [...byName.values()].sort(
            (a, b) =>
                b.completedCount +
                b.failedCount -
                (a.completedCount + a.failedCount),
        );
    }, [data?.taskTimings]);

    const maxP95Ms = useMemo(
        () => Math.max(...taskSummaries.map((t) => t.p95Ms ?? 0), 1),
        [taskSummaries],
    );

    // Build donut slices (filter out zeros)
    const donutSlices = useMemo<DonutSlice[]>(() => {
        if (!data) return [];
        return [
            {
                name: "Completed",
                value: data.completed,
                color: DONUT_COLORS.Completed,
            },
            { name: "Failed", value: data.failed, color: DONUT_COLORS.Failed },
            {
                name: "Cancelled",
                value: data.cancelled,
                color: DONUT_COLORS.Cancelled,
            },
            {
                name: "Running",
                value: data.running,
                color: DONUT_COLORS.Running,
            },
            {
                name: "Pending",
                value: data.pending,
                color: DONUT_COLORS.Pending,
            },
        ].filter((s) => s.value > 0);
    }, [data]);

    const donutTotal = useMemo(
        () => donutSlices.reduce((s, d) => s + d.value, 0),
        [donutSlices],
    );

    // Merge completed + failed per hour into one series
    const combinedChartData = useMemo<CombinedBucket[]>(() => {
        if (!data) return [];
        const byHour = new Map<string, CombinedBucket>();
        for (const b of data.throughputPerHour) {
            byHour.set(b.hour, {
                label: fmtHour(b.hour),
                completed: b.count,
                failed: 0,
            });
        }
        for (const b of data.errorRatePerHour) {
            const ex = byHour.get(b.hour) ?? {
                label: fmtHour(b.hour),
                completed: 0,
                failed: 0,
            };
            ex.failed = b.count;
            byHour.set(b.hour, ex);
        }
        return [...byHour.entries()]
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([, v]) => v);
    }, [data]);

    const errorRate = useMemo(() => {
        if (!data || data.completed + data.failed === 0) return null;
        return data.failed / (data.completed + data.failed);
    }, [data]);

    const { data: workers = [] } = useQuery<Worker[]>({
        queryKey: ["workers", namespace],
        queryFn: () => getWorkers(namespace),
        refetchInterval: 10_000,
    });

    const { data: taskKinds = [] } = useQuery<TaskKindEntry[]>({
        queryKey: ["task-kinds", namespace],
        queryFn: () => getTaskKinds(namespace),
        staleTime: 60_000,
    });

    const kindMap = useMemo(
        () =>
            new Map(
                taskKinds.map(
                    (e) =>
                        [e.name, e.kind] as [string, "WORKFLOW" | "ACTIVITY"],
                ),
            ),
        [taskKinds],
    );

    const handleSelectTask = useCallback((name: string | null) => {
        setSelectedTask(name);
    }, []);

    return (
        <div className="px-6 py-5 space-y-5">
            {/* ── Header ──────────────────────────────────────────────── */}
            <div className="flex items-center gap-3">
                <div className="mr-auto">
                    <h1 className="text-base font-semibold text-foreground">
                        Metrics
                    </h1>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Namespace-wide &middot;{" "}
                        {hours === 168 ? "7 day" : `${hours} h`} window &middot;
                        live latency percentiles
                    </p>
                </div>
                {lastUpdated && (
                    <span className="text-[10px] text-muted-foreground tabular-nums">
                        Updated {fmtSecondsAgo(secondsAgo)}
                    </span>
                )}
                {/* Time window selector */}
                <div className="flex items-center rounded-md border border-border overflow-hidden text-xs">
                    {([1, 6, 24, 168] as const).map((h) => (
                        <button
                            key={h}
                            onClick={() => setHours(h)}
                            className={`px-2.5 py-1.5 transition-colors border-r border-border last:border-0 ${
                                hours === h
                                    ? "bg-brand/15 text-brand font-medium"
                                    : "text-muted-foreground hover:text-foreground hover:bg-secondary/40"
                            }`}
                        >
                            {h === 168 ? "7d" : `${h}h`}
                        </button>
                    ))}
                </div>
                <button
                    onClick={() => refetch()}
                    className="p-1.5 rounded border border-border text-muted-foreground hover:text-foreground hover:bg-secondary/40 transition-colors"
                    title="Refresh metrics"
                >
                    <RefreshCw size={12} />
                </button>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {data && (
                <>
                    {/* ── Overview row: donut + stat tiles ────────────── */}
                    <div className="grid grid-cols-1 lg:grid-cols-[auto_1fr] gap-4">
                        {/* Status donut */}
                        <div className="rounded-lg border border-border bg-card/40 p-5 flex items-center">
                            <StatusDonut
                                slices={donutSlices}
                                total={donutTotal}
                            />
                        </div>

                        {/* Key metrics grid */}
                        <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 content-start">
                            <StatTile
                                label="Throughput"
                                value={
                                    data.throughputPerSec != null
                                        ? fmtRate(data.throughputPerSec)
                                        : "—"
                                }
                                sub="smoothed · ~15 s avg"
                                colorClass="text-violet-600 dark:text-violet-400"
                            />
                            <StatTile
                                label="Avg Duration (p50)"
                                value={fmtDuration(data.avgDurationMs)}
                                sub={
                                    data.taskTimings != null
                                        ? "live · ±2% approx"
                                        : "24 h avg from DB"
                                }
                                colorClass="text-foreground"
                            />
                            <StatTile
                                label="Error Rate (24 h)"
                                value={
                                    errorRate != null ? fmtPct(errorRate) : "—"
                                }
                                sub={
                                    errorRate != null && errorRate > 0.05
                                        ? "⚠ above 5%"
                                        : undefined
                                }
                                colorClass={
                                    errorRate != null && errorRate > 0.1
                                        ? "text-red-600 dark:text-red-400"
                                        : errorRate != null && errorRate > 0.05
                                          ? "text-orange-600 dark:text-orange-400"
                                          : "text-foreground"
                                }
                            />
                            <StatTile
                                label="Running"
                                value={data.running.toLocaleString()}
                                colorClass="text-blue-600 dark:text-blue-400"
                            />
                            <StatTile
                                label="Pending"
                                value={data.pending.toLocaleString()}
                                colorClass="text-yellow-600 dark:text-yellow-400"
                            />
                            <StatTile
                                label="Cancelled (24 h)"
                                value={data.cancelled.toLocaleString()}
                                colorClass="text-muted-foreground"
                            />
                        </div>
                    </div>

                    {/* ── Worker queue-pressure gauge ──────────────────── */}
                    {workers.length > 0 && (
                        <WorkerGauge workers={workers} pending={data.pending} />
                    )}

                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <div className="flex items-center justify-between mb-4">
                            <h2 className="text-sm font-medium text-foreground flex items-center gap-2">
                                <Activity
                                    size={13}
                                    className="text-muted-foreground"
                                />
                                Executions (last 24 h)
                            </h2>
                            <div className="flex items-center gap-3 text-[10px] text-muted-foreground">
                                <span className="flex items-center gap-1">
                                    <span className="w-2.5 h-2.5 rounded-sm bg-green-400 inline-block" />
                                    Completed
                                </span>
                                <span className="flex items-center gap-1">
                                    <span className="w-2.5 h-2.5 rounded-sm bg-red-400 inline-block" />
                                    Failed
                                </span>
                            </div>
                        </div>
                        <ThroughputChart data={combinedChartData} />
                    </section>

                    {/* ── Latency + top failing ───────────────────────── */}
                    <div className="grid grid-cols-1 xl:grid-cols-[1fr_320px] gap-4 items-start">
                        <LatencyTable
                            tasks={taskSummaries}
                            maxP95Ms={maxP95Ms}
                            selectedTask={selectedTask}
                            onSelectTask={handleSelectTask}
                            namespace={namespace}
                            kindMap={kindMap}
                        />
                        <TopFailing tasks={taskSummaries} />
                    </div>
                </>
            )}
        </div>
    );
}
