import { useState, useMemo } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import { useQuery } from "@tanstack/react-query";
import {
    Link,
    useNavigate,
    useParams,
    useSearch,
} from "@tanstack/react-router";
import { getQueues } from "@/api/queues";
import { getTasksGlobal } from "@/api/tasks";
import { qk } from "@/lib/queryKeys";
import { StatusBadge } from "@/components/ui/badge";
import { RelativeTime } from "@/components/RelativeTime";
import { LiveTimer } from "@/components/LiveTimer";
import { Paginator } from "@/components/Paginator";
import { Select } from "@/components/ui/select";
import { Search, X } from "lucide-react";
import type { TaskSummary, TaskKind, TaskState, QueueStats } from "@/api/types";
import { EmptyState } from "@/components/EmptyState";

// ── helpers ────────────────────────────────────────────────────────────────

function fmtDuration(ms: number): string {
    if (ms < 1_000) return `${ms}ms`;
    if (ms < 60_000) return `${(ms / 1_000).toFixed(1)}s`;
    const m = Math.floor(ms / 60_000);
    const s = Math.floor((ms % 60_000) / 1_000);
    return s > 0 ? `${m}m ${s}s` : `${m}m`;
}

const ZERO_STATS: QueueStats = {
    pending: 0,
    running: 0,
    sleeping: 0,
    completed: 0,
    failed: 0,
    cancelled: 0,
};

// ── sub-components ─────────────────────────────────────────────────────────

