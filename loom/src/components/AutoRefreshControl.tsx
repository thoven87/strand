import { RefreshCcw } from "lucide-react";
import { Select } from "@/components/ui/select";
import { REFRESH_OPTIONS, useAutoRefresh } from "@/lib/useAutoRefresh";

interface AutoRefreshControlProps {
    /** Value returned by useAutoRefresh() — pass the same instance down
     *  so the control and the queries share state. */
    intervalMs: false | number;
    setIntervalMs: (ms: false | number) => void;
}

export function AutoRefreshControl({
    intervalMs,
    setIntervalMs,
}: AutoRefreshControlProps) {
    const value = intervalMs === false ? "false" : String(intervalMs);

    return (
        <div className="flex items-center gap-1.5">
            <RefreshCcw
                size={12}
                className={
                    intervalMs === false
                        ? "text-muted-foreground/40"
                        : "text-muted-foreground animate-spin"
                }
                style={
                    intervalMs === false
                        ? undefined
                        : { animationDuration: `${intervalMs}ms` }
                }
            />
            <Select
                value={value}
                onChange={(e) => {
                    const raw = e.target.value;
                    setIntervalMs(raw === "false" ? false : parseInt(raw, 10));
                }}
                aria-label="Auto-refresh interval"
            >
                {REFRESH_OPTIONS.map((opt) => (
                    <option key={String(opt.ms)} value={String(opt.ms)}>
                        {opt.label}
                    </option>
                ))}
            </Select>
        </div>
    );
}

/** Self-contained version — manages its own state via localStorage. */
export function AutoRefreshControlStandalone() {
    const { intervalMs, setIntervalMs } = useAutoRefresh();
    return (
        <AutoRefreshControl
            intervalMs={intervalMs}
            setIntervalMs={setIntervalMs}
        />
    );
}
