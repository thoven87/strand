import { api } from "./client";
import type { Queue } from "./types";

export const getQueues = (namespace: string) =>
  api.get<Queue[]>(`/api/${namespace}/queues`).then((r) => r.data);

export const getQueue = (namespace: string, queue: string) =>
  api.get<Queue>(`/api/${namespace}/queues/${queue}`).then((r) => r.data);

export const createQueue = (namespace: string, name: string) =>
  api.post(`/api/${namespace}/queues`, { name }).then((r) => r.data);

export const deleteQueue = (namespace: string, queue: string) =>
  api.delete(`/api/${namespace}/queues/${queue}`).then((r) => r.data);

export const cleanupQueue = (
  namespace: string,
  queue: string,
  opts: { olderThan?: number; limit?: number } = {},
) =>
  api
    .post(`/api/${namespace}/queues/${queue}/cleanup`, null, { params: opts })
    .then((r) => r.data);

export const pauseQueue = (namespace: string, queue: string) =>
  api.post(`/api/${namespace}/queues/${queue}/pause`).then((r) => r.data);

export const resumeQueue = (namespace: string, queue: string) =>
  api.post(`/api/${namespace}/queues/${queue}/resume`).then((r) => r.data);
