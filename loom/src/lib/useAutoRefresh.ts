import { useState } from "react";

const STORAGE_KEY = "loom-refresh-interval";

export const REFRESH_OPTIONS = [
    { label: "Off",  ms: false    as false },
    { label: "5s",   ms: 5_000   },
    { label: "10s",  ms: 10_000  },
    { label: "30s",  ms: 30_000  },
    { label: "1m",   ms: 60_000  },
    { label: "5m",   ms: 300_000 },
] satisfies { label: string; ms: false | number }[];

function load(): false | number {
    try {
        const raw = localStorage.getItem(STORAGE_KEY);
        if (!raw || raw === "false") return false;
        const n = parseInt(raw, 10);
        return isNaN(n) ? false : n;
    } catch {
        return false;
    }
}

function save(ms: false | number) {
    try {
        localStorage.setItem(STORAGE_KEY, String(ms));
    } catch { /* ignore */ }
}

/** Returns the active refetch interval and a setter. Pass `intervalMs`
 *  directly to react-query's `refetchInterval`. */
export function useAutoRefresh() {
    const [intervalMs, setIntervalMsState] = useState<false | number>(load);

    function setIntervalMs(ms: false | number) {
        save(ms);
        setIntervalMsState(ms);
    }

    return { intervalMs, setIntervalMs };
}
