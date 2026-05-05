import { api } from "./client";

export interface MetricsBucket {
  hour: string;
  count: number;
}

export interface MetricsData {
  completed: number;
  failed: number;
  cancelled: number;
  pending: number;
  running: number;
  avgDurationMs: number | null;
  throughputPerHour: MetricsBucket[];
  errorRatePerHour: MetricsBucket[];
}

export const getMetrics = (namespace: string): Promise<MetricsData> =>
  api.get<MetricsData>(`/api/${namespace}/metrics`).then((r) => r.data);
