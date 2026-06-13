import { cn } from "@/lib/utils";

export type StatusVariant =
    | "QUEUED"
    | "RUNNING"
    | "PAUSED"
    | "COMPLETED"
    | "FAILED"
    | "CANCELLED"
    | "CONTINUED_AS_NEW";

const VARIANT_CLASSES: Record<StatusVariant, string> = {
    QUEUED: "bg-slate-500/15  text-slate-600  dark:text-slate-300  border-slate-500/25",
    RUNNING:
        "bg-yellow-500/15 text-yellow-700 dark:text-yellow-300 border-yellow-500/25",
    PAUSED: "bg-blue-500/15   text-blue-700   dark:text-blue-300   border-blue-500/25",
    COMPLETED:
        "bg-green-500/15  text-green-700  dark:text-green-300  border-green-500/25",
    FAILED: "bg-red-500/15    text-red-700    dark:text-red-300    border-red-500/25",
    CANCELLED:
        "bg-orange-500/15 text-orange-700 dark:text-orange-300 border-orange-500/25",
    CONTINUED_AS_NEW:
        "bg-slate-500/15  text-slate-600  dark:text-slate-300  border-slate-500/25",
};

const VARIANT_LABELS: Record<StatusVariant, string> = {
    QUEUED: "QUEUED",
    RUNNING: "RUNNING",
    PAUSED: "PAUSED",
    COMPLETED: "COMPLETED",
    FAILED: "FAILED",
    CANCELLED: "CANCELLED",
    CONTINUED_AS_NEW: "CONTINUED_AS_NEW",
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
