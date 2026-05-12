/**
 * TimeBrush — range selection control for the Gantt minimap.
 *
 * Ported from inngest/ui with Loom design tokens.
 * Lets the user drag a selection window over the full trace duration to
 * zoom into a specific time range without horizontal scrolling.
 *
 * Features:
 *  - Drag left/right handles to resize the selection
 *  - Drag inside the selection to pan the window
 *  - Click+drag outside the selection to create a new one
 *  - Hover cursor line (via rAF, no React re-render on every mousemove)
 *  - Optional reset button
 */

import { useCallback, useEffect, useRef, useState } from "react";
import { cn } from "@/lib/utils";

export interface TimeBrushProps {
    /** Called whenever the selection changes. Values are percentages 0–100. */
    onSelectionChange?: (start: number, end: number) => void;
    /** Initial left edge of the selection (default 0 = full range). */
    initialStart?: number;
    /** Initial right edge of the selection (default 100 = full range). */
    initialEnd?: number;
    /** Minimum selection width as a percentage (default 2). */
    minSelectionWidth?: number;
    /** Show the built-in reset button (default true). */
    showResetButton?: boolean;
    /** Extra class for the selection highlight band. */
    selectionClassName?: string;
    /** Extra class for the two resize handles. */
    handleClassName?: string;
    /** Extra class for the hover cursor line. */
    cursorLineClassName?: string;
    /** Minimap content rendered inside the track (e.g. span bars). */
    children?: React.ReactNode;
    className?: string;
}

type DragMode =
    | "none"
    | "left-handle"
    | "right-handle"
    | "selection"
    | "create-selection";

