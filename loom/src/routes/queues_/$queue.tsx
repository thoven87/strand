import { useState } from "react";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { getTasks } from "@/api/tasks";
import { getQueue, pauseQueue, resumeQueue } from "@/api/queues";
import { qk } from "@/lib/queryKeys";
import { getStoredNamespace } from "@/lib/namespace";
import { usePageTitle } from "@/lib/usePageTitle";
import { StatusBadge } from "@/components/ui/badge";
import { RelativeTime } from "@/components/RelativeTime";
import { Paginator } from "@/components/Paginator";
import { Button } from "@/components/ui/button";
import { CalendarClock, ArrowLeft, Pause, Play } from "lucide-react";
import type { Queue, TaskStatus, TaskSummary } from "@/api/types";

// State config — collapsed to public TaskStatus values.
// RUNNING covers running+sleeping+waiting; QUEUED covers pending.
// The server still stores the granular states; the count keys map to
// the QueueStats fields that the backend aggregates from strand.tasks.
const STATE_CONFIG = [
    {
        state: "RUNNING",
        // running + sleeping + waiting are all "in progress" from user perspective
        countFn: (s: import("@/api/types").QueueStats) =>
            s.running + s.sleeping + s.waiting,
        accent: "bg-yellow-500/20 text-yellow-300",
    },
    {
        state: "QUEUED",
        countFn: (s: import("@/api/types").QueueStats) => s.pending,
        accent: "bg-blue-500/15 text-blue-400",
    },
] as const;

