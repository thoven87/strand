import { useState } from "react";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { usePageTitle } from "@/lib/usePageTitle";
import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { Zap, Play, Search } from "lucide-react";
import {
    listTaskDefinitions,
    getTaskDefinitionActivity,
    type DailyActivity,
} from "@/api/workflows";
import type { TaskKind } from "@/api/types";
import { RelativeTime } from "@/components/RelativeTime";
import { TriggerDialog } from "@/components/TriggerDialog";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/EmptyState";
import { qk } from "@/lib/queryKeys";
import { fmtDuration } from "@/lib/utils";
import { BarChart, Bar, ResponsiveContainer, Tooltip } from "recharts";

function MiniSparkline({
    name,
    namespace,
}: {
    name: string;
    namespace: string;
}) {
    const { data = [] } = useQuery<DailyActivity[]>({
        queryKey: [...qk.tasks.activity(namespace, name)],
        queryFn: () => getTaskDefinitionActivity(namespace, name, 7),
        staleTime: 5 * 60_000,
    });

    if (data.length === 0) {
        return <span className="text-muted-foreground/30 text-xs">—</span>;
    }

    const hasFailures = data.some((d) => d.failed > 0);

    return (
        <div style={{ width: 64, height: 24 }}>
            <ResponsiveContainer width="100%" height="100%">
                <BarChart data={data} barCategoryGap="10%">
                    <Tooltip
                        content={({ active, payload }) => {
                            if (!active || !payload?.length) return null;
                            const d = payload[0].payload as DailyActivity;
                            return (
                                <div className="rounded border border-border bg-background px-2 py-1 text-[10px] shadow-lg">
                                    <p className="text-foreground">
                                        {d.total} runs
                                    </p>
                                    {d.failed > 0 && (
                                        <p className="text-red-400">
                                            {d.failed} failed
                                        </p>
                                    )}
                                </div>
                            );
                        }}
                    />
                    <Bar
                        dataKey="total"
                        fill={hasFailures ? "rgb(239,68,68)" : "rgb(34,197,94)"}
                        opacity={0.7}
                        radius={[1, 1, 0, 0]}
                        minPointSize={2}
                    />
                </BarChart>
            </ResponsiveContainer>
        </div>
    );
}

function KindBadge({ kind }: { kind: TaskKind }) {
    if (kind === "WORKFLOW")
        return (
            <span className="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-blue-500/15 text-blue-400 border border-blue-500/20">
                W
            </span>
        );
    return (
        <span className="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-amber-500/15 text-amber-400 border border-amber-500/20">
            A
        </span>
    );
}

