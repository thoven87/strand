import { useQuery } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams } from "@tanstack/react-router";
import { api } from "@/api/client";
import { RelativeTime } from "@/components/RelativeTime";
import { EmptyState } from "@/components/EmptyState";

interface Worker {
    workerID: string;
    queue: string;
    concurrency: number;
    runningTasks: number;
    completedRecently: number;
    startedAt: string | null;
    lastSeenAt: string | null;
    leaseExpiresAt: string | null;
    isHealthy: boolean;
}

export function WorkersPage() {
    usePageTitle("Workers");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const { data: workers = [], isLoading } = useQuery({
        queryKey: ["workers", namespace],
        queryFn: () =>
            api
                .get<Worker[]>(`/api/${namespace}/workers`)
                .then((r) => r.data)
                .catch(() => [] as Worker[]),
        refetchInterval: 5_000,
    });

    return (
        <div className="px-6 py-5">
            <h1 className="text-base font-semibold text-foreground mb-1">
                Workers
            </h1>
            <p className="text-xs text-muted-foreground mb-4">
                Workers active in the last 5 minutes. Refreshes every 5 s.
            </p>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {!isLoading && workers.length === 0 && (
                <EmptyState
                    variant="workers"
                    title="No active workers"
                    description="Start a StrandWorker to see it here."
                />
            )}

            {workers.length > 0 && (
                <div className="rounded-lg border border-border overflow-hidden">
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="border-b border-border bg-secondary/20">
                                {[
                                    "Worker ID",
                                    "Queue",
                                    "Concurrency",
                                    "Running",
                                    "Completed (5 min)",
                                    "Last Seen",
                                    "Lease Expires",
                                    "Status",
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
                            {workers.map((w) => (
                                <tr
                                    key={`${w.workerID}:${w.queue}`}
                                    className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                >
                                    <td className="px-4 py-2.5 font-mono text-xs max-w-xs truncate">
                                        <Link
                                            to="/$namespace/workers/$workerId"
                                            params={{
                                                namespace,
                                                workerId: encodeURIComponent(
                                                    w.workerID,
                                                ),
                                            }}
                                            className="text-foreground hover:text-brand transition-colors"
                                            title={w.workerID}
                                        >
                                            {w.workerID.split(":").pop() ??
                                                w.workerID}
                                        </Link>
                                    </td>
                                    <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">
                                        {w.queue}
                                    </td>
                                    <td className="px-4 py-2.5">
                                        {w.concurrency}
                                    </td>
                                    <td className="px-4 py-2.5">
                                        {w.runningTasks > 0 ? (
                                            <span className="inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal bg-yellow-500/20 text-yellow-300 border-yellow-500/30">
                                                {w.runningTasks} running
                                            </span>
                                        ) : (
                                            <span className="text-muted-foreground text-xs">
                                                0
                                            </span>
                                        )}
                                    </td>
                                    <td className="px-4 py-2.5 text-muted-foreground">
                                        {w.completedRecently}
                                    </td>
                                    <td className="px-4 py-2.5">
                                        <RelativeTime iso={w.lastSeenAt} />
                                    </td>
                                    <td className="px-4 py-2.5">
                                        {w.leaseExpiresAt ? (
                                            <RelativeTime
                                                iso={w.leaseExpiresAt}
                                            />
                                        ) : (
                                            <span className="text-muted-foreground">
                                                —
                                            </span>
                                        )}
                                    </td>
                                    <td className="px-4 py-2.5">
                                        <span
                                            className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${
                                                w.isHealthy
                                                    ? "bg-green-500/20 text-green-300 border-green-500/30"
                                                    : "bg-slate-500/20 text-slate-300 border-slate-500/30"
                                            }`}
                                        >
                                            {w.isHealthy ? "Active" : "Idle"}
                                        </span>
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}
        </div>
    );
}
