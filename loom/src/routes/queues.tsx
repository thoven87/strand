import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams } from "@tanstack/react-router";
import { getQueues, pauseQueue, resumeQueue } from "@/api/queues";
import { qk } from "@/lib/queryKeys";
import { Pause, Play } from "lucide-react";
import type { Queue } from "@/api/types";
import { EmptyState } from "@/components/EmptyState";

function QueueBar({ stats }: { stats: Queue["stats"] }) {
    const total =
        stats.pending +
        stats.running +
        stats.sleeping +
        stats.completed +
        stats.failed +
        stats.cancelled;

    if (total === 0)
        return (
            <span className="text-xs text-muted-foreground">No tasks yet</span>
        );

    const segments = [
        { count: stats.running, cls: "bg-yellow-400" },
        { count: stats.pending, cls: "bg-blue-400" },
        { count: stats.sleeping, cls: "bg-indigo-400" },
        { count: stats.failed, cls: "bg-red-400" },
        { count: stats.cancelled, cls: "bg-orange-400" },
        { count: stats.completed, cls: "bg-green-400" },
    ].filter((s) => s.count > 0);

    const items = [
        { label: "Running", count: stats.running, dot: "bg-yellow-400" },
        { label: "Pending", count: stats.pending, dot: "bg-blue-400" },
        { label: "Sleeping", count: stats.sleeping, dot: "bg-indigo-400" },
        { label: "Failed", count: stats.failed, dot: "bg-red-400" },
        { label: "Cancelled", count: stats.cancelled, dot: "bg-orange-400" },
        { label: "Completed", count: stats.completed, dot: "bg-green-400" },
    ].filter((i) => i.count > 0);

    return (
        <div className="space-y-2">
            <div className="flex h-1.5 w-full overflow-hidden rounded-full bg-muted">
                {segments.map((seg, i) => (
                    <div
                        key={i}
                        className={`${seg.cls} opacity-80`}
                        style={{ width: `${(seg.count / total) * 100}%` }}
                    />
                ))}
            </div>
            <div className="flex flex-wrap gap-x-4 gap-y-0.5">
                {items.map((i) => (
                    <span
                        key={i.label}
                        className="flex items-center gap-1.5 text-xs text-muted-foreground"
                    >
                        <span
                            className={`size-1.5 rounded-full ${i.dot} opacity-80`}
                        />
                        {i.label}:{" "}
                        <strong className="text-foreground font-medium">
                            {i.count}
                        </strong>
                    </span>
                ))}
            </div>
        </div>
    );
}

export function QueuesPage() {
    usePageTitle("Queues");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const qc = useQueryClient();
    const {
        data: queues = [],
        isLoading,
        error,
    } = useQuery({
        queryKey: qk.queues.list(namespace),
        queryFn: () => getQueues(namespace),
        refetchInterval: 10_000,
    });

    const pauseMut = useMutation({
        mutationFn: (name: string) => pauseQueue(namespace, name),
        onSuccess: () =>
            qc.invalidateQueries({ queryKey: qk.queues.list(namespace) }),
    });

    const resumeMut = useMutation({
        mutationFn: (name: string) => resumeQueue(namespace, name),
        onSuccess: () =>
            qc.invalidateQueries({ queryKey: qk.queues.list(namespace) }),
    });

    return (
        <div className="px-6 py-5">
            <h1 className="text-base font-semibold text-foreground mb-4">
                Queues
            </h1>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}
            {!isLoading && !error && queues.length === 0 && (
                <EmptyState
                    variant="queues"
                    title="No queues yet"
                    description="Enqueue a task to create your first queue."
                />
            )}

            <div className="space-y-2">
                {queues.map((q) => (
                    <div
                        key={q.name}
                        className="rounded-lg border border-border bg-card/40 hover:border-border/80 hover:bg-card/60 transition-all p-4 group"
                    >
                        <div className="flex items-center justify-between mb-3">
                            {/* Name + paused badge */}
                            <div className="flex items-center gap-2">
                                <Link
                                    to="/$namespace/queues/$queue"
                                    params={{ namespace, queue: q.name }}
                                    className="font-medium text-foreground hover:text-brand transition-colors font-mono text-sm"
                                >
                                    {q.name}
                                </Link>
                                {q.isPaused && (
                                    <span className="inline-flex items-center rounded border px-1.5 py-0.5 text-[10px] font-medium bg-yellow-500/15 text-yellow-300 border-yellow-500/25">
                                        Paused
                                    </span>
                                )}
                            </div>

                            {/* Right side: task count + pause/resume button */}
                            <div className="flex items-center gap-3">
                                <span className="text-xs text-muted-foreground">
                                    {(
                                        q.stats.pending +
                                        q.stats.running +
                                        q.stats.sleeping +
                                        q.stats.completed +
                                        q.stats.failed +
                                        q.stats.cancelled
                                    ).toLocaleString()}{" "}
                                    tasks
                                </span>
                                {q.isPaused ? (
                                    <button
                                        onClick={(e) => {
                                            e.preventDefault();
                                            resumeMut.mutate(q.name);
                                        }}
                                        disabled={resumeMut.isPending}
                                        title="Resume queue"
                                        className="inline-flex items-center gap-1 rounded border border-green-500/30 bg-green-500/10 px-2 py-0.5 text-[11px] font-medium text-green-300 hover:bg-green-500/20 transition-colors disabled:opacity-40"
                                    >
                                        <Play size={10} />
                                        Resume
                                    </button>
                                ) : (
                                    <button
                                        onClick={(e) => {
                                            e.preventDefault();
                                            pauseMut.mutate(q.name);
                                        }}
                                        disabled={pauseMut.isPending}
                                        title="Pause queue"
                                        className="inline-flex items-center gap-1 rounded border border-border px-2 py-0.5 text-[11px] font-medium text-muted-foreground hover:text-foreground hover:border-border/80 transition-colors disabled:opacity-40"
                                    >
                                        <Pause size={10} />
                                        Pause
                                    </button>
                                )}
                            </div>
                        </div>
                        <QueueBar stats={q.stats} />
                    </div>
                ))}
            </div>
        </div>
    );
}
