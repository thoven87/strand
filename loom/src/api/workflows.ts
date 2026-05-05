import { api } from "./client";
import type { HistoryEvent, WorkflowState } from "./types";

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

export const triggerWorkflow = (
  namespace: string,
  workflowName: string,
  input: string,
  queue?: string,
): Promise<{ taskID: string; runID: string; attempt: number }> =>
  api
    .post(`/api/${namespace}/workflows/run`, { workflowName, queue, input })
    .then((r) => r.data);
