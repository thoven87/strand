import { api } from "./client";

export interface MetricsBucket {
    hour: string;
    count: number;
}

export interface TaskTiming {
    queue: string;
    taskName: string;
    /** Terminal state — always one of the TaskState uppercase values. */
    state: "COMPLETED" | "FAILED";
    count: number;
    /** Executions per second for this (queue, task, state) in the last broadcast cycle. */
    ratePerSec: number | null;
    p50Ms: number | null;
    p95Ms: number | null;
    p99Ms: number | null;
    /** p50 queue-wait time — time from PENDING to when a worker claimed the task */
    p50WaitMs: number | null;
    /** p95 queue-wait time */
    p95WaitMs: number | null;
}

export interface MetricsData {
    completed: number;
    failed: number;
    cancelled: number;
    pending: number;
    running: number;
    avgDurationMs: number | null;
    /** Total tasks/sec across all queues in the last broadcast cycle. Null when no metrics buffer is wired. */
    throughputPerSec: number | null;
    throughputPerHour: MetricsBucket[];
    errorRatePerHour: MetricsBucket[];
    taskTimings: TaskTiming[] | null;
    windowHours: number;
}

export interface TaskMetrics {
    taskName: string;
    completedCount: number;
    failedCount: number;
    p50Ms: number | null;
    p95Ms: number | null;
    p99Ms: number | null;
    p50WaitMs: number | null;
    p95WaitMs: number | null;
    ratePerSec: number | null;
}

export const getTaskMetrics = (
    namespace: string,
    taskName: string,
): Promise<TaskMetrics> =>
    api
        .get<TaskMetrics>(
            `/api/${namespace}/metrics/task/${encodeURIComponent(taskName)}`,
        )
        .then((r) => r.data);

export const getMetrics = (
    namespace: string,
    hours = 24,
): Promise<MetricsData> =>
    api
        .get<MetricsData>(`/api/${namespace}/metrics`, { params: { hours } })
        .then((r) => r.data);
