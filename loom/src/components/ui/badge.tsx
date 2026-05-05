import { cn } from "@/lib/utils";

export type StatusVariant =
  | "PENDING"
  | "RUNNING"
  | "SLEEPING"
  | "COMPLETED"
  | "FAILED"
  | "CANCELLED"
  | "DAG_BLOCKED";

const VARIANT_CLASSES: Record<StatusVariant, string> = {
  PENDING: "bg-slate-500/20 text-slate-300 border-slate-500/30",
  RUNNING: "bg-yellow-500/20 text-yellow-300 border-yellow-500/30",
  SLEEPING: "bg-indigo-500/20 text-indigo-300 border-indigo-500/30",
  COMPLETED: "bg-green-500/20 text-green-300 border-green-500/30",
  FAILED: "bg-red-500/20 text-red-300 border-red-500/30",
  CANCELLED: "bg-orange-500/20 text-orange-300 border-orange-500/30",
  DAG_BLOCKED: "bg-purple-500/20 text-purple-300 border-purple-500/30",
};

const VARIANT_LABELS: Record<StatusVariant, string> = {
  PENDING: "Pending",
  RUNNING: "Running",
  SLEEPING: "Sleeping",
  COMPLETED: "Completed",
  FAILED: "Failed",
  CANCELLED: "Cancelled",
  DAG_BLOCKED: "Blocked",
};

interface StatusBadgeProps {
  state: string;
  className?: string;
}

export function StatusBadge({ state, className }: StatusBadgeProps) {
  const s = state as StatusVariant;
  const cls =
    VARIANT_CLASSES[s] ?? "bg-slate-500/20 text-slate-300 border-slate-500/30";
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
