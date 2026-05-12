import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { usePageTitle } from "@/lib/usePageTitle";
import { Link, useParams, useNavigate } from "@tanstack/react-router";
import { ArrowLeft, Trash2 } from "lucide-react";
import {
    getSchedule,
    getScheduleRuns,
    pauseSchedule,
    resumeSchedule,
    deleteSchedule,
    getScheduleUpcoming,
    type ScheduleRun,
    type UpcomingSlot,
} from "@/api/schedules";
import type { TaskState } from "@/api/types";
import { qk } from "@/lib/queryKeys";
import { Button } from "@/components/ui/button";
import { StatusBadge } from "@/components/ui/badge";
import { RelativeTime } from "@/components/RelativeTime";

const TYPE_LABEL: Record<string, string> = {
    cron: "Cron",
    interval: "Interval",
    daily: "Daily",
    weekly: "Weekly",
    monthly: "Monthly",
    once: "Once",
};

function DetailRow({
    label,
    children,
}: {
    label: string;
    children: React.ReactNode;
}) {
    return (
        <div className="flex items-start gap-4 py-2.5 border-b border-border/40 last:border-0">
            <span className="w-36 shrink-0 text-xs text-muted-foreground font-medium">
                {label}
            </span>
            <span className="text-sm text-foreground">{children}</span>
        </div>
    );
}

