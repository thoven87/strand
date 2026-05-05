import { api } from "./client";

export interface NamespaceSummary {
  id: string;
  displayName: string | null;
}

export const listNamespaces = (): Promise<NamespaceSummary[]> =>
  api.get<NamespaceSummary[]>("/api/namespaces").then((r) => r.data);
