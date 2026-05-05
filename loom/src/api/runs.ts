import { api } from "./client";
import type { Checkpoint, Run } from "./types";

export const getRuns = (namespace: string, queue: string, taskId: string) =>
  api
    .get<Run[]>(`/api/${namespace}/queues/${queue}/tasks/${taskId}/runs`)
    .then((r) => r.data);

export const getCheckpoints = (
  namespace: string,
  queue: string,
  taskId: string,
  runId: string,
) =>
  api
    .get<
      Checkpoint[]
    >(`/api/${namespace}/queues/${queue}/tasks/${taskId}/runs/${runId}/checkpoints`)
    .then((r) => r.data);
