import { useState } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import { useQuery } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { Zap } from "lucide-react";
import { api } from "@/api/client";
import { RelativeTime } from "@/components/RelativeTime";
import { TriggerDialog } from "@/components/TriggerDialog";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/EmptyState";

interface WorkflowDef {
    name: string;
    totalRuns: number;
    activeRuns: number;
    failedRuns: number;
    lastSeenAt: string | null;
}

function StatPill({
    count,
    label,
    cls,
}: {
    count: number;
    label: string;
    cls: string;
}) {
    if (count === 0) return null;
    return (
        <span
            className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${cls}`}
        >
            {count} {label}
        </span>
    );
}

export function WorkflowsPage() {
    usePageTitle("Workflows");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const [triggerOpen, setTriggerOpen] = useState(false);

    const { data: workflows = [], isLoading } = useQuery({
        queryKey: ["workflows", namespace],
        queryFn: () =>
            api
                .get<WorkflowDef[]>(`/api/${namespace}/workflows`)
                .then((r) => r.data)
                .catch(() => [] as WorkflowDef[]),
        refetchInterval: 30_000,
    });

    return (
        <div className="px-6 py-5">
            {/* Page header */}
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-base font-semibold text-foreground">
                    Workflows
                </h1>
                <Button
                    size="sm"
                    variant="default"
                    onClick={() => setTriggerOpen(true)}
                >
                    <Zap size={13} />
                    Trigger
                </Button>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {!isLoading && workflows.length === 0 && (
                <EmptyState
                    variant="workflows"
                    title="No workflows yet"
                    description="Enqueue your first workflow to see it here."
                />
            )}

            {workflows.length > 0 && (
                <div className="rounded-lg border border-border overflow-hidden">
                    <table className="w-full text-sm">
                        <thead>
                            <tr className="border-b border-border bg-secondary/20">
                                {[
                                    "Name",
                                    "Status",
                                    "Total Runs",
                                    "Last Seen",
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
                            {workflows.map((wf) => (
                                <tr
                                    key={wf.name}
                                    className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                >
                                    <td className="px-4 py-3">
                                        <Link
                                            to="/$namespace/tasks"
                                            params={{ namespace }}
                                            search={{ name: wf.name }}
                                            className="font-medium text-foreground hover:text-brand transition-colors font-mono text-sm"
                                        >
                                            {wf.name}
                                        </Link>
                                    </td>
                                    <td className="px-4 py-3">
                                        <div className="flex gap-1.5 flex-wrap">
                                            <StatPill
                                                count={wf.activeRuns}
                                                label="active"
                                                cls="bg-yellow-500/20 text-yellow-300 border-yellow-500/30"
                                            />
                                            <StatPill
                                                count={wf.failedRuns}
                                                label="failed"
                                                cls="bg-red-500/20 text-red-300 border-red-500/30"
                                            />
                                            {wf.activeRuns === 0 &&
                                                wf.failedRuns === 0 && (
                                                    <span className="text-xs text-muted-foreground">
                                                        idle
                                                    </span>
                                                )}
                                        </div>
                                    </td>
                                    <td className="px-4 py-3 text-muted-foreground">
                                        {wf.totalRuns.toLocaleString()}
                                    </td>
                                    <td className="px-4 py-3 text-xs text-muted-foreground">
                                        {wf.lastSeenAt ? (
                                            <RelativeTime iso={wf.lastSeenAt} />
                                        ) : (
                                            "—"
                                        )}
                                    </td>
                                </tr>
                            ))}
                        </tbody>
                    </table>
                </div>
            )}

            <TriggerDialog
                open={triggerOpen}
                onClose={() => setTriggerOpen(false)}
                namespace={namespace}
            />
        </div>
    );
}