function StatePill({
    label,
    count,
    active,
    accent,
    onClick,
}: {
    label: string;
    count: number;
    active: boolean;
    accent: string;
    onClick: () => void;
}) {
    return (
        <button
            onClick={onClick}
            className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                active
                    ? "bg-secondary text-foreground"
                    : "text-muted-foreground hover:text-foreground hover:bg-secondary/60"
            }`}
        >
            {label}
            {count > 0 && (
                <span
                    className={`rounded px-1 py-px text-[10px] font-mono leading-none ${
                        active ? "bg-white/10 text-foreground" : accent
                    }`}
                >
                    {count >= 1000 ? `${Math.floor(count / 1000)}k` : count}
                </span>
            )}
        </button>
    );
}

function QueueBar({ stats }: { stats: Queue["stats"] }) {
    const total =
        stats.pending + stats.running + stats.sleeping + stats.waiting;

    if (total === 0)
        return (
            <span className="text-xs text-muted-foreground">
                No active tasks
            </span>
        );

    const segments = [
        { count: stats.running, cls: "bg-yellow-400" },
        { count: stats.pending, cls: "bg-blue-400" },
        { count: stats.sleeping, cls: "bg-indigo-400" },
        { count: stats.waiting, cls: "bg-violet-400" },
    ].filter((s) => s.count > 0);

    // Legend is intentionally omitted — the StatePill filter bar below shows
    // the same counts and doubles as the click-to-filter control.
    return (
        <div className="flex h-1.5 w-full overflow-hidden rounded-full bg-muted">
            {segments.map((seg, i) => (
                <div
                    key={i}
                    className={`${seg.cls} opacity-80`}
                    style={{ width: `${(seg.count / total) * 100}%` }}
                />
            ))}
        </div>
    );
}

export function QueueDetailPage() {
    const { queue } = useParams({ strict: false }) as { queue: string };
    const namespace = getStoredNamespace();
    usePageTitle(queue);

    const qc = useQueryClient();
    const [stateFilter, setStateFilter] = useState<string | undefined>(
        undefined,
    );
    const [cursor, setCursor] = useState<string | undefined>(undefined);
    const [history, setHistory] = useState<string[]>([]);
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    // ── Queue detail (stats + paused) ───────────────────────────────────────
    // Queue detail always shows root tasks only — child activities are spawned
    // automatically by workflows and are not the primary concern of this view.
    const { data: queueData } = useQuery({
        queryKey: qk.queues.detail(namespace, queue),
        queryFn: () => getQueue(namespace, queue, { rootOnly: true }),
        refetchInterval: intervalMs,
    });

    const pauseMut = useMutation({
        mutationFn: () => pauseQueue(namespace, queue),
        onSuccess: () =>
            qc.invalidateQueries({
                queryKey: qk.queues.detail(namespace, queue),
            }),
    });

    const resumeMut = useMutation({
        mutationFn: () => resumeQueue(namespace, queue),
        onSuccess: () =>
            qc.invalidateQueries({
                queryKey: qk.queues.detail(namespace, queue),
            }),
    });

    // ── Task list ────────────────────────────────────────────────────────────
    const { data, isLoading, error } = useQuery({
        queryKey: qk.tasks.list(namespace, queue, stateFilter, cursor),
        queryFn: () =>
            getTasks(namespace, queue, {
                state: stateFilter,
                cursor,
                limit: 50,
                rootOnly: true,
            }),
        refetchInterval: intervalMs,
    });

    function goNext() {
        if (!data?.nextCursor) return;
        setHistory((h) => [...h, cursor ?? ""]);
        setCursor(data.nextCursor ?? undefined);
    }
    function goPrev() {
        const prev = history[history.length - 1];
        setHistory((h) => h.slice(0, -1));
        setCursor(prev || undefined);
    }

    return (
        <div className="px-6 py-6">
            {/* Header */}
            <div className="flex items-center justify-between mb-5">
                <div className="flex items-center gap-3">
                    <Link to={`/${namespace}/queues` as never}>
                        <button className="text-muted-foreground hover:text-foreground transition-colors">
                            <ArrowLeft size={16} />
                        </button>
                    </Link>
                    <h1 className="text-lg font-semibold font-mono text-foreground">
                        {queue}
                    </h1>
                </div>
                <div className="flex items-center gap-2">
                    <AutoRefreshControl
                        intervalMs={intervalMs}
                        setIntervalMs={setIntervalMs}
                    />
                    <Link to={`/${namespace}/events` as never}>
                        <Button variant="outline" size="sm">
                            <CalendarClock size={14} /> Events
                        </Button>
                    </Link>
                </div>
            </div>

            {/* Stats card */}
            {queueData && (
                <div className="rounded-lg border border-border bg-card/40 p-4 mb-5">
                    {/* Card header: name + paused badge + pause/resume button */}
                    <div className="flex items-center justify-between mb-3">
                        <div className="flex items-center gap-2">
                            <span className="font-medium font-mono text-sm text-foreground">
                                {queueData.name}
                            </span>
                            {queueData.isPaused && (
                                <span className="inline-flex items-center rounded border px-1.5 py-0.5 text-[10px] font-medium bg-yellow-500/15 text-yellow-300 border-yellow-500/25">
                                    Paused
                                </span>
                            )}
                        </div>

                        {queueData.isPaused ? (
                            <button
                                onClick={() => resumeMut.mutate()}
                                disabled={resumeMut.isPending}
                                title="Resume queue"
                                className="inline-flex items-center gap-1 rounded border border-green-500/30 bg-green-500/10 px-2 py-0.5 text-[11px] font-medium text-green-300 hover:bg-green-500/20 transition-colors disabled:opacity-40"
                            >
                                <Play size={10} />
                                Resume
                            </button>
                        ) : (
                            <button
                                onClick={() => pauseMut.mutate()}
                                disabled={pauseMut.isPending}
                                title="Pause queue"
                                className="inline-flex items-center gap-1 rounded border border-border px-2 py-0.5 text-[11px] font-medium text-muted-foreground hover:text-foreground hover:border-border/80 transition-colors disabled:opacity-40"
                            >
                                <Pause size={10} />
                                Pause
                            </button>
                        )}
                    </div>

                    {/* Stacked bar + legend */}
                    <QueueBar stats={queueData.stats} />
                </div>
            )}

            {/* Filter bar: state pills with live counts from queueData.stats */}
            <div className="flex gap-1.5 mb-4 flex-wrap items-center">
                {/* All */}
                <StatePill
                    label="All"
                    count={0}
                    active={stateFilter === undefined}
                    accent=""
                    onClick={() => {
                        setStateFilter(undefined);
                        setCursor(undefined);
                        setHistory([]);
                    }}
                />

                {/* Per-state pills with counts from queueData.stats */}
                {STATE_CONFIG.map(({ state, countFn, accent }) => (
                    <StatePill
                        key={state}
                        label={state}
                        count={queueData ? countFn(queueData.stats) : 0}
                        active={stateFilter === state}
                        accent={accent}
                        onClick={() => {
                            setStateFilter(
                                stateFilter === state ? undefined : state,
                            );
                            setCursor(undefined);
                            setHistory([]);
                        }}
                    />
                ))}
            </div>

            {/* Table */}
            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}
            {data && (
                <>
                    <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-sm">
                            <thead>
                                <tr className="border-b border-border bg-secondary/30">
                                    <th className="text-left px-4 py-2.5 text-xs font-medium text-muted-foreground">
                                        Name
                                    </th>
                                    <th className="text-left px-4 py-2.5 text-xs font-medium text-muted-foreground">
                                        State
                                    </th>
                                    <th className="text-left px-4 py-2.5 text-xs font-medium text-muted-foreground">
                                        Attempt
                                    </th>
                                    <th className="text-left px-4 py-2.5 text-xs font-medium text-muted-foreground">
                                        Created
                                    </th>
                                    <th className="text-left px-4 py-2.5 text-xs font-medium text-muted-foreground">
                                        Finished
                                    </th>
                                </tr>
                            </thead>
                            <tbody>
                                {data.items.length === 0 && (
                                    <tr>
                                        <td
                                            colSpan={5}
                                            className="px-4 py-10 text-center text-sm text-muted-foreground"
                                        >
                                            No tasks found.
                                        </td>
                                    </tr>
                                )}
                                {data.items.map((task: TaskSummary) => (
                                    <tr
                                        key={task.id}
                                        className="border-b border-border/50 last:border-0 hover:bg-secondary/20 transition-colors"
                                    >
                                        <td className="px-4 py-3">
                                            <Link
                                                to="/$namespace/tasks/$taskId"
                                                params={{
                                                    namespace,
                                                    taskId: task.id,
                                                }}
                                                search={{ queue }}
                                                className="font-medium text-foreground hover:text-brand transition-colors"
                                            >
                                                {task.name}
                                            </Link>
                                        </td>
                                        <td className="px-4 py-3">
                                            <StatusBadge
                                                state={task.state as TaskStatus}
                                            />
                                        </td>
                                        <td className="px-4 py-3 text-muted-foreground text-sm">
                                            {task.attempt}
                                        </td>
                                        <td className="px-4 py-3">
                                            <RelativeTime
                                                iso={task.createdAt}
                                            />
                                        </td>
                                        <td className="px-4 py-3">
                                            <RelativeTime
                                                iso={task.completedAt}
                                            />
                                        </td>
                                    </tr>
                                ))}
                            </tbody>
                        </table>
                    </div>
                    <Paginator
                        hasNext={!!data.nextCursor}
                        hasPrev={history.length > 0}
                        onNext={goNext}
                        onPrev={goPrev}
                    />
                </>
            )}
        </div>
    );
}
