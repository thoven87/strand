import { api } from "./client";
import type { HistoryEvent, WorkflowState } from "./types";

import type { TaskKind } from "./types";

export interface TaskDefinition {
    name: string;
    kind: TaskKind;
    totalRuns: number;
    runningRuns: number;
    queuedRuns: number;
    failedRuns: number;
    lastSeenAt: string | null;
    avgDurationMs: number | null;
}

export const listTaskDefinitions = (
    namespace: string,
): Promise<TaskDefinition[]> =>
    api
        .get<TaskDefinition[]>(`/api/${namespace}/task-definitions`)
        .then((r) => r.data)
        .catch(() => [] as TaskDefinition[]);

export const getWorkflowHistory = (
    namespace: string,
    queue: string,
    taskId: string,
) =>
    api
        .get<
            HistoryEvent[]
        >(`/api/${namespace}/queues/${queue}/tasks/${taskId}/history`)
        .then((r) => r.data);

export const getWorkflowState = (
    namespace: string,
    queue: string,
    taskId: string,
) =>
    api
        .get<WorkflowState>(
            `/api/${namespace}/queues/${queue}/tasks/${taskId}/state`,
        )
        .then((r) => r.data);

export const sendSignal = (
    namespace: string,
    queue: string,
    taskId: string,
    name: string,
    payload?: string,
) =>
    api
        .post<{
            message: string;
            id: string;
        }>(`/api/${namespace}/queues/${queue}/tasks/${taskId}/signal`, {
            name,
            payload: payload ?? null,
        })
        .then((r) => r.data);

export interface DailyActivity {
    date: string; // ISO date string
    total: number;
    failed: number;
}

export const getTaskDefinitionActivity = (
    namespace: string,
    name: string,
    days = 7,
): Promise<DailyActivity[]> =>
    api
        .get<DailyActivity[]>(
            `/api/${namespace}/task-definitions/${encodeURIComponent(name)}/activity`,
            { params: { days } },
        )
        .then((r) => r.data)
        .catch(() => [] as DailyActivity[]);

export interface TaskKindEntry {
    name: string;
    kind: "WORKFLOW" | "ACTIVITY";
}

export const getTaskKinds = (
    namespace: string,
    limit = 200,
): Promise<TaskKindEntry[]> =>
    api
        .get<TaskKindEntry[]>(`/api/${namespace}/task-kinds`, {
            params: { limit },
        })
        .then((r) => r.data)
        .catch(() => [] as TaskKindEntry[]);

export const triggerWorkflow = (
    namespace: string,
    workflowName: string,
    input: string,
    queue?: string,
): Promise<{ taskID: string; runID: string; attempt: number }> =>
    api
        .post(`/api/${namespace}/workflows/run`, { workflowName, queue, input })
        .then((r) => r.data);
