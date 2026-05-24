import { useState } from "react";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { Search } from "lucide-react";
import {
    useQuery,
    useMutation,
    useQueryClient,
    keepPreviousData,
} from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams } from "@tanstack/react-router";
import {
    listSchedules,
    pauseSchedule,
    resumeSchedule,
    deleteSchedule,
    type ScheduleEntry,
} from "@/api/schedules";
import { qk } from "@/lib/queryKeys";
import { EmptyState } from "@/components/EmptyState";

const TYPE_LABEL: Record<string, string> = {
    cron: "Cron",
    interval: "Interval",
    daily: "Daily",
    weekly: "Weekly",
    monthly: "Monthly",
    yearly: "Yearly",
    once: "Once",
};

export function SchedulesPage() {
    usePageTitle("Schedules");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const qc = useQueryClient();
    const [cursor, setCursor] = useState<{
        afterQueue: string;
        afterName: string;
    } | null>(null);
    const [allSchedules, setAllSchedules] = useState<ScheduleEntry[]>([]);
    const { intervalMs, setIntervalMs } = useAutoRefresh();
    const [query, setQuery] = useState("");
    const PAGE_SIZE = 200;

    const {
        data: page = [],
        isLoading,
        isFetching,
    } = useQuery({
        queryKey: [...qk.schedules.list(namespace), cursor],
        queryFn: () =>
            listSchedules(namespace, {
                limit: PAGE_SIZE,
                afterQueue: cursor?.afterQueue,
                afterName: cursor?.afterName,
            }),
        refetchInterval: cursor ? false : intervalMs,
        placeholderData: keepPreviousData,
    });

    // Append new pages to the accumulated list
    const schedules = cursor === null ? page : [...allSchedules, ...page];
    const hasMore = page.length === PAGE_SIZE;

    function loadMore() {
        const last = page[page.length - 1];
        if (!last) return;
        setAllSchedules((prev) => [...prev, ...page]);
        setCursor({ afterQueue: last.queue, afterName: last.name });
    }

    const pauseMut = useMutation({
        mutationFn: (id: string) => pauseSchedule(namespace, id),
        onSuccess: () =>
            qc.invalidateQueries({ queryKey: qk.schedules.list(namespace) }),
    });
    const resumeMut = useMutation({
        mutationFn: (id: string) => resumeSchedule(namespace, id),
        onSuccess: () =>
            qc.invalidateQueries({ queryKey: qk.schedules.list(namespace) }),
    });
    const deleteMut = useMutation({
        mutationFn: (id: string) => deleteSchedule(namespace, id),
        onSuccess: () =>
            qc.invalidateQueries({ queryKey: qk.schedules.list(namespace) }),
    });

    return (
        <div className="px-6 py-5">
            <div className="flex items-center justify-between mb-4">
                <div>
                    <h1 className="text-base font-semibold text-foreground">
                        Schedules
                    </h1>
                </div>
                <AutoRefreshControl
                    intervalMs={intervalMs}
                    setIntervalMs={setIntervalMs}
                />
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {!isLoading && schedules.length === 0 && (
                <EmptyState
                    variant="schedules"
                    title="No schedules configured"
                    description="Use client.schedule(…) to create one."
                />
            )}

            {schedules.length > 0 && (
                <>
                    <div className="relative mb-3 w-56">
                        <Search
                            size={13}
                            className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none"
                        />
                        <input
                            type="search"
                            placeholder="Filter schedules…"
                            value={query}
                            onChange={(e) => setQuery(e.target.value)}
                            className="pl-7 pr-3 py-1.5 w-full rounded border border-border bg-secondary/30 text-foreground text-xs focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/50"
                        />
                    </div>
                    <div className="rounded-lg border border-border overflow-hidden">
                        <table className="w-full text-sm">
                            <thead>
                                <tr className="border-b border-border bg-secondary/20">
                                    {[
                                        "Name",
                                        "Type",
                                        "Pattern",
                                        "Task",
                                        "Queue",
                                        "Next Run",
                                        "Runs",
                                        "Status",
                                        "",
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
                                {schedules
                                    .filter(
                                        (s) =>
                                            !query ||
                                            s.name
                                                .toLowerCase()
                                                .includes(
                                                    query.toLowerCase(),
                                                ) ||
                                            s.taskName
                                                .toLowerCase()
                                                .includes(
                                                    query.toLowerCase(),
                                                ) ||
                                            s.queue
                                                .toLowerCase()
                                                .includes(query.toLowerCase()),
                                    )
                                    .map((s) => (
                                        <tr
                                            key={s.id}
                                            className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                        >
                                            <td className="px-4 py-2.5 font-medium text-foreground">
                                                <Link
                                                    to="/$namespace/schedules/$scheduleId"
                                                    params={{
                                                        namespace,
                                                        scheduleId: s.id,
                                                    }}
                                                    className="hover:text-brand transition-colors"
                                                >
                                                    {s.name}
                                                </Link>
                                            </td>
                                            <td className="px-4 py-2.5">
                                                <span className="inline-flex items-center rounded border px-2 py-0.5 text-xs bg-secondary/40 text-muted-foreground border-border/60">
                                                    {TYPE_LABEL[
                                                        s.patternType
                                                    ] ?? s.patternType}
                                                </span>
                                            </td>
                                            <td
                                                className="px-4 py-2.5 font-mono text-xs text-muted-foreground max-w-40 truncate"
                                                title={s.patternDescription}
                                            >
                                                {s.patternDescription}
                                            </td>
                                            <td className="px-4 py-2.5 text-muted-foreground">
                                                {s.taskName}
                                            </td>
                                            <td className="px-4 py-2.5 font-mono text-xs text-muted-foreground">
                                                {s.queue}
                                            </td>
                                            <td className="px-4 py-2.5 text-xs text-muted-foreground">
                                                {s.nextRunAt
                                                    ? new Date(
                                                          s.nextRunAt,
                                                      ).toLocaleString()
                                                    : "—"}
                                            </td>
                                            <td className="px-4 py-2.5 text-muted-foreground">
                                                {s.runCount}
                                            </td>
                                            <td className="px-4 py-2.5">
                                                <span
                                                    className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${
                                                        s.isActive
                                                            ? "bg-green-500/20 text-green-300 border-green-500/30"
                                                            : "bg-slate-500/20 text-slate-300 border-slate-500/30"
                                                    }`}
                                                >
                                                    {s.isActive
                                                        ? "Active"
                                                        : "Paused"}
                                                </span>
                                            </td>
                                            <td className="px-4 py-2.5">
                                                <div className="flex gap-2">
                                                    <button
                                                        onClick={() =>
                                                            s.isActive
                                                                ? pauseMut.mutate(
                                                                      s.id,
                                                                  )
                                                                : resumeMut.mutate(
                                                                      s.id,
                                                                  )
                                                        }
                                                        className="text-xs text-muted-foreground hover:text-foreground transition-colors"
                                                    >
                                                        {s.isActive
                                                            ? "Pause"
                                                            : "Resume"}
                                                    </button>
                                                    <button
                                                        onClick={() =>
                                                            deleteMut.mutate(
                                                                s.id,
                                                            )
                                                        }
                                                        className="text-xs text-red-400/60 hover:text-red-400 transition-colors"
                                                    >
                                                        Delete
                                                    </button>
                                                </div>
                                            </td>
                                        </tr>
                                    ))}
                            </tbody>
                        </table>
                        {hasMore && (
                            <div className="flex justify-center py-3 border-t border-border/40">
                                <button
                                    onClick={loadMore}
                                    disabled={isFetching}
                                    className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
                                >
                                    {isFetching ? "Loading…" : `Load more`}
                                </button>
                            </div>
                        )}
                    </div>
                </>
            )}
        </div>
    );
}
