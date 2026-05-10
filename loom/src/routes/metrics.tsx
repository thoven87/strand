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
} from "recharts";
import { getMetrics } from "@/api/metrics";
import type { TaskTiming } from "@/api/metrics";
import { qk } from "@/lib/queryKeys";

// ── Helpers ───────────────────────────────────────────────────────────────

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

function fmtDuration(ms: number | null | undefined): string {
    if (ms == null || !isFinite(ms) || ms < 0) return "—";
    if (ms < 1000) return `${Math.round(ms)}ms`;
    if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1000);
    return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

// ── Stat card ──────────────────────────────────────────────────────────────

interface StatCardProps {
    label: string;
    value: number;
    colorClass: string;
}

function StatCard({ label, value, colorClass }: StatCardProps) {
    return (
        <div className="rounded-lg border border-border bg-card/40 p-4 flex flex-col gap-1">
            <span className={`text-2xl font-bold tabular-nums ${colorClass}`}>
                {value.toLocaleString()}
            </span>
            <span className="text-xs text-muted-foreground font-medium uppercase tracking-wide">
                {label}
            </span>
        </div>
    );
}

// ── Custom tooltip ─────────────────────────────────────────────────────────

function ChartTooltip({
    active,
    payload,
    label,
}: {
    active?: boolean;
    payload?: { value: number }[];
    label?: string;
}) {
    if (!active || !payload?.length) return null;
    return (
        <div className="rounded-md border border-border bg-slate-900 px-3 py-2 text-xs shadow-xl">
            <p className="text-muted-foreground mb-0.5">{label}</p>
            <p className="font-semibold text-foreground">{payload[0].value}</p>
        </div>
    );
}

// ── Chart section ──────────────────────────────────────────────────────────

interface ChartSectionProps {
    title: string;
    data: { hour: string; count: number }[];
    fill: string;
}

function ChartSection({ title, data, fill }: ChartSectionProps) {
    const chartData = data.map((d) => ({ ...d, label: fmtHour(d.hour) }));

    return (
        <section className="rounded-lg border border-border bg-card/40 p-4">
            <h2 className="text-sm font-medium text-foreground mb-4">
                {title}
            </h2>
            {data.length === 0 ? (
                <p className="text-xs text-muted-foreground py-8 text-center">
                    No data yet.
                </p>
            ) : (
                <ResponsiveContainer width="100%" height={180}>
                    <BarChart
                        data={chartData}
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
                            content={<ChartTooltip />}
                            cursor={{ fill: "rgba(255,255,255,0.04)" }}
                        />
                        <Bar
                            dataKey="count"
                            fill={fill}
                            radius={[3, 3, 0, 0]}
                            maxBarSize={32}
                        />
                    </BarChart>
                </ResponsiveContainer>
            )}
        </section>
    );
}

// ── Latency table ──────────────────────────────────────────────────────────

