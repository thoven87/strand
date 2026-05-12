import { cn } from "@/lib/utils";

export type StatusVariant =
    | "PENDING"
    | "RUNNING"
    | "SLEEPING"
    | "WAITING"
    | "COMPLETED"
    | "FAILED"
    | "CANCELLED"
    | "DAG_BLOCKED"
    | "CONTINUED_AS_NEW";

const VARIANT_CLASSES: Record<StatusVariant, string> = {
    PENDING:
        "bg-slate-500/15  text-slate-600  dark:text-slate-300  border-slate-500/25",
    RUNNING:
        "bg-yellow-500/15 text-yellow-700 dark:text-yellow-300 border-yellow-500/25",
    SLEEPING:
        "bg-indigo-500/15 text-indigo-700 dark:text-indigo-300 border-indigo-500/25",
    WAITING:
        "bg-violet-500/15 text-violet-700 dark:text-violet-300 border-violet-500/25",
    COMPLETED:
        "bg-green-500/15  text-green-700  dark:text-green-300  border-green-500/25",
    FAILED: "bg-red-500/15    text-red-700    dark:text-red-300    border-red-500/25",
    CANCELLED:
        "bg-orange-500/15 text-orange-700 dark:text-orange-300 border-orange-500/25",
    DAG_BLOCKED:
        "bg-purple-500/15 text-purple-700 dark:text-purple-300 border-purple-500/25",
    CONTINUED_AS_NEW:
        "bg-slate-500/15  text-slate-600  dark:text-slate-300  border-slate-500/25",
};

const VARIANT_LABELS: Record<StatusVariant, string> = {
    PENDING: "Pending",
    RUNNING: "Running",
    SLEEPING: "Sleeping",
    WAITING: "Waiting",
    COMPLETED: "Completed",
    FAILED: "Failed",
    CANCELLED: "Cancelled",
    DAG_BLOCKED: "Blocked",
    CONTINUED_AS_NEW: "Continued",
};

interface StatusBadgeProps {
    state: string;
    className?: string;
}

export function StatusBadge({ state, className }: StatusBadgeProps) {
    const s = state as StatusVariant;
    const cls =
        VARIANT_CLASSES[s] ??
        "bg-slate-500/20 text-slate-300 border-slate-500/30";
    const label = VARIANT_LABELS[s] ?? state;

    return (
        <span
            className={cn(
                "inline-flex items-center rounded border px-2 py-0.5 text-xs font-normal",
                s === "RUNNING" && "animate-pulse",
                cls,
                className,
            )}
        >
            {label}
        </span>
    );
}
