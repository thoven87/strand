import { useState } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import {
    useQuery,
    useMutation,
    useQueryClient,
    keepPreviousData,
} from "@tanstack/react-query";
import {
    Link,
    useNavigate,
    useParams,
    useSearch,
} from "@tanstack/react-router";
import { getTask, cancelTask, requeueTask, getTaskTrace } from "@/api/tasks";
import { TraceTree } from "@/components/TraceTree";
import { RetryDialog } from "@/components/RetryDialog";
import { StatusBadge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { RelativeTime } from "@/components/RelativeTime";
import { qk } from "@/lib/queryKeys";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { ArrowLeft, RefreshCw, XCircle, GitBranch } from "lucide-react";
import type { RetryOptions, TaskState } from "@/api/types";

// ── helpers ───────────────────────────────────────────────────────────────

const isTerminal = (s: TaskState) =>
    s === "COMPLETED" ||
    s === "FAILED" ||
    s === "CANCELLED" ||
    s === "CONTINUED_AS_NEW";

// ── TaskTracePage ──────────────────────────────────────────────────────────

export function TaskTracePage() {
    const { taskId, namespace } = useParams({ strict: false }) as {
        taskId: string;
        namespace: string;
    };
    const search = useSearch({ strict: false }) as { queue?: string };
    const queue = search.queue ?? "";
    const qc = useQueryClient();
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    // Fetch task metadata for the header bar.
    const { data: task } = useQuery({
        queryKey: qk.tasks.detail(namespace, queue, taskId),
        queryFn: () => getTask(namespace, queue, taskId),
        refetchInterval: (q) => {
            const d = q.state.data;
            return d && isTerminal(d.state) ? intervalMs : 3_000;
        },
    });
    usePageTitle(`Trace · ${task?.name ?? "\u2026"}`);

    // Fetch the trace spans from the backend.
    const { data: traceSpans, isLoading: traceLoading } = useQuery({
        queryKey: qk.tasks.trace(namespace, taskId),
        queryFn: () => getTaskTrace(namespace, taskId),
        refetchInterval: task && isTerminal(task.state) ? intervalMs : 5_000,
        placeholderData: keepPreviousData,
    });

    const [retryDialogOpen, setRetryDialogOpen] = useState(false);
    const cancelMutation = useMutation({
        mutationFn: () => cancelTask(namespace, queue, taskId),
        onSuccess: () => {
            qc.invalidateQueries({
                queryKey: qk.tasks.detail(namespace, queue, taskId),
            });
            qc.invalidateQueries({
                queryKey: qk.tasks.trace(namespace, taskId),
            });
        },
    });

    const requeueMutation = useMutation({
        mutationFn: (opts: RetryOptions) =>
            requeueTask(namespace, queue, taskId, opts),
        onSuccess: (data) => {
            setRetryDialogOpen(false);
            if (data.taskID.toLowerCase() !== taskId.toLowerCase()) {
                // reRunTask created a brand-new task — navigate to its trace so the
                // user sees the fresh execution, not the old completed one.
                navigate({
                    to: "/$namespace/tasks/$taskId/trace",
                    params: { namespace, taskId: data.taskID },
                    search: queue ? { queue } : {},
                });
            } else {
                // retryTask reused the same task ID — refresh in place.
                qc.invalidateQueries({
                    queryKey: qk.tasks.detail(namespace, queue, taskId),
                });
                qc.invalidateQueries({
                    queryKey: qk.tasks.trace(namespace, taskId),
                });
            }
        },
    });

    const navigate = useNavigate();
    const handleViewTask = (spanTaskId: string) => {
        navigate({
            to: "/$namespace/tasks/$taskId",
            params: { namespace, taskId: spanTaskId },
            search: queue ? { queue } : {},
        });
    };

    const handleViewEmission = (emissionId: string) => {
        // Copy emission ID to clipboard so the user can paste it into the
        // events page search — there is no direct permalink per emission yet.
        void navigator.clipboard.writeText(emissionId).catch(() => undefined);
        void navigate({ to: "/$namespace/events", params: { namespace } });
    };

    const terminal = task ? isTerminal(task.state) : false;
    const rootDurationMs = traceSpans?.[0]?.durationMs ?? 1_000;

    return (
        // h-full fills the Shell's <main> area; overflow-hidden keeps the tree
        // from causing page-level scrolling — the TraceTree scrolls internally.
        <div className="flex flex-col h-full overflow-hidden">
            {/* ── Header bar ────────────────────────────────────────────────── */}
            <div className="shrink-0 border-b border-border bg-card/40 px-4 py-2.5 flex items-center gap-3 min-w-0">
                {/* Back → task detail */}
                <Link
                    to="/$namespace/tasks/$taskId"
                    params={{ namespace, taskId }}
                    search={queue ? { queue } : {}}
                    className="flex items-center gap-1.5 text-xs text-muted-foreground hover:text-foreground transition-colors shrink-0"
                >
                    <ArrowLeft size={13} />
                    <span className="font-mono truncate max-w-[180px]">
                        {task?.name ?? "…"}
                    </span>
                </Link>

                <span className="text-muted-foreground/40 shrink-0">·</span>

                <GitBranch
                    size={13}
                    className="text-muted-foreground shrink-0"
                />
                <span className="text-xs font-semibold text-foreground shrink-0">
                    Trace
                </span>

                {task && <StatusBadge state={task.state as TaskState} />}

                {task && (
                    <span className="text-xs text-muted-foreground hidden sm:block">
                        Created <RelativeTime iso={task.createdAt} />
                    </span>
                )}

                {/* Actions pushed to the right */}
                <div className="ml-auto flex items-center gap-2 shrink-0">
                    <AutoRefreshControl
                        intervalMs={intervalMs}
                        setIntervalMs={setIntervalMs}
                    />
                    {task && !terminal && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => cancelMutation.mutate()}
                            disabled={cancelMutation.isPending}
                        >
                            <XCircle size={13} /> Cancel
                        </Button>
                    )}
                    {task && terminal && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setRetryDialogOpen(true)}
                            disabled={requeueMutation.isPending}
                            title={
                                task.state === "COMPLETED"
                                    ? "Re-run this workflow from scratch"
                                    : "Retry the failed run"
                            }
                        >
                            <RefreshCw size={13} />
                            {task.state === "COMPLETED" ? "Re-run" : "Retry"}
                        </Button>
                    )}
                </div>
            </div>

            {/* ── Trace body ─────────────────────────────────────────────────── */}
            {/* flex-1 + min-h-0 lets the view fill all remaining height without
          overflowing — min-h-0 overrides the default flex min-height:auto  */}
            <div className="flex-1 min-h-0 p-4">
                {traceLoading && !traceSpans && (
                    <div className="flex items-center justify-center h-full">
                        <p className="text-sm text-muted-foreground">
                            Loading trace…
                        </p>
                    </div>
                )}

                {!traceLoading && (!traceSpans || traceSpans.length === 0) && (
                    <div className="flex items-center justify-center h-full">
                        <p className="text-sm text-muted-foreground">
                            No trace data yet.
                        </p>
                    </div>
                )}

                {traceSpans && traceSpans.length > 0 && (
                    <TraceTree
                        spans={traceSpans}
                        totalMs={rootDurationMs}
                        isLive={!terminal}
                        traceStartEpochMs={
                            task?.createdAt
                                ? new Date(task.createdAt).getTime()
                                : undefined
                        }
                        className="h-full"
                        onViewTask={handleViewTask}
                        onViewEmission={handleViewEmission}
                        rootSummary={
                            task
                                ? {
                                      name: task.name,
                                      state: task.state,
                                      createdAt: task.createdAt,
                                      startedAt: task.firstRunAt ?? undefined,
                                      completedAt:
                                          task.completedAt ?? undefined,
                                  }
                                : undefined
                        }
                        onLoadSpanDetail={async (spanTaskId) => {
                            try {
                                const t = await getTask(
                                    namespace,
                                    queue || "",
                                    spanTaskId,
                                );
                                return {
                                    input: t.params ?? null,
                                    output: t.result ?? null,
                                };
                            } catch {
                                return { input: null, output: null };
                            }
                        }}
                    />
                )}
            </div>

            {task && (
                <RetryDialog
                    open={retryDialogOpen}
                    onClose={() => setRetryDialogOpen(false)}
                    onConfirm={(opts) => requeueMutation.mutate(opts)}
                    isPending={requeueMutation.isPending}
                    taskState={task.state}
                />
            )}
        </div>
    );
}