export function TimeBrush({
    onSelectionChange,
    initialStart = 0,
    initialEnd = 100,
    minSelectionWidth = 2,
    showResetButton = true,
    selectionClassName = "",
    handleClassName = "bg-border hover:bg-brand/60",
    cursorLineClassName = "bg-muted-foreground/50",
    children,
    className,
}: TimeBrushProps) {
    const [selection, setSelection] = useState({
        start: initialStart,
        end: initialEnd,
    });
    const { start: selectionStart, end: selectionEnd } = selection;

    // Cursor line is driven via rAF refs — no React re-render on every mousemove.
    const cursorLineRef = useRef<HTMLDivElement>(null);
    const rafIdRef = useRef<number>(0);

    // Drag state lives in refs so the global mousemove handler always sees fresh values.
    const dragModeRef = useRef<DragMode>("none");
    const dragStartXRef = useRef(0);
    const dragStartSelectionRef = useRef({ start: 0, end: 0 });
    const containerRef = useRef<HTMLDivElement>(null);

    // Keep a stable ref to the callback so the mousemove handler never goes stale.
    const onSelectionChangeRef = useRef(onSelectionChange);
    onSelectionChangeRef.current = onSelectionChange;

    const isDefaultSelection =
        selectionStart === initialStart && selectionEnd === initialEnd;

    // ── Cursor line (rAF) ──────────────────────────────────────────────────

    const updateCursorLine = useCallback((position: number | null) => {
        cancelAnimationFrame(rafIdRef.current);
        rafIdRef.current = requestAnimationFrame(() => {
            const el = cursorLineRef.current;
            if (!el) return;
            if (position === null) {
                el.style.display = "none";
            } else {
                el.style.display = "";
                el.style.left = `${position}%`;
            }
        });
    }, []);

    // ── Local mousedown handlers ───────────────────────────────────────────

    const handleLeftHandleMouseDown = useCallback(
        (e: React.MouseEvent) => {
            e.preventDefault();
            e.stopPropagation();
            dragModeRef.current = "left-handle";
            dragStartXRef.current = e.clientX;
            dragStartSelectionRef.current = {
                start: selectionStart,
                end: selectionEnd,
            };
        },
        [selectionStart, selectionEnd],
    );

    const handleRightHandleMouseDown = useCallback(
        (e: React.MouseEvent) => {
            e.preventDefault();
            e.stopPropagation();
            dragModeRef.current = "right-handle";
            dragStartXRef.current = e.clientX;
            dragStartSelectionRef.current = {
                start: selectionStart,
                end: selectionEnd,
            };
        },
        [selectionStart, selectionEnd],
    );

    const handleSelectionMouseDown = useCallback(
        (e: React.MouseEvent) => {
            if (isDefaultSelection) return;
            e.preventDefault();
            e.stopPropagation();
            dragModeRef.current = "selection";
            dragStartXRef.current = e.clientX;
            dragStartSelectionRef.current = {
                start: selectionStart,
                end: selectionEnd,
            };
        },
        [selectionStart, selectionEnd, isDefaultSelection],
    );

    const handleTrackMouseDown = useCallback(
        (e: React.MouseEvent) => {
            const container = containerRef.current;
            if (!container) return;
            const rect = container.getBoundingClientRect();
            const clickPct = ((e.clientX - rect.left) / rect.width) * 100;
            if (
                isDefaultSelection ||
                clickPct < selectionStart ||
                clickPct > selectionEnd
            ) {
                e.preventDefault();
                e.stopPropagation();
                dragModeRef.current = "create-selection";
                dragStartXRef.current = e.clientX;
                dragStartSelectionRef.current = {
                    start: clickPct,
                    end: clickPct,
                };
                updateCursorLine(null);
            }
        },
        [isDefaultSelection, selectionStart, selectionEnd, updateCursorLine],
    );

    const handleTrackMouseMove = useCallback(
        (e: React.MouseEvent) => {
            const container = containerRef.current;
            if (!container) return;
            const rect = container.getBoundingClientRect();
            const hoverPct = Math.max(
                0,
                Math.min(100, ((e.clientX - rect.left) / rect.width) * 100),
            );
            if (
                isDefaultSelection ||
                hoverPct <= selectionStart ||
                hoverPct >= selectionEnd
            ) {
                updateCursorLine(hoverPct);
            } else {
                updateCursorLine(null);
            }
        },
        [isDefaultSelection, selectionStart, selectionEnd, updateCursorLine],
    );

    const handleTrackMouseLeave = useCallback(() => {
        updateCursorLine(null);
    }, [updateCursorLine]);

    // ── Global mousemove / mouseup (attached once, reads from refs) ────────

    useEffect(() => {
        const handleMouseMove = (e: MouseEvent) => {
            if (dragModeRef.current === "none") return;
            const container = containerRef.current;
            if (!container) return;
            const rect = container.getBoundingClientRect();
            const deltaPx = e.clientX - dragStartXRef.current;
            const deltaPct = (deltaPx / rect.width) * 100;
            const { start: origStart, end: origEnd } =
                dragStartSelectionRef.current;

            if (dragModeRef.current === "left-handle") {
                const newStart = Math.max(
                    0,
                    Math.min(origEnd - minSelectionWidth, origStart + deltaPct),
                );
                setSelection({ start: newStart, end: origEnd });
                onSelectionChangeRef.current?.(newStart, origEnd);
            } else if (dragModeRef.current === "right-handle") {
                const newEnd = Math.max(
                    origStart + minSelectionWidth,
                    Math.min(100, origEnd + deltaPct),
                );
                setSelection({ start: origStart, end: newEnd });
                onSelectionChangeRef.current?.(origStart, newEnd);
            } else if (dragModeRef.current === "selection") {
                const width = origEnd - origStart;
                let newStart = origStart + deltaPct;
                let newEnd = origEnd + deltaPct;
                if (newStart < 0) {
                    newStart = 0;
                    newEnd = width;
                }
                if (newEnd > 100) {
                    newEnd = 100;
                    newStart = 100 - width;
                }
                setSelection({ start: newStart, end: newEnd });
                onSelectionChangeRef.current?.(newStart, newEnd);
            } else if (dragModeRef.current === "create-selection") {
                const currentPct = Math.max(
                    0,
                    Math.min(100, ((e.clientX - rect.left) / rect.width) * 100),
                );
                const clickPos = origStart; // origStart holds the initial click position
                const newStart =
                    currentPct < clickPos
                        ? Math.max(0, currentPct)
                        : clickPos;
                const newEnd =
                    currentPct < clickPos
                        ? clickPos
                        : Math.min(100, currentPct);
                if (newEnd - newStart >= minSelectionWidth) {
                    setSelection({ start: newStart, end: newEnd });
                    onSelectionChangeRef.current?.(newStart, newEnd);
                }
            }
        };

        const handleMouseUp = () => {
            dragModeRef.current = "none";
        };

        document.addEventListener("mousemove", handleMouseMove);
        document.addEventListener("mouseup", handleMouseUp);
        return () => {
            document.removeEventListener("mousemove", handleMouseMove);
            document.removeEventListener("mouseup", handleMouseUp);
        };
    }, [minSelectionWidth]);

    const handleReset = useCallback(() => {
        setSelection({ start: initialStart, end: initialEnd });
        onSelectionChangeRef.current?.(initialStart, initialEnd);
    }, [initialStart, initialEnd]);

    return (
        <div className={cn("relative select-none", className)} ref={containerRef}>
            {/* Built-in reset button (shown when not at default) */}
            {showResetButton && !isDefaultSelection && (
                <button
                    onClick={handleReset}
                    className="absolute bottom-1 right-full mr-2 rounded border border-border bg-background px-2 py-0.5 text-[10px] text-muted-foreground hover:text-foreground transition-colors"
                >
                    Reset
                </button>
            )}

            {/* Track */}
            <div className="relative h-5">
                {/* Extended click target (larger than the visible track) */}
                <div
                    className="absolute inset-0 -bottom-2 -top-3 cursor-crosshair"
                    onMouseDown={handleTrackMouseDown}
                    onMouseMove={handleTrackMouseMove}
                    onMouseLeave={handleTrackMouseLeave}
                />

                {/* Minimap content (span bars, etc.) */}
                <div className="absolute inset-0 overflow-hidden rounded-sm">
                    {children}
                </div>

                {/* Dimmed overlay outside selection */}
                {!isDefaultSelection && (
                    <>
                        <div
                            className="absolute top-0 h-full bg-background/50"
                            style={{ left: 0, width: `${selectionStart}%` }}
                        />
                        <div
                            className="absolute top-0 h-full bg-background/50"
                            style={{
                                left: `${selectionEnd}%`,
                                width: `${100 - selectionEnd}%`,
                            }}
                        />
                    </>
                )}

                {/* Selection highlight band */}
                <div
                    className={cn(
                        "absolute top-0 h-full border-x",
                        selectionClassName,
                        isDefaultSelection
                            ? "cursor-default"
                            : "cursor-grab active:cursor-grabbing",
                    )}
                    style={{
                        left: `${selectionStart}%`,
                        width: `${selectionEnd - selectionStart}%`,
                    }}
                    onMouseDown={
                        isDefaultSelection
                            ? handleTrackMouseDown
                            : handleSelectionMouseDown
                    }
                    onMouseMove={handleTrackMouseMove}
                    onMouseLeave={handleTrackMouseLeave}
                />

                {/* Cursor hover line (manipulated via ref, never causes re-render) */}
                <div
                    ref={cursorLineRef}
                    className={cn(
                        "pointer-events-none absolute -top-3 bottom-0 w-px",
                        cursorLineClassName,
                    )}
                    style={{
                        display: "none",
                        transform: "translateX(-50%)",
                        zIndex: 10,
                    }}
                />

                {/* Left resize handle */}
                <div
                    className="absolute top-0 h-full cursor-ew-resize"
                    style={{
                        left: `${selectionStart}%`,
                        transform: "translateX(-50%)",
                        width: "16px",
                    }}
                    onMouseDown={handleLeftHandleMouseDown}
                >
                    <div
                        className={cn(
                            "absolute left-1/2 top-0 h-full w-0.5 -translate-x-1/2 rounded-full transition-colors",
                            handleClassName,
                        )}
                    />
                </div>

                {/* Right resize handle */}
                <div
                    className="absolute top-0 h-full cursor-ew-resize"
                    style={{
                        left: `${selectionEnd}%`,
                        transform: "translateX(-50%)",
                        width: "16px",
                    }}
                    onMouseDown={handleRightHandleMouseDown}
                >
                    <div
                        className={cn(
                            "absolute left-1/2 top-0 h-full w-0.5 -translate-x-1/2 rounded-full transition-colors",
                            handleClassName,
                        )}
                    />
                </div>
            </div>
        </div>
    );
}
