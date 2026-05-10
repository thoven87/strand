// ─── States ────────────────────────────────────────────────────────────────

export type TaskState =
    | "PENDING"
    | "RUNNING"
    | "SLEEPING"
    | "WAITING"
    | "COMPLETED"
    | "FAILED"
    | "CANCELLED"
    | "CONTINUED_AS_NEW";

// ─── Queue ─────────────────────────────────────────────────────────────────

export interface QueueStats {
    pending: number;
    running: number;
    /** Workflows suspended on ctx.sleep(for:) — waiting for a timer. */
    sleeping: number;
    /** Workflows suspended waiting for an activity, child workflow, or named event. */
    waiting: number;
    completed: number;
    failed: number;
    cancelled: number;
}

export interface Queue {
    name: string;
    createdAt: string;
    stats: QueueStats;
    isPaused: boolean;
}

// ─── Tasks ─────────────────────────────────────────────────────────────────

export type TaskKind = "WORKFLOW" | "ACTIVITY";

// ─── Retry ──────────────────────────────────────────────────────────────────

export type RetryMode = "all" | "failed_only" | "failed_and_dependents";

export interface RetryOptions {
    mode: RetryMode;
    resetHistory: boolean;
}

export interface TaskSummary {
    id: string;
    name: string;
    queue: string;
    state: TaskState;
    attempt: number;
    createdAt: string;
    completedAt: string | null;
    /** "WORKFLOW" for root orchestrators, "ACTIVITY" for child leaf tasks. */
    kind: TaskKind;
    /** UUID of the parent workflow that spawned this task, null for root tasks. */
    parentTaskId: string | null;
    /**
     * Human-readable workflow ID — the value passed to WorkflowOptions.id at enqueue
     * time, or the auto-generated "WorkflowName-<ms>" string.
     * null for activity tasks (spawned internally, not via startWorkflow).
     */
    workflowId: string | null;
    /** Schedule name when triggered by StrandScheduler, null for manual enqueues. */
    scheduleName: string | null;
}

export interface TaskDetail {
    id: string;
    name: string;
    queue: string;
    params: string; // raw JSON string
    state: TaskState;
    attempt: number;
    maxAttempts: number | null;
    createdAt: string;
    firstRunAt: string | null;
    completedAt: string | null;
    result: string | null; // raw JSON string
    cancelledAt: string | null;
    kind: TaskKind;
    parentTaskId: string | null;
    workflowId: string | null;
    scheduling: {
        scheduleName: string | null;
        scheduleId: string | null;
        executionTime: string;
        partitionTime: string | null;
        /** ISO 8601 offset string from the pattern, e.g. "PT15M". null when offset is zero. */
        scheduleOffset: string | null;
    } | null;
}

export interface CursorPage<T> {
    items: T[];
    nextCursor: string | null;
}

// ─── Runs ──────────────────────────────────────────────────────────────────

export interface Run {
    id: string;
    attempt: number;
    state: TaskState;
    workerID: string | null;
    startedAt: string | null;
    finishedAt: string | null;
    leaseExpiresAt: string | null;
    createdAt: string;
    failureReason: string | null; // raw JSON string
}

export interface Checkpoint {
    name: string;
    state: string; // raw JSON value (any type)
}

// ─── Events ────────────────────────────────────────────────────────────────

export interface StrandEvent {
    name: string;
    payload: string | null; // raw JSON string
    createdAt: string;
}

// ─── Misc ──────────────────────────────────────────────────────────────────

export interface EnqueueResult {
    taskID: string;
    runID: string;
    attempt: number;
}

// ─── Workflow history ───────────────────────────────────────────────────────

export interface HistoryEvent {
    seq: number;
    eventType: string;
    eventData: string | null; // raw JSON string
    createdAt: string;
}

// ─── Workflow state ─────────────────────────────────────────────────────────

export interface WorkflowState {
    state: string; // raw JSON string of the serialised workflow struct
}

// ─── Trace ─────────────────────────────────────────────────────────────────

/** Raw shape returned by GET /api/:namespace/tasks/:taskID/trace */
export interface TraceSpanData {
    id: string;
    name: string;
    kind: "WORKFLOW" | "ACTIVITY";
    state:
        | "COMPLETED"
        | "RUNNING"
        | "WAITING"
        | "FAILED"
        | "CANCELLED"
        | "PENDING";
    startMs: number;
    durationMs: number;
    queuedMs?: number;
    attempt: number;
    maxAttempts?: number;
    errorMessage?: string;
    workerID?: string;
    createdAt: string;
    startedAt?: string | null;
    completedAt?: string | null;
    taskId: string;
    children: TraceSpanData[];
}
