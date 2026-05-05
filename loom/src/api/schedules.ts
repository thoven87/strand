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
}

export interface ScheduleDetail extends ScheduleEntry {
  startsAt: string | null;
  endsAt: string | null;
}

export const listSchedules = (namespace: string): Promise<ScheduleEntry[]> =>
  api
    .get<ScheduleEntry[]>(`/api/${namespace}/schedules`)
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
