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
    /** Tasks that failed in the last 24 hours. */
    failedRecent: number;
    // COMPLETED and CANCELLED are not included — use the metrics endpoint for historical counts.
}

export interface Queue {
    name: string;
    createdAt: string;
    stats: QueueStats;
    isPaused: boolean;
    /** Tasks/sec from the broadcast DDSketch cache. null when cache is cold. */
    throughputPerSec: number | null;
}

// ─── Tasks ─────────────────────────────────────────────────────────────────

export type TaskKind = "WORKFLOW" | "ACTIVITY";

/** All possible span kinds in a workflow trace. */
export type SpanKind =
    | "WORKFLOW"
    | "ACTIVITY"
    | "WAIT" // ctx.waitForEvent(...)
    | "SLEEP" // ctx.sleep(for:)
    | "SIGNAL" // handleSignal delivery
    | "EMIT" // ctx.emitEvent(...)
    | "CONDITION"; // ctx.condition(...) — reserved

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
    firstRunAt: string | null;
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
    sdkVersion: string | null;
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

export interface TriggeredTask {
    taskId: string;
    taskName: string;
    taskState: string;
    taskKind: string; // "WORKFLOW" | "ACTIVITY"
}

export interface StrandEvent {
    id: string; // emission UUID — new in append-only log
    name: string;
    payload: string | null; // raw JSON string
    createdAt: string;
    triggeredTasks: TriggeredTask[]; // tasks woken by this event (newest first, up to 5)
}

export interface EventTrigger {
    emissionId: string | null; // UUID of the specific emission that woke this task; null for pre-migration rows
    eventName: string;
    queue: string;
    triggeredAt: string;
}

// ─── Misc ──────────────────────────────────────────────────────────────────

export interface EnqueueResult {
    taskID: string;
    runID: string;
    attempt: number;
}

// ─── Workflow history ───────────────────────────────────────────────────────

/** All known history event types written by the Strand worker. */
export type HistoryEventType =
    | "WORKFLOW_STARTED"
    | "WORKFLOW_COMPLETED"
    | "WORKFLOW_FAILED"
    | "SIGNAL_RECEIVED"
    | "UPDATE_APPLIED"
    | "ACTIVITY_SCHEDULED"
    | "ACTIVITY_STARTED"
    | "ACTIVITY_COMPLETED"
    | "ACTIVITY_FAILED"
    | "TIMER_STARTED"
    | "TIMER_FIRED"
    | "CONDITION_WAITING"
    | "CONDITION_MET"
    | "CONDITION_TIMED_OUT"
    | "EVENT_WAIT_STARTED"
    | "EVENT_RECEIVED"
    | "EVENT_WAIT_TIMED_OUT"
    | "CHILD_WORKFLOW_STARTED"
    | "CHILD_WORKFLOW_COMPLETED"
    | "EVENT_EMITTED";

export interface HistoryEvent {
    seq: number;
    eventType: HistoryEventType;
    eventData: string | null; // raw JSON string
    createdAt: string;
}

// ─── Workflow state ─────────────────────────────────────────────────────────

export interface WorkflowState {
    state: string; // raw JSON string of the serialised workflow struct
}

// ─── Trace ─────────────────────────────────────────────────────────────────

/** Raw shape returned by GET /api/:namespace/tasks/:taskID/trace */
export interface TraceSpanResponse {
    id: string;
    name: string;
    kind: SpanKind; // was "WORKFLOW" | "ACTIVITY" (TaskKind)
    state: string;
    startMs: number;
    durationMs: number;
    queuedMs?: number;
    attempt: number;
    maxAttempts?: number;
    errorMessage?: string;
    workerID?: string;
    createdAt?: string;
    startedAt?: string;
    completedAt?: string;
    taskId?: string; // null for synthetic spans (WAIT/SLEEP/SIGNAL/EMIT)
    children: TraceSpanResponse[];
    emissionId?: string; // only for WAIT spans: links to the emission event
    /** Raw JSON payload received when a waitForEvent resolved. Only set on completed WAIT spans. */
    eventPayload?: string;
}
