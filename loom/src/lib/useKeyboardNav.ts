import { useEffect, useRef } from "react";
import { useNavigate, useParams } from "@tanstack/react-router";
import { getStoredNamespace } from "@/lib/namespace";

/**
 * GitHub-style keyboard navigation: press `g` then a letter within 1 second.
 *
 *   g t → /$namespace/tasks       (definitions)
 *   g r → /$namespace/runs        (execution list)
 *   g q → /$namespace/queues
 *   g s → /$namespace/schedules
 *   g w → /$namespace/workers
 *   g e → /$namespace/events
 *   g m → /$namespace/metrics
 *
 * Disabled when focus is inside an input, textarea, select, or contenteditable.
 */
export function useKeyboardNav() {
    const navigate = useNavigate();
    const { namespace } = useParams({ strict: false }) as {
        namespace?: string;
    };
    const ns = namespace ?? getStoredNamespace();

    const pending = useRef(false);
    const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

    useEffect(() => {
        function onKeyDown(e: KeyboardEvent) {
            // Ignore when modifier keys are held or focus is in an editable element.
            if (e.metaKey || e.ctrlKey || e.altKey) return;
            const target = e.target as HTMLElement;
            const tag = target.tagName;
            if (
                tag === "INPUT" ||
                tag === "TEXTAREA" ||
                tag === "SELECT" ||
                target.isContentEditable
            )
                return;

            const key = e.key.toLowerCase();

            if (pending.current) {
                // Second key of the chord.
                if (timer.current) clearTimeout(timer.current);
                pending.current = false;

                const routes: Record<string, string> = {
                    t: `/${ns}/tasks`,
                    r: `/${ns}/runs`,
                    q: `/${ns}/queues`,
                    s: `/${ns}/schedules`,
                    w: `/${ns}/workers`,
                    e: `/${ns}/events`,
                    m: `/${ns}/metrics`,
                };

                const to = routes[key];
                if (to) {
                    e.preventDefault();
                    navigate({ to: to as never });
                }
                return;
            }

            if (key === "g") {
                // First key of the chord — arm the pending state.
                pending.current = true;
                timer.current = setTimeout(() => {
                    pending.current = false;
                }, 1_000);
            }
        }

        window.addEventListener("keydown", onKeyDown);
        return () => {
            window.removeEventListener("keydown", onKeyDown);
            if (timer.current) clearTimeout(timer.current);
        };
    }, [navigate, ns]);
}