/** Formats a Date as `YYYY-MM-DDTHH:MM UTC` — no seconds, always UTC. */
function fmtUTC(iso: string): string {
    const d = new Date(iso);
    const pad = (n: number) => String(n).padStart(2, "0");
    return (
        `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
        `T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`
    );
}

function OptionalTime({ iso }: { iso: string | null }) {
    if (!iso) return <span className="text-muted-foreground">—</span>;
    return (
        <span className="flex items-center gap-2 flex-wrap">
            <span className="font-mono text-xs text-foreground">
                {fmtUTC(iso)}
            </span>
            <RelativeTime iso={iso} />
        </span>
    );
}

export function ScheduleDetailPage() {
    const { scheduleId, namespace } = useParams({ strict: false }) as {
        scheduleId: string;
        namespace: string;
    };
    const navigate = useNavigate();
    const qc = useQueryClient();

    const {
        data: schedule,
        isLoading,
        error,
    } = useQuery({
        queryKey: qk.schedules.detail(namespace, scheduleId),
        queryFn: () => getSchedule(namespace, scheduleId),
        refetchInterval: 30_000,
    });
    usePageTitle(schedule?.name ?? "Schedule");

    const { data: runs = [] } = useQuery({
        queryKey: qk.schedules.runs(namespace, scheduleId),
        queryFn: () => getScheduleRuns(namespace, scheduleId),
        refetchInterval: schedule?.isActive ? 30_000 : false,
    });

    const { data: upcoming = [] } = useQuery({
        queryKey: [...qk.schedules.detail(namespace, scheduleId), "upcoming"],
        queryFn: () => getScheduleUpcoming(namespace, scheduleId, 5),
        enabled: !!schedule?.isActive,
        refetchInterval: 60_000,
    });

    const pauseMut = useMutation({
        mutationFn: () => pauseSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void qc.invalidateQueries({
                queryKey: qk.schedules.detail(namespace, scheduleId),
            });
        },
    });

    const resumeMut = useMutation({
        mutationFn: () => resumeSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void qc.invalidateQueries({
                queryKey: qk.schedules.detail(namespace, scheduleId),
            });
        },
    });

    const deleteMut = useMutation({
        mutationFn: () => deleteSchedule(namespace, scheduleId),
        onSuccess: () => {
            void qc.invalidateQueries({
                queryKey: qk.schedules.list(namespace),
            });
            void navigate({
                to: "/$namespace/schedules",
                params: { namespace },
            });
        },
    });

    return (
        <div className="px-6 py-5">
            {/* Back link */}
            <div className="flex items-center gap-2 mb-5">
                <Link
                    to="/$namespace/schedules"
                    params={{ namespace }}
                    className="text-muted-foreground hover:text-foreground transition-colors"
                >
                    <ArrowLeft size={16} />
                </Link>
                <span className="text-muted-foreground text-sm">/</span>
                <span className="text-sm text-muted-foreground">Schedules</span>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}
            {error && <p className="text-sm text-red-400">{String(error)}</p>}

            {schedule && (
                <div className="space-y-5">
                    {/* Header */}
                    <div className="flex items-start justify-between gap-4">
                        <div className="space-y-1">
                            <div className="flex items-center gap-3">
                                <h1 className="text-lg font-semibold text-foreground">
                                    {schedule.name}
                                </h1>
                                <span
                                    className={`inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal ${
                                        schedule.isActive
                                            ? "bg-green-500/20 text-green-300 border-green-500/30"
                                            : "bg-slate-500/20 text-slate-300 border-slate-500/30"
                                    }`}
                                >
                                    {schedule.isActive ? "Active" : "Paused"}
                                </span>
                            </div>
                            <p className="text-xs text-muted-foreground font-mono">
                                {scheduleId}
                            </p>
                        </div>

                        {/* Actions */}
                        <div className="flex items-center gap-2 shrink-0">
                            {schedule.isActive ? (
                                <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => pauseMut.mutate()}
                                    disabled={pauseMut.isPending}
                                >
                                    Pause
                                </Button>
                            ) : (
                                <Button
                                    variant="outline"
                                    size="sm"
                                    onClick={() => resumeMut.mutate()}
                                    disabled={resumeMut.isPending}
                                >
                                    Resume
                                </Button>
                            )}
                            <Button
                                variant="destructive"
                                size="sm"
                                onClick={() => {
                                    if (
                                        window.confirm(
                                            `Delete schedule "${schedule.name}"? This cannot be undone.`,
                                        )
                                    ) {
                                        deleteMut.mutate();
                                    }
                                }}
                                disabled={deleteMut.isPending}
                            >
                                <Trash2 size={13} />
                                Delete
                            </Button>
                        </div>
                    </div>

                    {/* Details card */}
                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                            Details
                        </h2>
                        <DetailRow label="Queue">
                            <span className="font-mono text-xs">
                                {schedule.queue}
                            </span>
                        </DetailRow>
                        <DetailRow label="Task name">
                            <span className="font-mono text-xs">
                                {schedule.taskName}
                            </span>
                        </DetailRow>
                        <DetailRow label="Pattern type">
                            <span className="inline-flex items-center rounded border px-2 py-0.5 text-xs bg-secondary/40 text-muted-foreground border-border/60">
                                {TYPE_LABEL[schedule.patternType] ??
                                    schedule.patternType}
                            </span>
                        </DetailRow>
                        <DetailRow label="Pattern">
                            <span className="font-mono text-xs">
                                {schedule.patternDescription}
                            </span>
                        </DetailRow>
                        <DetailRow label="Run count">
                            <span>{schedule.runCount.toLocaleString()}</span>
                        </DetailRow>
                    </section>

                    {/* Timing card */}
                    <section className="rounded-lg border border-border bg-card/40 p-4">
                        <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                            Timing
                        </h2>
                        <DetailRow label="Next run">
                            <OptionalTime iso={schedule.nextRunAt} />
                        </DetailRow>
                        <DetailRow label="Last run">
                            <OptionalTime iso={schedule.lastRunAt} />
                        </DetailRow>
                        <DetailRow label="Created">
                            <OptionalTime iso={schedule.createdAt} />
                        </DetailRow>
                        <DetailRow label="Starts at">
                            <OptionalTime iso={schedule.startsAt} />
                        </DetailRow>
                        <DetailRow label="Ends at">
                            <OptionalTime iso={schedule.endsAt} />
                        </DetailRow>
                    </section>

                    {/* Upcoming fire times */}
                    {upcoming.length > 0 && (
                        <section className="rounded-lg border border-border bg-card/40 p-4">
                            <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                                Upcoming fire times
                            </h2>
                            <ol className="space-y-1.5">
                                {upcoming.map((s: UpcomingSlot, i: number) => (
                                    <li
                                        key={s.slot}
                                        className="flex items-center gap-3 text-xs"
                                    >
                                        <span className="w-4 text-right text-muted-foreground/50 tabular-nums shrink-0">
                                            {i + 1}
                                        </span>
                                        <span className="font-mono text-foreground">
                                            {fmtUTC(s.slot)}
                                        </span>
                                        <span className="text-muted-foreground ml-auto shrink-0">
                                            <RelativeTime iso={s.slot} />
                                        </span>
                                    </li>
                                ))}
                            </ol>
                        </section>
                    )}

                    {/* Recent Runs */}
                    <section className="rounded-lg border border-border bg-card/40 overflow-hidden">
                        <div className="px-4 py-3 border-b border-border/50">
                            <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                                Recent Runs
                            </h2>
                        </div>
                        {runs.length === 0 ? (
                            <div className="px-4 py-8 text-center text-sm text-muted-foreground">
                                No runs yet.
                            </div>
                        ) : (
                            <table className="w-full text-sm">
                                <thead>
                                    <tr className="border-b border-border bg-secondary/20">
                                        {[
                                            "",
                                            "State",
                                            "Attempt",
                                            "Fired",
                                            "Completed",
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
                                    {runs.map((run: ScheduleRun) => (
                                        <tr
                                            key={run.id}
                                            className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors"
                                        >
                                            <td className="px-4 py-3 w-8">
                                                <Link
                                                    to="/$namespace/tasks/$taskId"
                                                    params={{
                                                        namespace,
                                                        taskId: run.id,
                                                    }}
                                                    search={
                                                        {
                                                            queue:
                                                                schedule?.queue ??
                                                                "",
                                                        } as never
                                                    }
                                                    className="text-muted-foreground hover:text-foreground transition-colors"
                                                    title={run.id}
                                                >
                                                    ↗
                                                </Link>
                                            </td>
                                            <td className="px-4 py-3">
                                                <StatusBadge
                                                    state={
                                                        run.state as TaskState
                                                    }
                                                />
                                            </td>
                                            <td className="px-4 py-3 text-muted-foreground">
                                                {run.attempt}
                                            </td>
                                            <td className="px-4 py-3">
                                                <RelativeTime
                                                    iso={run.createdAt}
                                                />
                                            </td>
                                            <td className="px-4 py-3">
                                                <RelativeTime
                                                    iso={run.completedAt}
                                                />
                                            </td>
                                        </tr>
                                    ))}
                                </tbody>
                            </table>
                        )}
                    </section>
                </div>
            )}
        </div>
    );
}
