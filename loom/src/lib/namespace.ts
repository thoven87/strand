const KEY = "strand_namespace";

export function getStoredNamespace(): string {
  return localStorage.getItem(KEY) ?? "default";
}

export function setStoredNamespace(ns: string): void {
  localStorage.setItem(KEY, ns);
}
