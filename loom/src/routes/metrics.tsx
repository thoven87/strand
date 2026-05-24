import { useState, useMemo } from "react";
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
import { Activity } from "lucide-react";
import { getMetrics } from "@/api/metrics";
import { getWorkers } from "@/api/workers";
import type { Worker } from "@/api/workers";
import { qk } from "@/lib/queryKeys";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
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
    const [hours, setHours] = useState<number>(24);
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    const { data, isLoading, error } = useQuery({
        queryKey: [...qk.metrics.get(namespace), hours],
        queryFn: () => getMetrics(namespace, hours),
        refetchInterval: intervalMs,
    });

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
        refetchInterval: intervalMs,
    });

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
                        {hours === 168 ? "7 day" : `${hours} h`} window
                    </p>
                </div>
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
                <AutoRefreshControl
                    intervalMs={intervalMs}
                    setIntervalMs={setIntervalMs}
                />
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
                                Runs (last 24 h)
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
                </>
            )}
        </div>
    );
}
