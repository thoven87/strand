import { api } from "./client";

export interface ScheduleEntry {
    id: string;
    name: string;
    queue: string;
    taskName: string;
    isActive: boolean;
    nextRunAt: string | null;
    lastRunAt: string | null;
    runCount: number;
    createdAt: string;
    patternType: string;
    patternDescription: string;
    /** SLO: expected max seconds from logicalDate to partition completion. null = no SLO. */
    sloLimitSeconds: number | null;
}

export interface ScheduleDetail extends ScheduleEntry {
    startsAt: string | null;
    endsAt: string | null;
    /** IANA timezone identifier for the schedule (e.g. "America/New_York").
     *  Use this to show a timezone hint in manual-trigger forms so users
     *  don't accidentally enter UTC when the schedule runs in a different zone. */
    patternTimezone: string;
}

export const listSchedules = (
    namespace: string,
    opts: { limit?: number; afterQueue?: string; afterName?: string } = {},
): Promise<ScheduleEntry[]> =>
    api
        .get<ScheduleEntry[]>(`/api/${namespace}/schedules`, { params: opts })
        .then((r) => r.data)
        .catch(() => [] as ScheduleEntry[]);

export const getSchedule = (
    namespace: string,
    id: string,
): Promise<ScheduleDetail> =>
    api
        .get<ScheduleDetail>(`/api/${namespace}/schedules/${id}`)
        .then((r) => r.data);

export const pauseSchedule = (namespace: string, id: string) =>
    api.post(`/api/${namespace}/schedules/${id}/pause`).then((r) => r.data);

export const resumeSchedule = (namespace: string, id: string) =>
    api.post(`/api/${namespace}/schedules/${id}/resume`).then((r) => r.data);

export const deleteSchedule = (namespace: string, id: string) =>
    api.delete(`/api/${namespace}/schedules/${id}`).then((r) => r.data);

export interface ScheduleRun {
    id: string;
    state: string;
    attempt: number;
    createdAt: string;
    completedAt: string | null;
    /** Canonical logical/partition date from scheduling_metadata.logicalDate.
     *  Use this (not createdAt) to place runs in the partition grid:
     *  backfill tasks are created at wall-clock time but belong to a past slot. */
    logicalDate: string | null;
}

export const getScheduleRuns = (
    namespace: string,
    scheduleId: string,
    limit = 20,
): Promise<ScheduleRun[]> =>
    api
        .get<ScheduleRun[]>(`/api/${namespace}/schedules/${scheduleId}/runs`, {
            params: { limit },
        })
        .then((r) => r.data);

export interface UpcomingSlot {
    /** Wall-clock UTC fire time. */
    slot: string;
    /** Logical/partition date for this slot (slot − scheduleOffset).
     *  Use this (not slot) to place upcoming runs in the partition health grid.
     *  Null for schedules whose pattern cannot be parsed server-side. */
    logicalDate: string | null;
}

export const runSchedulePartition = (
    namespace: string,
    scheduleId: string,
    body: { logicalDate: string; allowOverwrite?: boolean },
): Promise<{ taskId: string; runId: string }> =>
    api
        .post<{
            taskId: string;
            runId: string;
        }>(
            `/api/${namespace}/schedules/${encodeURIComponent(scheduleId)}/run`,
            body,
        )
        .then((r) => r.data);

export const getScheduleUpcoming = (
    namespace: string,
    id: string,
    count = 5,
): Promise<UpcomingSlot[]> =>
    api
        .get<UpcomingSlot[]>(`/api/${namespace}/schedules/${id}/upcoming`, {
            params: { count },
        })
        .then((r) => r.data);
