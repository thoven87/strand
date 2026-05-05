import type { ReactNode } from "react";

export type EmptyVariant =
  | "tasks"
  | "queues"
  | "workers"
  | "workflows"
  | "schedules"
  | "events";

interface EmptyStateProps {
  variant: EmptyVariant;
  title: string;
  description?: ReactNode;
  action?: ReactNode;
}

// ── Illustrations ─────────────────────────────────────────────────────────

function TasksIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <rect
        x="12"
        y="8"
        width="40"
        height="48"
        rx="4"
        stroke="currentColor"
        strokeWidth="2"
      />
      <line
        x1="20"
        y1="22"
        x2="44"
        y2="22"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="20"
        y1="30"
        x2="44"
        y2="30"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="20"
        y1="38"
        x2="36"
        y2="38"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <circle cx="16" cy="22" r="2" fill="currentColor" />
      <circle cx="16" cy="30" r="2" fill="currentColor" />
      <circle cx="16" cy="38" r="2" fill="currentColor" />
    </svg>
  );
}

function QueuesIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <rect
        x="8"
        y="20"
        width="14"
        height="24"
        rx="3"
        stroke="currentColor"
        strokeWidth="2"
      />
      <rect
        x="25"
        y="14"
        width="14"
        height="36"
        rx="3"
        stroke="currentColor"
        strokeWidth="2"
      />
      <rect
        x="42"
        y="24"
        width="14"
        height="16"
        rx="3"
        stroke="currentColor"
        strokeWidth="2"
      />
    </svg>
  );
}

function WorkersIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <rect
        x="10"
        y="16"
        width="44"
        height="32"
        rx="4"
        stroke="currentColor"
        strokeWidth="2"
      />
      <line
        x1="10"
        y1="28"
        x2="54"
        y2="28"
        stroke="currentColor"
        strokeWidth="1.5"
        strokeDasharray="3 2"
      />
      <circle cx="22" cy="22" r="2" fill="currentColor" />
      <circle cx="30" cy="22" r="2" fill="currentColor" />
      <circle cx="38" cy="22" r="2" fill="currentColor" />
      <line
        x1="24"
        y1="56"
        x2="40"
        y2="56"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="32"
        y1="48"
        x2="32"
        y2="56"
        stroke="currentColor"
        strokeWidth="2"
      />
    </svg>
  );
}

function WorkflowsIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <circle cx="32" cy="12" r="6" stroke="currentColor" strokeWidth="2" />
      <circle cx="14" cy="44" r="6" stroke="currentColor" strokeWidth="2" />
      <circle cx="50" cy="44" r="6" stroke="currentColor" strokeWidth="2" />
      <line
        x1="26"
        y1="16"
        x2="18"
        y2="38"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <line
        x1="38"
        y1="16"
        x2="46"
        y2="38"
        stroke="currentColor"
        strokeWidth="1.5"
      />
    </svg>
  );
}

function SchedulesIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <rect
        x="10"
        y="14"
        width="44"
        height="40"
        rx="4"
        stroke="currentColor"
        strokeWidth="2"
      />
      <line
        x1="10"
        y1="26"
        x2="54"
        y2="26"
        stroke="currentColor"
        strokeWidth="1.5"
      />
      <line
        x1="22"
        y1="8"
        x2="22"
        y2="20"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="42"
        y1="8"
        x2="42"
        y2="20"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <circle cx="24" cy="38" r="3" fill="currentColor" opacity="0.5" />
      <circle cx="40" cy="38" r="3" stroke="currentColor" strokeWidth="1.5" />
      <circle cx="32" cy="46" r="3" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}

function EventsIllustration() {
  return (
    <svg
      width="64"
      height="64"
      viewBox="0 0 64 64"
      fill="none"
      className="text-muted-foreground/30"
    >
      <circle cx="32" cy="32" r="8" stroke="currentColor" strokeWidth="2" />
      <path
        d="M32 16 Q40 24 32 32"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
      />
      <path
        d="M48 32 Q40 40 32 32"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
      />
      <path
        d="M32 48 Q24 40 32 32"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
      />
      <path
        d="M16 32 Q24 24 32 32"
        stroke="currentColor"
        strokeWidth="1.5"
        fill="none"
      />
    </svg>
  );
}

const ILLUSTRATIONS: Record<EmptyVariant, () => JSX.Element> = {
  tasks: TasksIllustration,
  queues: QueuesIllustration,
  workers: WorkersIllustration,
  workflows: WorkflowsIllustration,
  schedules: SchedulesIllustration,
  events: EventsIllustration,
};

// ── Component ─────────────────────────────────────────────────────────────

export function EmptyState({
  variant,
  title,
  description,
  action,
}: EmptyStateProps) {
  const Illustration = ILLUSTRATIONS[variant];
  return (
    <div className="rounded-lg border border-border bg-card/40 p-10 flex flex-col items-center gap-3 text-center">
      <Illustration />
      <div className="space-y-1">
        <p className="text-sm font-medium text-foreground">{title}</p>
        {description && (
          <p className="text-xs text-muted-foreground max-w-xs">
            {description}
          </p>
        )}
      </div>
      {action && <div className="pt-1">{action}</div>}
    </div>
  );
}
