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

function fmtDuration(ms: number): string {
    if (!isFinite(ms) || ms < 0) return "—";
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
            <h1 className="text-base font-semibold text-foreground">Metrics</h1>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {data && (
                <>
                    {/* Summary stat cards */}
                    <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
                        <StatCard
                            label="Completed"
                            value={data.completed}
                            colorClass="text-green-400"
                        />
                        <StatCard
                            label="Failed"
                            value={data.failed}
                            colorClass="text-red-400"
                        />
                        <StatCard
                            label="Cancelled"
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