function LatencyTable({ timings }: { timings: TaskTiming[] }) {
    // Sort completed first, then by count descending
    const sorted = [...timings].sort((a, b) => {
        if (a.state !== b.state) return a.state === "COMPLETED" ? -1 : 1;
        return b.count - a.count;
    });

    const headers = [
        "Queue",
        "Task",
        "State",
        "Count",
        "Rate",
        "exec p50",
        "exec p95",
        "exec p99",
        "wait p50",
        "wait p95",
    ];

    return (
        <section className="rounded-lg border border-border bg-card/40 overflow-hidden">
            <div className="px-4 py-3 border-b border-border/50 flex items-center justify-between">
                <h2 className="text-sm font-medium text-foreground">
                    Task latency
                </h2>
                <span className="text-xs text-muted-foreground">
                    exec = run duration · wait = queue time · ±2% error
                </span>
            </div>
            <div className="overflow-x-auto">
                <table className="w-full text-sm">
                    <thead>
                        <tr className="border-b border-border bg-secondary/20">
                            {headers.map((h) => (
                                <th
                                    key={h}
                                    className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide whitespace-nowrap"
                                >
                                    {h}
                                </th>
                            ))}
                        </tr>
                    </thead>
                    <tbody>
                        {sorted.map((t) => (
                            <tr
                                key={`${t.queue}/${t.taskName}/${t.state}`}
                                className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                            >
                                <td className="px-4 py-3 font-mono text-xs text-muted-foreground whitespace-nowrap">
                                    {t.queue}
                                </td>
                                <td className="px-4 py-3 font-mono text-xs text-foreground whitespace-nowrap">
                                    {t.taskName}
                                </td>
                                <td className="px-4 py-3">
                                    <span
                                        className={`inline-flex items-center rounded border px-1.5 py-0.5 text-[10px] font-medium ${
                                            t.state === "COMPLETED"
                                                ? "bg-green-500/15 text-green-300 border-green-500/25"
                                                : "bg-red-500/15 text-red-300 border-red-500/25"
                                        }`}
                                    >
                                        {t.state}
                                    </span>
                                </td>
                                <td className="px-4 py-3 text-muted-foreground tabular-nums">
                                    {t.count.toLocaleString()}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-violet-400 whitespace-nowrap">
                                    {fmtRate(t.ratePerSec)}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-green-400">
                                    {fmtDuration(t.p50Ms)}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-yellow-400">
                                    {fmtDuration(t.p95Ms)}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-orange-400">
                                    {fmtDuration(t.p99Ms)}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-sky-400">
                                    {fmtDuration(t.p50WaitMs)}
                                </td>
                                <td className="px-4 py-3 tabular-nums text-blue-400">
                                    {fmtDuration(t.p95WaitMs)}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            </div>
        </section>
    );
}

// ── Page ───────────────────────────────────────────────────────────────────

export function MetricsPage() {
    usePageTitle("Metrics");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const { data, isLoading, error } = useQuery({
        queryKey: qk.metrics.get(namespace),
        queryFn: () => getMetrics(namespace),
        refetchInterval: 30_000,
    });

    return (
        <div className="px-6 py-5 space-y-5">
            <div>
                <h1 className="text-base font-semibold text-foreground mb-0.5">
                    Metrics
                </h1>
                <p className="text-xs text-muted-foreground">
                    All queues in this namespace · completed/failed/cancelled
                    counts are last 24 h
                </p>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {data && (
                <>
                    {/* Summary stat cards */}
                    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-6 gap-3">
                        <StatCard
                            label="Completed (24h)"
                            value={data.completed}
                            colorClass="text-green-400"
                        />
                        <StatCard
                            label="Failed (24h)"
                            value={data.failed}
                            colorClass="text-red-400"
                        />
                        <StatCard
                            label="Cancelled (24h)"
                            value={data.cancelled}
                            colorClass="text-muted-foreground"
                        />
                        <StatCard
                            label="Pending"
                            value={data.pending}
                            colorClass="text-yellow-400"
                        />
                        <StatCard
                            label="Running"
                            value={data.running}
                            colorClass="text-blue-400"
                        />
                        {/* Throughput card — only rendered when the broadcast
                             cache is warm (AggregatedMetricsBuffer wired in). */}
                        <div className="rounded-lg border border-border bg-card/40 p-4 flex flex-col gap-1">
                            <span className="text-2xl font-bold tabular-nums text-violet-400">
                                {data.throughputPerSec != null
                                    ? fmtRate(data.throughputPerSec)
                                    : "—"}
                            </span>
                            <span className="text-xs text-muted-foreground font-medium uppercase tracking-wide">
                                Throughput
                            </span>
                            <span className="text-[10px] text-muted-foreground/60">
                                live · last 5 s window
                            </span>
                        </div>
                    </div>

                    {/* Avg duration */}
                    {data.avgDurationMs != null &&
                        isFinite(data.avgDurationMs) && (
                            <div className="rounded-lg border border-border bg-card/40 p-4 inline-flex items-center gap-3">
                                <span className="text-xs text-muted-foreground uppercase tracking-wide font-medium">
                                    Avg Duration
                                </span>
                                <span className="text-lg font-semibold text-foreground tabular-nums">
                                    {fmtDuration(data.avgDurationMs)}
                                </span>
                            </div>
                        )}

                    {/* Task latency percentiles (DDSketch) */}
                    {data.taskTimings && data.taskTimings.length > 0 && (
                        <LatencyTable timings={data.taskTimings} />
                    )}

                    {/* Charts */}
                    <ChartSection
                        title="Completed tasks (last 24h)"
                        data={data.throughputPerHour}
                        fill="#4ade80"
                    />
                    <ChartSection
                        title="Failed tasks (last 24h)"
                        data={data.errorRatePerHour}
                        fill="#f87171"
                    />
                </>
            )}
        </div>
    );
}
