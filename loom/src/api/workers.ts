import { api } from "./client";

export interface Worker {
    workerID: string;
    queue: string;
    concurrency: number;
    runningTasks: number;
    completedRecently: number;
    startedAt: string | null;
    lastSeenAt: string | null;
    leaseExpiresAt: string | null;
    isHealthy: boolean;
}

export const getWorkers = (namespace: string): Promise<Worker[]> =>
    api
        .get<Worker[]>(`/api/${namespace}/workers`)
        .then((r) => r.data)
        .catch(() => [] as Worker[]);
