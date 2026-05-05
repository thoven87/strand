import { useSyncExternalStore } from "react";

const STORAGE_KEY = "loom_time_format";
const listeners = new Set<() => void>();

export type TimeFormat = "relative" | "absolute";

function getSnapshot(): TimeFormat {
  try {
    return (localStorage.getItem(STORAGE_KEY) as TimeFormat) ?? "relative";
  } catch {
    return "relative";
  }
}

function subscribe(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Toggle between "relative" and "absolute" and notify all subscribers. */
export function toggleTimeFormat(): void {
  const next = getSnapshot() === "relative" ? "absolute" : "relative";
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    // ignore storage errors (e.g. private browsing)
  }
  listeners.forEach((fn) => fn());
}

/** React hook — re-renders whenever the format changes globally. */
export function useTimeFormat(): TimeFormat {
  return useSyncExternalStore(subscribe, getSnapshot);
}
