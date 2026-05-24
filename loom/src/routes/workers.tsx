import { useQuery, keepPreviousData } from "@tanstack/react-query";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
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
    sdkVersion: string | null;
}

export function WorkersPage() {
    usePageTitle("Workers");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const { intervalMs, setIntervalMs } = useAutoRefresh();
    const { data: workers = [], isLoading } = useQuery({
        queryKey: ["workers", namespace],
        queryFn: () =>
            api
                .get<Worker[]>(`/api/${namespace}/workers`)
                .then((r) => r.data)
                .catch(() => [] as Worker[]),
        refetchInterval: intervalMs,
        placeholderData: keepPreviousData,
    });

    return (
        <div className="px-6 py-5">
            <div className="flex items-center justify-between mb-4">
                <div>
                    <h1 className="text-base font-semibold text-foreground">
                        Workers
                    </h1>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Workers active in the last 5 minutes.
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
                                    "Version",
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
                                        {w.sdkVersion ? (
                                            <span className="inline-flex items-center rounded border px-1.5 py-0.5 text-[11px] font-mono text-muted-foreground border-border/60 bg-secondary/20">
                                                v{w.sdkVersion}
                                            </span>
                                        ) : (
                                            <span className="text-muted-foreground/40 text-xs">
                                                —
                                            </span>
                                        )}
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