export function TasksPage() {
    usePageTitle("Tasks");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const { intervalMs, setIntervalMs } = useAutoRefresh();
    const [triggerTarget, setTriggerTarget] = useState<string | null>(null);
    const [enqueueTarget, setEnqueueTarget] = useState<string | null>(null);
    const [query, setQuery] = useState("");

    const { data: definitions = [], isLoading } = useQuery({
        queryKey: [...qk.schedules.list(namespace), "task-definitions"],
        queryFn: () => listTaskDefinitions(namespace),
        refetchInterval: intervalMs,
        placeholderData: keepPreviousData,
    });

    return (
        <div className="px-6 py-5">
            <div className="flex items-center justify-between mb-4">
                <div>
                    <h1 className="text-base font-semibold text-foreground">
                        Tasks
                    </h1>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Root task definitions — workflows and standalone
                        activities.
                    </p>
                </div>
                <AutoRefreshControl
                    intervalMs={intervalMs}
                    setIntervalMs={setIntervalMs}
                />
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {!isLoading && definitions.length === 0 && (
                <EmptyState
                    variant="tasks"
                    title="No tasks yet"
                    description="Enqueue a workflow or activity to see it here."
                />
            )}

            {definitions.length > 0 && (
                <>
                    {/* Search bar */}
                    <div className="relative mb-3 w-56">
                        <Search
                            size={13}
                            className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none"
                        />
                        <input
                            type="search"
                            placeholder="Filter by name…"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                            className="pl-7 pr-3 py-1.5 w-full rounded border border-border bg-secondary/30 text-foreground text-xs focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/50"
                        />
                    </div>
                    <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-sm">
                            <thead className="sticky top-0 z-10 bg-background">
                                <tr className="border-b border-border bg-secondary/20">
                                    {(
                                        [
                                            ["kind", ""],
                                            ["name", "Name"],
                                            ["running", "Running"],
                                            ["queued", "Queued"],
                                            ["failed", "Failed"],
                                            ["total", "Total"],
                                            ["avgDuration", "Avg Duration"],
                                            ["activity", "7d Activity"],
                                            ["lastSeen", "Last Seen"],
                                            ["actions", ""],
                                        ] as [string, string][]
                                    ).map(([key, label]) => (
                                        <th
                                            key={key}
                                            className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide"
                                        >
                                            {label}
                                        </th>
                                    ))}
                                </tr>
                            </thead>
                            <tbody>
                                {definitions
                                    .filter(
                                        (d) =>
                                            !query ||
                                            d.name
                                                .toLowerCase()
                                                .includes(query.toLowerCase()),
                                    )
                                    .map((def) => (
                                        <tr
                                            key={`${def.name}:${def.kind}`}
                                            className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                        >
                                            <td className="px-4 py-3 w-8">
                                                <KindBadge kind={def.kind} />
                                            </td>
                                            <td className="px-4 py-3 font-medium font-mono text-sm">
                                                <Link
                                                    to="/$namespace/runs"
                                                    params={{ namespace }}
                                                    search={{
                                                        kind: def.kind,
                                                        name: def.name,
                                                    }}
                                                    className="text-foreground hover:text-brand transition-colors"
                                                >
                                                    {def.name}
                                                </Link>
                                            </td>
                                            <td className="px-4 py-3 text-sm tabular-nums">
                                                <span
                                                    className={
                                                        def.runningRuns > 0
                                                            ? "text-green-400"
                                                            : "text-muted-foreground"
                                                    }
                                                >
                                                    {def.runningRuns}
                                                </span>
                                            </td>
                                            <td className="px-4 py-3 text-sm tabular-nums">
                                                <span
                                                    className={
                                                        def.queuedRuns > 0
                                                            ? "text-yellow-400"
                                                            : "text-muted-foreground"
                                                    }
                                                >
                                                    {def.queuedRuns}
                                                </span>
                                            </td>
                                            <td className="px-4 py-3 text-sm tabular-nums">
                                                <span
                                                    className={
                                                        def.failedRuns > 0
                                                            ? "text-red-400"
                                                            : "text-muted-foreground"
                                                    }
                                                >
                                                    {def.failedRuns}
                                                </span>
                                            </td>
                                            <td className="px-4 py-3 text-sm tabular-nums text-muted-foreground">
                                                {def.totalRuns.toLocaleString()}
                                            </td>
                                            <td className="px-4 py-3 font-mono text-xs text-muted-foreground">
                                                {fmtDuration(def.avgDurationMs)}
                                            </td>
                                            <td className="px-4 py-3">
                                                <MiniSparkline
                                                    name={def.name}
                                                    namespace={namespace}
                                                />
                                            </td>
                                            <td className="px-4 py-3 text-xs text-muted-foreground">
                                                {def.lastSeenAt ? (
                                                    <RelativeTime
                                                        iso={def.lastSeenAt}
                                                    />
                                                ) : (
                                                    "—"
                                                )}
                                            </td>
                                            <td className="px-4 py-3">
                                                <div className="flex items-center gap-2">
                                                    {def.kind ===
                                                        "WORKFLOW" && (
                                                        <Button
                                                            size="sm"
                                                            variant="outline"
                                                            onClick={() =>
                                                                setTriggerTarget(
                                                                    def.name,
                                                                )
                                                            }
                                                            className="gap-1 h-7 text-xs"
                                                        >
                                                            <Zap size={11} />
                                                            Run
                                                        </Button>
                                                    )}
                                                    {def.kind ===
                                                        "ACTIVITY" && (
                                                        <Button
                                                            size="sm"
                                                            variant="outline"
                                                            onClick={() =>
                                                                setEnqueueTarget(
                                                                    def.name,
                                                                )
                                                            }
                                                            className="gap-1 h-7 text-xs text-amber-500 border-amber-500/30 hover:bg-amber-500/10"
                                                        >
                                                            <Play size={11} />
                                                            Enqueue
                                                        </Button>
                                                    )}
                                                </div>
                                            </td>
                                        </tr>
                                    ))}
                            </tbody>
                        </table>
                    </div>
                </>
            )}

            <TriggerDialog
                open={triggerTarget !== null}
                onClose={() => setTriggerTarget(null)}
                namespace={namespace}
                initialWorkflowName={triggerTarget ?? undefined}
            />

            <TriggerDialog
                kind="ACTIVITY"
                open={enqueueTarget !== null}
                onClose={() => setEnqueueTarget(null)}
                namespace={namespace}
                initialActivityName={enqueueTarget ?? undefined}
            />
        </div>
    );
}
