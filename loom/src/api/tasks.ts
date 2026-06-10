import { api } from "./client";
import type {
    CursorPage,
    EnqueueResult,
    RetryOptions,
    TaskDetail,
    TaskSummary,
    TraceSpanResponse,
} from "./types";
import type { TraceSpan } from "@/components/TraceTree";

export const getTasks = (
    namespace: string,
    queue: string,
    opts: {
        state?: string;
        cursor?: string;
        limit?: number;
        rootOnly?: boolean;
    } = {},
) =>
    api
        .get<CursorPage<TaskSummary>>(
            `/api/${namespace}/queues/${queue}/tasks`,
            {
                params: opts,
            },
        )
        .then((r) => r.data);

// Fetch tasks across all queues (or filtered to one queue)
export const getTasksGlobal = (
    namespace: string,
    opts: {
        queue?: string;
        state?: string;
        name?: string;
        kind?: string;
        rootOnly?: boolean;
        /** Filter to tasks created by a specific backfill (allowOverwrite=true, or new slots). */
        backfillId?: string;
        /** Filter to all tasks belonging to a schedule (by idempotency-key prefix).
         *  Used for backfill task lists when backfill_id is NULL because the task
         *  pre-existed (allowOverwrite=false, slot already ran via regular schedule). */
        scheduleId?: string;
        cursor?: string;
        limit?: number;
    } = {},
) =>
    api
        .get<
            CursorPage<TaskSummary>
        >(`/api/${namespace}/tasks`, { params: opts })
        .then((r) => r.data);

export const getTask = (namespace: string, queue: string, taskId: string) =>
    api
        .get<TaskDetail>(`/api/${namespace}/queues/${queue}/tasks/${taskId}`)
        .then((r) => r.data);

export const cancelTask = (namespace: string, queue: string, taskId: string) =>
    api
        .post(`/api/${namespace}/queues/${queue}/tasks/${taskId}/cancel`)
        .then((r) => r.data);

export const requeueTask = (
    namespace: string,
    queue: string,
    taskId: string,
    options: RetryOptions = { mode: "all", resetHistory: false },
): Promise<EnqueueResult> =>
    api
        .post<EnqueueResult>(
            `/api/${namespace}/queues/${queue}/tasks/${taskId}/retry`,
            options,
        )
        .then((r) => r.data);

export const getChildTasks = (
    namespace: string,
    queue: string,
    taskId: string,
    opts: { cursor?: string; limit?: number } = {},
) =>
    api
        .get<CursorPage<TaskSummary>>(
            `/api/${namespace}/queues/${queue}/tasks/${taskId}/children`,
            {
                params: opts,
            },
        )
        .then((r) => r.data);

// ─── Trace ──────────────────────────────────────────────────────────────────

function transformSpan(raw: TraceSpanResponse): TraceSpan {
    const isLive =
        raw.state === "RUNNING" ||
        raw.state === "WAITING" ||
        raw.state === "PENDING";
    return {
        id: raw.id,
        name: raw.name,
        kind: raw.kind,
        state: raw.state as TraceSpan["state"],
        startMs: raw.startMs,
        durationMs: raw.durationMs,
        queuedMs: raw.queuedMs,
        attempt: raw.attempt,
        maxAttempts: raw.maxAttempts,
        errorMessage: raw.errorMessage,
        workerID: raw.workerID ?? undefined,
        createdAt: raw.createdAt,
        startedAt: raw.startedAt ?? undefined,
        completedAt: raw.completedAt ?? undefined,
        taskId: raw.taskId,
        emissionId: raw.emissionId,
        eventPayload: raw.eventPayload,
        isLive,
        children: raw.children.map(transformSpan),
    };
}

export const getTaskTrace = (
    namespace: string,
    taskId: string,
): Promise<TraceSpan[]> =>
    api
        .get<TraceSpanResponse[]>(`/api/${namespace}/tasks/${taskId}/trace`)
        .then((r) => r.data.map(transformSpan));
