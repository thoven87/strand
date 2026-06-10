import { useState, useMemo } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { useQuery, keepPreviousData } from "@tanstack/react-query";
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
import { Search, X, Copy, Check } from "lucide-react";
import type { TaskSummary, TaskKind, TaskState, QueueStats } from "@/api/types";
import { EmptyState } from "@/components/EmptyState";
import { fmtDuration } from "@/lib/utils";

// ── helpers ────────────────────────────────────────────────────────────────

function CopyIDButton({ id }: { id: string }) {
    const [copied, setCopied] = useState(false);
    return (
        <button
            onClick={(e) => {
                e.preventDefault();
                e.stopPropagation();
                void navigator.clipboard.writeText(id).then(() => {
                    setCopied(true);
                    setTimeout(() => setCopied(false), 2_000);
                });
            }}
            title="Copy task ID"
            className="opacity-0 group-hover/row:opacity-100 ml-1 text-muted-foreground/40 hover:text-muted-foreground transition-opacity"
        >
            {copied ? <Check size={10} /> : <Copy size={10} />}
        </button>
    );
}

const ZERO_STATS: QueueStats = {
    pending: 0,
    running: 0,
    sleeping: 0,
    waiting: 0,
    failedRecent: 0,
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
// countKey maps a filter state to the matching field on QueueStats.
// COMPLETED and CANCELLED are null because they were removed from QueueStats
// (counting all-time terminal tasks requires a full table scan).
// The filter pills still work for those states; they just show no live count.
const STATE_CONFIG: ReadonlyArray<{
    state: string;
    countKey: keyof import("@/api/types").QueueStats | null;
    accent: string;
}> = [
    {
        state: "RUNNING",
        countKey: "running",
        accent: "bg-yellow-500/20 text-yellow-300",
    },
    {
        state: "PENDING",
        countKey: "pending",
        accent: "bg-blue-500/15   text-blue-400",
    },
    {
        state: "SLEEPING",
        countKey: "sleeping",
        accent: "bg-slate-500/20  text-slate-300",
    },
    {
        state: "WAITING",
        countKey: "waiting",
        accent: "bg-violet-500/20 text-violet-300",
    },
    {
        state: "COMPLETED",
        countKey: null,
        accent: "bg-green-500/15  text-green-400",
    },
    {
        state: "FAILED",
        countKey: "failedRecent",
        accent: "bg-red-500/20    text-red-400",
    },
    {
        state: "CANCELLED",
        countKey: null,
        accent: "bg-slate-500/15  text-slate-400",
    },
];

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

export function RunsPage() {
    usePageTitle("Runs");
    const { namespace } = useParams({ strict: false }) as { namespace: string };

    // ── All filters live in the URL ──────────────────────────────────────────────────
    const search = useSearch({ strict: false }) as {
        queue?: string;
        state?: string;
        kind?: string;
        name?: string;
        /** Backfill UUID — when set, list shows only tasks created by this backfill. */
        backfillId?: string;
        /** Schedule UUID — filter by idempotency-key prefix `$schedule:<id>:`.
         *  Used by backfill task list for pre-existing tasks (allowOverwrite=false). */
        scheduleId?: string;
    };
    const navigate = useNavigate();

    const selectedQueue = search.queue ?? "";
    const stateFilter = search.state;
    const kindFilter = search.kind as TaskKind | undefined;
    const nameFilter = search.name ?? "";
    const backfillIdFilter = search.backfillId;
    const scheduleIdFilter = search.scheduleId;

    // Pagination is local state — it resets on any filter change
    const [cursor, setCursor] = useState<string | undefined>(undefined);
    const [history, setHistory] = useState<string[]>([]);
    const [rootOnly, setRootOnly] = useState(true); // default true: hides child activities
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    function setFilters(updates: Record<string, string | undefined>) {
        setCursor(undefined);
        setHistory([]);
        void navigate({
            to: "/$namespace/runs",
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
            to: "/$namespace/runs",
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
        queryKey: [...qk.queues.list(namespace), rootOnly],
        queryFn: () =>
            getQueues(namespace, { rootOnly: rootOnly || undefined }),
        refetchInterval: intervalMs,
    });

    const isBackfillScoped = !!(backfillIdFilter || scheduleIdFilter);

    const { data, isLoading, error } = useQuery({
        queryKey: [
            "tasks-global",
            namespace,
            selectedQueue,
            stateFilter,
            kindFilter,
            nameFilter,
            rootOnly,
            backfillIdFilter,
            scheduleIdFilter,
            cursor,
        ],
        queryFn: () =>
            getTasksGlobal(namespace, {
                queue: selectedQueue || undefined,
                state: stateFilter,
                kind: kindFilter,
                name: nameFilter || undefined,
                // Disable rootOnly when scoped to a backfill/schedule so child
                // activities spawned by backfill workflows are also visible.
                rootOnly: isBackfillScoped
                    ? undefined
                    : rootOnly
                      ? true
                      : undefined,
                backfillId: backfillIdFilter,
                scheduleId: scheduleIdFilter,
                cursor,
                limit: 50,
            }),
        placeholderData: keepPreviousData,
        refetchInterval:
            intervalMs === false
                ? false
                : (q) => {
                      const items = q.state.data?.items;
                      const hasActive = items?.some(
                          (t) =>
                              t.state === "RUNNING" ||
                              t.state === "PENDING" ||
                              t.state === "SLEEPING",
                      );
                      return hasActive
                          ? Math.min(intervalMs, 4_000)
                          : intervalMs;
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
                waiting: acc.waiting + q.stats.waiting,
                failedRecent: acc.failedRecent + q.stats.failedRecent,
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
            {/* Backfill context banner — shown when navigated from a backfill row */}
            {isBackfillScoped && (
                <div className="rounded-lg border border-blue-500/25 bg-blue-500/8 px-4 py-2.5 flex items-center justify-between">
                    <div className="flex items-center gap-2">
                        <span className="text-[10px] font-mono text-blue-400/70 bg-blue-500/15 border border-blue-500/20 rounded px-1.5 py-0.5">
                            {scheduleIdFilter ? "SCHEDULE" : "BACKFILL"}
                        </span>
                        <span className="text-xs text-muted-foreground font-mono truncate max-w-xs">
                            {scheduleIdFilter ?? backfillIdFilter}
                        </span>
                    </div>
                    <button
                        onClick={() =>
                            navigate({
                                to: "/$namespace/runs",
                                params: { namespace },
                                search: {
                                    queue: selectedQueue || undefined,
                                    name: nameFilter || undefined,
                                },
                                replace: true,
                            })
                        }
                        className="text-[11px] text-muted-foreground hover:text-foreground transition-colors shrink-0 ml-4"
                    >
                        Clear filter ×
                    </button>
                </div>
            )}

            {/* ── Header row: title + queue selector + name search ────────────── */}
            <div className="flex items-center gap-3 flex-wrap">
                <h1 className="text-base font-semibold text-foreground mr-auto">
                    Runs
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

                <AutoRefreshControl
                    intervalMs={intervalMs}
                    setIntervalMs={setIntervalMs}
                />
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
                        count={countKey != null ? stateCounts[countKey] : 0}
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

                {/* Root only toggle — lives next to state filters, not kind filters */}
                <button
                    onClick={() => {
                        setRootOnly((v) => !v);
                        setCursor(undefined);
                    }}
                    className={`inline-flex items-center gap-1.5 rounded border px-2.5 py-1 text-xs font-medium transition-colors ${
                        rootOnly
                            ? "bg-brand/15 text-brand border-brand/30"
                            : "border-border text-muted-foreground hover:text-foreground"
                    }`}
                    title="Hide child activities spawned by workflows"
                >
                    Root only
                </button>

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
                                        "Schedule",
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
                                    data.items.map(
                                        (task: TaskSummary, index) => {
                                            const durationMs =
                                                task.completedAt &&
                                                task.firstRunAt
                                                    ? new Date(
                                                          task.completedAt,
                                                      ).getTime() -
                                                      new Date(
                                                          task.firstRunAt,
                                                      ).getTime()
                                                    : null;

                                            return (
                                                <tr
                                                    key={task.id}
                                                    className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors group/row"
                                                >
                                                    <td className="px-4 py-2.5">
                                                        <div className="flex items-center gap-1">
                                                            <Link
                                                                to="/$namespace/tasks/$taskId"
                                                                params={{
                                                                    namespace,
                                                                    taskId: task.id,
                                                                }}
                                                                search={{
                                                                    queue: task.queue,
                                                                    ...(index >
                                                                    0
                                                                        ? {
                                                                              prevId: data
                                                                                  .items[
                                                                                  index -
                                                                                      1
                                                                              ]
                                                                                  .id,
                                                                          }
                                                                        : {}),
                                                                    ...(index <
                                                                    data.items
                                                                        .length -
                                                                        1
                                                                        ? {
                                                                              nextId: data
                                                                                  .items[
                                                                                  index +
                                                                                      1
                                                                              ]
                                                                                  .id,
                                                                          }
                                                                        : {}),
                                                                }}
                                                                className="group block"
                                                            >
                                                                <span className="font-medium text-foreground group-hover:text-brand transition-colors">
                                                                    {task.name}
                                                                </span>
                                                                <span className="block font-mono text-[10px] text-muted-foreground/50 mt-0.5">
                                                                    {task.workflowId ??
                                                                        task.id.split(
                                                                            "-",
                                                                        )[0]}
                                                                </span>
                                                            </Link>
                                                            <CopyIDButton
                                                                id={task.id}
                                                            />
                                                        </div>
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
                                                            iso={
                                                                task.completedAt
                                                            }
                                                        />
                                                    </td>
                                                    <td className="px-4 py-2.5 text-xs text-muted-foreground tabular-nums">
                                                        {durationMs !== null ? (
                                                            fmtDuration(
                                                                durationMs,
                                                            )
                                                        ) : task.state ===
                                                              "RUNNING" &&
                                                          task.firstRunAt ? (
                                                            <LiveTimer
                                                                startIso={
                                                                    task.firstRunAt
                                                                }
                                                                className="text-green-400 tabular-nums"
                                                            />
                                                        ) : task.state ===
                                                              "PENDING" ||
                                                          task.state ===
                                                              "WAITING" ||
                                                          task.state ===
                                                              "SLEEPING" ? (
                                                            <span className="text-muted-foreground/60 text-[10px]">
                                                                queued{" "}
                                                                <RelativeTime
                                                                    iso={
                                                                        task.createdAt
                                                                    }
                                                                />
                                                            </span>
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
                                        },
                                    )
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