function TriggerBadge({ scheduleName }: { scheduleName: string | null }) {
    if (scheduleName)
        return (
            <span
                className="inline-flex items-center gap-1 text-[10px] font-medium text-sky-400"
                title={`Schedule: ${scheduleName}`}
            >
                ⏱ {scheduleName}
            </span>
        );
    return <span className="text-[11px] text-muted-foreground/50">—</span>;
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

const KINDS: { label: string; value: TaskKind | undefined }[] = [
    { label: "All", value: undefined },
    { label: "Workflows", value: "WORKFLOW" },
    { label: "Activities", value: "ACTIVITY" },
];

// State config: label, count key, accent colour classes for the count badge
const STATE_CONFIG = [
    {
        state: "RUNNING",
        countKey: "running" as const,
        accent: "bg-yellow-500/20 text-yellow-300",
    },
    {
        state: "PENDING",
        countKey: "pending" as const,
        accent: "bg-blue-500/15   text-blue-400",
    },
    {
        state: "SLEEPING",
        countKey: "sleeping" as const,
        accent: "bg-slate-500/20  text-slate-300",
    },
    {
        state: "COMPLETED",
        countKey: "completed" as const,
        accent: "bg-green-500/15  text-green-400",
    },
    {
        state: "FAILED",
        countKey: "failed" as const,
        accent: "bg-red-500/20    text-red-400",
    },
    {
        state: "CANCELLED",
        countKey: "cancelled" as const,
        accent: "bg-slate-500/15  text-slate-400",
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
            {label.charAt(0) + label.slice(1).toLowerCase()}
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

function KindPill({
    label,
    active,
    onClick,
}: {
    label: string;
    active: boolean;
    onClick: () => void;
}) {
    return (
        <button
            onClick={onClick}
            className={`px-2.5 py-1 rounded text-xs font-medium transition-colors ${
                active
                    ? "bg-secondary text-foreground"
                    : "text-muted-foreground hover:text-foreground hover:bg-secondary/60"
            }`}
        >
            {label}
        </button>
    );
}

// ── TasksPage ──────────────────────────────────────────────────────────────

export function TasksPage() {
    usePageTitle("Tasks");
    const { namespace } = useParams({ strict: false }) as { namespace: string };

    // ── All filters live in the URL ─────────────────────────────────────────
    const search = useSearch({ strict: false }) as {
        queue?: string;
        state?: string;
        kind?: string;
        name?: string;
    };
    const navigate = useNavigate();

    const selectedQueue = search.queue ?? "";
    const stateFilter = search.state;
    const kindFilter = search.kind as TaskKind | undefined;
    const nameFilter = search.name ?? "";

    // Pagination is local state — it resets on any filter change
    const [cursor, setCursor] = useState<string | undefined>(undefined);
    const [history, setHistory] = useState<string[]>([]);

    function setFilters(updates: Record<string, string | undefined>) {
        setCursor(undefined);
        setHistory([]);
        void navigate({
            to: "/$namespace/tasks",
            params: { namespace },
            search: (prev) => {
                const next = { ...prev, ...updates };
                // Remove undefined/empty keys so URLs stay clean
                Object.keys(next).forEach(
                    (k) =>
                        (next[k as keyof typeof next] === undefined ||
                            next[k as keyof typeof next] === "") &&
                        delete next[k as keyof typeof next],
                );
                return next;
            },
            replace: true,
        });
    }

    function clearAllFilters() {
        setCursor(undefined);
        setHistory([]);
        void navigate({
            to: "/$namespace/tasks",
            params: { namespace },
            search: {},
            replace: true,
        });
    }

    const hasActiveFilters = !!(
        stateFilter ||
        kindFilter ||
        nameFilter ||
        selectedQueue
    );

    // ── Data fetching ──────────────────────────────────────────────────────
    const { data: queues = [] } = useQuery({
        queryKey: qk.queues.list(namespace),
        queryFn: () => getQueues(namespace),
        refetchInterval: 10_000,
    });

    const { data, isLoading, error } = useQuery({
        queryKey: [
            "tasks-global",
            namespace,
            selectedQueue,
            stateFilter,
            kindFilter,
            nameFilter,
            cursor,
        ],
        queryFn: () =>
            getTasksGlobal(namespace, {
                queue: selectedQueue || undefined,
                state: stateFilter,
                kind: kindFilter,
                name: nameFilter || undefined,
                cursor,
                limit: 50,
            }),
        refetchInterval: (q) => {
            const items = q.state.data?.items;
            const hasActive = items?.some(
                (t) =>
                    t.state === "RUNNING" ||
                    t.state === "PENDING" ||
                    t.state === "SLEEPING",
            );
            return hasActive ? 4_000 : 15_000;
        },
    });

    // ── Derive per-state counts from queue stats ────────────────────────────
    // When a queue is selected, use that queue's stats; otherwise sum all queues.
    const stateCounts = useMemo<QueueStats>(() => {
        if (queues.length === 0) return ZERO_STATS;
        if (selectedQueue) {
            const q = queues.find((q) => q.name === selectedQueue);
            return q?.stats ?? ZERO_STATS;
        }
        return queues.reduce(
            (acc, q) => ({
                pending: acc.pending + q.stats.pending,
                running: acc.running + q.stats.running,
                sleeping: acc.sleeping + q.stats.sleeping,
                completed: acc.completed + q.stats.completed,
                failed: acc.failed + q.stats.failed,
                cancelled: acc.cancelled + q.stats.cancelled,
            }),
            { ...ZERO_STATS },
        );
    }, [queues, selectedQueue]);

    // ── Pagination helpers ─────────────────────────────────────────────────
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

    // ── Render ─────────────────────────────────────────────────────────────
    return (
        <div className="px-6 py-5 space-y-4">
            {/* ── Header row: title + queue selector + name search ────────── */}
            <div className="flex items-center gap-3 flex-wrap">
                <h1 className="text-base font-semibold text-foreground mr-auto">
                    Tasks
                </h1>

                {/* Name search */}
                <div className="relative">
                    <Search
                        size={13}
                        className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none"
                    />
                    <input
                        type="search"
                        placeholder="Search by name…"
                        value={nameFilter}
                        onChange={(e) =>
                            setFilters({ name: e.target.value || undefined })
                        }
                        className="pl-7 pr-3 py-1.5 rounded border border-border bg-secondary/30 text-foreground text-xs w-44 focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/50"
                    />
                </div>

                {/* Queue selector */}
                <Select
                    value={selectedQueue}
                    onChange={(e) =>
                        setFilters({ queue: e.target.value || undefined })
                    }
                >
                    <option value="">All queues</option>
                    {queues.map((q) => (
                        <option key={q.name} value={q.name}>
                            {q.name}
                        </option>
                    ))}
                </Select>
            </div>

            {/* ── Filter bar: kind pills + state-count badges ───────────────── */}
            <div className="flex flex-wrap items-center gap-x-3 gap-y-2">
                {/* Kind pills */}
                <div className="flex gap-1">
                    {KINDS.map(({ label, value }) => (
                        <KindPill
                            key={label}
                            label={label}
                            active={kindFilter === value}
                            onClick={() => setFilters({ kind: value })}
                        />
                    ))}
                </div>

                <div className="h-4 w-px bg-border/50 hidden sm:block" />

                {/* "All states" pill */}
                <KindPill
                    label="All states"
                    active={stateFilter === undefined}
                    onClick={() => setFilters({ state: undefined })}
                />

                {/* Per-state count badges */}
                {STATE_CONFIG.map(({ state, countKey, accent }) => (
                    <StatePill
                        key={state}
                        label={state}
                        count={stateCounts[countKey]}
                        active={stateFilter === state}
                        accent={accent}
                        onClick={() =>
                            setFilters({
                                state:
                                    stateFilter === state ? undefined : state,
                            })
                        }
                    />
                ))}

                {/* Clear-all indicator */}
                {hasActiveFilters && (
                    <button
                        onClick={clearAllFilters}
                        className="ml-1 flex items-center gap-1 text-[11px] text-muted-foreground hover:text-foreground transition-colors"
                        title="Clear all filters"
                    >
                        <X size={12} /> Clear
                    </button>
                )}
            </div>

            {/* ── Table ─────────────────────────────────────────────────────── */}
            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {data && (
                <>
                    <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-sm">
                            <thead>
                                <tr className="border-b border-border bg-secondary/20">
                                    {[
                                        "Name",
                                        "Queue",
                                        "State",
                                        "Trigger",
                                        "Attempt",
                                        "Created",
                                        "Finished",
                                        "Duration",
                                        "Kind",
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
                                {data.items.length === 0 ? (
                                    <tr>
                                        <td colSpan={9} className="p-4">
                                            {hasActiveFilters ? (
                                                <EmptyState
                                                    variant="tasks"
                                                    title="No tasks match these filters"
                                                    action={
                                                        <button
                                                            onClick={
                                                                clearAllFilters
                                                            }
                                                            className="text-xs text-brand hover:underline"
                                                        >
                                                            Clear filters
                                                        </button>
                                                    }
                                                />
                                            ) : (
                                                <EmptyState
                                                    variant="tasks"
                                                    title="No tasks yet"
                                                    description="Enqueue a workflow or activity to see it here."
                                                />
                                            )}
                                        </td>
                                    </tr>
                                ) : (
                                    data.items.map((task: TaskSummary) => {
                                        const isActive =
                                            task.state === "RUNNING" ||
                                            task.state === "SLEEPING";
                                        const durationMs =
                                            task.completedAt && task.createdAt
                                                ? new Date(
                                                      task.completedAt,
                                                  ).getTime() -
                                                  new Date(
                                                      task.createdAt,
                                                  ).getTime()
                                                : null;

                                        return (
                                            <tr
                                                key={task.id}
                                                className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                            >
                                                <td className="px-4 py-2.5">
                                                    <Link
                                                        to="/$namespace/tasks/$taskId"
                                                        params={{
                                                            namespace,
                                                            taskId: task.id,
                                                        }}
                                                        search={{
                                                            queue: task.queue,
                                                        }}
                                                        className="font-medium text-foreground hover:text-brand transition-colors"
                                                    >
                                                        {task.name}
                                                    </Link>
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <span className="font-mono text-xs text-muted-foreground">
                                                        {task.queue}
                                                    </span>
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <StatusBadge
                                                        state={
                                                            task.state as TaskState
                                                        }
                                                    />
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <TriggerBadge
                                                        scheduleName={
                                                            task.scheduleName
                                                        }
                                                    />
                                                </td>
                                                <td className="px-4 py-2.5 text-muted-foreground">
                                                    {task.attempt}
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <RelativeTime
                                                        iso={task.createdAt}
                                                    />
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <RelativeTime
                                                        iso={task.completedAt}
                                                    />
                                                </td>
                                                <td className="px-4 py-2.5 text-xs text-muted-foreground tabular-nums">
                                                    {durationMs !== null ? (
                                                        fmtDuration(durationMs)
                                                    ) : isActive ? (
                                                        <LiveTimer
                                                            startIso={
                                                                task.createdAt
                                                            }
                                                            className="text-muted-foreground tabular-nums"
                                                        />
                                                    ) : (
                                                        "—"
                                                    )}
                                                </td>
                                                <td className="px-4 py-2.5">
                                                    <KindBadge
                                                        kind={task.kind}
                                                    />
                                                </td>
                                            </tr>
                                        );
                                    })
                                )}
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
