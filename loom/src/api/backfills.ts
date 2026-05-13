import { api } from "./client";

export interface BackfillResponse {
    id: string;
    scheduleId: string | null;
    queue: string;
    taskName: string;
    taskKind: string;
    rangeStart: string;    // ISO 8601
    rangeEnd: string;
    concurrency: number;
    allowOverwrite: boolean;
    description: string | null;
    status: "RUNNING" | "HALTED" | "COMPLETED" | "FAILED";
    nextSlotTime: string;
    totalSlots: number;
    completedSlots: number;
    createdAt: string;
    completedAt: string | null;
}

export const createBackfill = (
    namespace: string,
    scheduleId: string,
    body: {
        rangeStart: string;
        rangeEnd: string;
        concurrency?: number;
        allowOverwrite?: boolean;
        description?: string;
    }
): Promise<BackfillResponse> =>
    api.post<BackfillResponse>(
        `/api/${namespace}/schedules/${scheduleId}/backfills`,
        body
    ).then(r => r.data);

export const getBackfills = (
    namespace: string,
    scheduleId: string
): Promise<BackfillResponse[]> =>
    api.get<BackfillResponse[]>(
        `/api/${namespace}/schedules/${scheduleId}/backfills`
    ).then(r => r.data);

export const haltBackfill = (namespace: string, id: string) =>
    api.post(`/api/${namespace}/backfills/${id}/halt`).then(r => r.data);

export const resumeBackfill = (namespace: string, id: string) =>
    api.post(`/api/${namespace}/backfills/${id}/resume`).then(r => r.data);

export const setBackfillConcurrency = (namespace: string, id: string, concurrency: number) =>
    api.patch(`/api/${namespace}/backfills/${id}/concurrency`, { concurrency }).then(r => r.data);
