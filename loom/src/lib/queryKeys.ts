export const qk = {
  queues: {
    list: (namespace: string) => ["queues", namespace] as const,
    detail: (namespace: string, queue: string) =>
      ["queues", namespace, queue] as const,
  },
  tasks: {
    list: (namespace: string, queue: string, state?: string, cursor?: string) =>
      ["tasks", namespace, queue, state ?? "all", cursor ?? ""] as const,
    detail: (namespace: string, queue: string, taskId: string) =>
      ["tasks", namespace, queue, taskId] as const,
    children: (namespace: string, queue: string, taskId: string) =>
      ["children", namespace, queue, taskId] as const,
    trace: (namespace: string, taskId: string) =>
      ["tasks", "trace", namespace, taskId] as const,
  },
  runs: {
    list: (namespace: string, queue: string, taskId: string) =>
      ["runs", namespace, queue, taskId] as const,
    checkpoints: (
      namespace: string,
      queue: string,
      taskId: string,
      runId: string,
    ) => ["checkpoints", namespace, queue, taskId, runId] as const,
  },
  events: {
    list: (namespace: string, queue: string, cursor?: string) =>
      ["events", namespace, queue, cursor ?? ""] as const,
  },
  workflows: {
    history: (namespace: string, queue: string, taskId: string) =>
      ["workflows", "history", namespace, queue, taskId] as const,
    state: (namespace: string, queue: string, taskId: string) =>
      ["workflows", "state", namespace, queue, taskId] as const,
  },
  schedules: {
    list: (namespace: string) => ["schedules", namespace] as const,
    detail: (namespace: string, id: string) =>
      ["schedules", namespace, id] as const,
    runs: (ns: string, id: string) => ["schedules", ns, id, "runs"] as const,
  },
  metrics: {
    get: (namespace: string) => ["metrics", namespace] as const,
  },
  namespaces: {
    list: () => ["namespaces"] as const,
  },
};
