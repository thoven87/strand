import { useState } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import {
    useQuery,
    useMutation,
    useQueryClient,
    keepPreviousData,
} from "@tanstack/react-query";
import {
    Link,
    useNavigate,
    useParams,
    useSearch,
} from "@tanstack/react-router";
import { getTask, cancelTask, requeueTask, getChildTasks } from "@/api/tasks";
import { getEventTriggerForTask } from "@/api/events";
import { getTaskMetrics, type TaskMetrics } from "@/api/metrics";
import { RetryDialog } from "@/components/RetryDialog";
import { SignalDialog } from "@/components/SignalDialog";
import { UpdateDialog } from "@/components/UpdateDialog";
import type { RetryOptions } from "@/api/types";
import { getRuns, getCheckpoints } from "@/api/runs";
import {
    getWorkflowHistory,
    getWorkflowState,
    getVersionMarkers,
    sendSignal,
    sendUpdate,
    type VersionMarker,
} from "@/api/workflows";

import { qk } from "@/lib/queryKeys";
import { useAutoRefresh } from "@/lib/useAutoRefresh";
import { AutoRefreshControl } from "@/components/AutoRefreshControl";
import { StatusBadge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { RelativeTime } from "@/components/RelativeTime";
import { LiveTimer } from "@/components/LiveTimer";
import { JsonView } from "@/components/JsonView";
import {
    ChevronDown,
    ChevronRight,
    RefreshCw,
    XCircle,
    ArrowUpRight,
    Send,
    GitBranch,
    Zap,
} from "lucide-react";
import { TriggerDialog } from "@/components/TriggerDialog";
import type { Checkpoint, Run, TaskState, HistoryEvent } from "@/api/types";
import { fmtDuration } from "@/lib/utils";

// ── helpers ───────────────────────────────────────────────────────────────

/**
 * Parses a raw failure_reason JSON string and returns a human-readable message.
 * Strand serialises errors as {"error":"..."}  or {"message":"...","name":"..."}.
 * Falls back to the raw string if parsing fails or the key isn't present.
 */
function parseFailureMessage(raw: string): string {
    try {
        const obj = JSON.parse(raw) as Record<string, unknown>;
        // Prefer the 'message' key (LocalizedError / NSError format)
        if (typeof obj["message"] === "string" && obj["message"])
            return obj["message"];
        // Fall back to 'error' key (Strand internal format)
        if (typeof obj["error"] === "string" && obj["error"])
            return obj["error"];
        // Last resort: pretty-print the whole object
        return JSON.stringify(obj, null, 2);
    } catch {
        return raw;
    }
}

/**
 * Walks a parsed JSON value and replaces every primitive (string, number,
 * boolean) with `null`, keeping the structural shape (objects and arrays).
 * Used to pre-seed the TriggerDialog editor with the input schema of a past
 * run so the user can see what fields are expected without reusing stale values.
 */
function nullifyValues(v: unknown): unknown {
    if (v === null || v === undefined) return null;
    if (typeof v !== "object") return null; // primitive → null
    if (Array.isArray(v)) return v.map(nullifyValues);
    return Object.fromEntries(
        Object.entries(v as Record<string, unknown>).map(([k, val]) => [
            k,
            nullifyValues(val),
        ]),
    );
}

function paramsTemplate(raw: string | null | undefined): string {
    if (!raw) return "{}";
    try {
        return JSON.stringify(nullifyValues(JSON.parse(raw)), null, 2);
    } catch {
        return "{}";
    }
}

/** Structured failure object stored by Strand in failure_reason. */
interface ParsedFailure {
    name?: string;
    message?: string;
    cause?: ParsedFailure;
    source?: { file_id?: string; line?: number };
}

function parsedFailure(raw: string): ParsedFailure | null {
    try {
        const obj = JSON.parse(raw) as ParsedFailure;
        return typeof obj === "object" && obj !== null ? obj : null;
    } catch {
        return null;
    }
}

/** One node in the cause chain. */
function FailureNode({
    failure,
    depth = 0,
}: {
    failure: ParsedFailure;
    depth?: number;
}) {
    const msg = failure.message ?? parseFailureMessage(JSON.stringify(failure));
    const src = failure.source;
    const indent = depth > 0;

    return (
        <div className={indent ? "mt-2 pl-3 border-l border-red-500/20" : ""}>
            {/* type badge + message */}
            <div className="flex items-start gap-2 flex-wrap">
                {failure.name && (
                    <span className="shrink-0 text-[10px] font-mono bg-red-500/15 text-red-400 rounded px-1.5 py-0.5">
                        {failure.name}
                    </span>
                )}
                <p className="text-xs text-red-200 font-mono whitespace-pre-wrap break-words leading-relaxed flex-1">
                    {msg}
                </p>
            </div>
            {/* source location */}
            {src?.file_id && (
                <p className="mt-0.5 text-[10px] font-mono text-muted-foreground/60">
                    {src.file_id}
                    {src.line ? `:${src.line}` : ""}
                </p>
            )}
            {/* recursive cause */}
            {failure.cause && (
                <FailureNode failure={failure.cause} depth={depth + 1} />
            )}
        </div>
    );
}

/** Renders a failure_reason string with typed cause chain, source location, + raw toggle. */
function FailureReasonView({ raw }: { raw: string }) {
    const [showRaw, setShowRaw] = useState(false);
    const parsed = parsedFailure(raw);

    return (
        <div className="space-y-1.5">
            {parsed ? (
                <FailureNode failure={parsed} />
            ) : (
                <p className="text-xs text-red-300 font-mono whitespace-pre-wrap break-words">
                    {parseFailureMessage(raw)}
                </p>
            )}
            <button
                onClick={() => setShowRaw((v) => !v)}
                className="text-[10px] text-muted-foreground/50 hover:text-muted-foreground transition-colors"
            >
                {showRaw ? "Hide raw JSON" : "Show raw JSON"}
            </button>
            {showRaw && (
                <pre className="text-[10px] font-mono text-muted-foreground/50 whitespace-pre-wrap break-all bg-secondary/20 rounded p-2">
                    {raw}
                </pre>
            )}
        </div>
    );
}

const isTerminal = (s: string) =>
    ["COMPLETED", "FAILED", "CANCELLED", "CONTINUED_AS_NEW"].includes(s);

function taskDurationMs(
    startAt: string, // firstRunAt ?? createdAt
    completedAt: string | null,
): number | null {
    if (!completedAt) return null;
    return new Date(completedAt).getTime() - new Date(startAt).getTime();
}

// ── Event colour ──────────────────────────────────────────────────────────

function eventColour(type: string): string {
    if (type.startsWith("WORKFLOW_")) return "bg-blue-400";
    if (type === "ACTIVITY_COMPLETED") return "bg-green-400";
    if (type === "ACTIVITY_FAILED") return "bg-red-400";
    if (type.startsWith("ACTIVITY_")) return "bg-yellow-400";
    if (type === "UPDATE_APPLIED") return "bg-violet-400";
    if (type.startsWith("SIGNAL_")) return "bg-purple-400";
    if (type.startsWith("CHILD_")) return "bg-cyan-400";
    if (type.startsWith("TIMER_")) return "bg-green-400";
    if (type.startsWith("EVENT_")) return "bg-orange-400";
    if (type.startsWith("CONDITION_")) return "bg-pink-400";
    return "bg-muted-foreground";
}

function eventLabel(type: string): string {
    if (type === "UPDATE_APPLIED") return "Update applied";
    return type
        .replace(/_/g, " ")
        .toLowerCase()
        .replace(/^\w/, (c) => c.toUpperCase());
}

/**
 * Extract a short human-readable annotation from an event's raw JSON data.
 * Strips internal `$$activity:`, `$$child:` etc. prefixes.
 */
function eventSummary(_type: string, raw: string | null): string | null {
    if (!raw) return null;
    try {
        const d = JSON.parse(raw) as Record<string, unknown>;
        // Activity events carry an `activity` field with the registered name.
        if (typeof d.activity === "string") return d.activity;
        // Child workflow events carry a `workflow` field.
        if (typeof d.workflow === "string") return d.workflow;
        // Signal events carry a `name` field.
        if (typeof d.name === "string") return d.name;
        // Event-received / event-wait events carry `event_name`.
        if (typeof d.event_name === "string") return d.event_name;
        // Timer-started carries `duration_ms` — format as human-readable duration.
        if (typeof d.duration_ms === "number")
            return fmtDuration(d.duration_ms as number);
        return null;
    } catch {
        return null;
    }
}

// ── ACTIVITY_STARTED inline detail ────────────────────────────────────────

interface ActivityStartedInfo {
    attempt: number;
    workerID: string | null;
}

/**
 * Parses the `ActivityStartedData` payload for inline display in the timeline.
 * Returns `null` when the event data is absent or unparseable.
 */
function parseActivityStarted(raw: string | null): ActivityStartedInfo | null {
    if (!raw) return null;
    try {
        const d = JSON.parse(raw) as Record<string, unknown>;
        return {
            attempt: typeof d.attempt === "number" ? d.attempt : 1,
            workerID: typeof d.worker_id === "string" ? d.worker_id : null,
        };
    } catch {
        return null;
    }
}

// ── Event grouping ──────────────────────────────────────────────────

interface EventGroup {
    eventType: string;
    summary: string | null;
    count: number;
    firstSeq: number;
    firstCreatedAt: string;
    lastCreatedAt: string;
    events: HistoryEvent[];
}

/**
 * Collapse consecutive events with the same type + same logical summary into groups.
 *
 * Two merging strategies:
 * ① Consecutive: adjacent events with identical (eventType, summary) → always merged.
 *    This handles ACTIVITY_SCHEDULED ×N batches written in one activation.
 *
 * ② Activity batch (non-consecutive): for ACTIVITY_STARTED and ACTIVITY_COMPLETED,
 *    look back through the preceding groups for a same-(eventType, summary) match.
 *    Merge if every group in between is also an ACTIVITY event for the same activity
 *    name. This handles the sequential fan-out pattern:
 *      SCHEDULED ×8, STARTED-1, COMPLETED-1, STARTED-2, COMPLETED-2, …
 *    which becomes:
 *      SCHEDULED ×8 | STARTED ×8 | COMPLETED ×8
 *    The ×N group is anchored at the timestamp of the FIRST event in the group.
 */
function groupEvents(events: HistoryEvent[]): EventGroup[] {
    const groups: EventGroup[] = [];
    for (const evt of events) {
        const s = eventSummary(evt.eventType, evt.eventData);
        const last = groups[groups.length - 1];

        // ① Consecutive same-type + same-summary
        if (last && last.eventType === evt.eventType && last.summary === s) {
            last.count++;
            last.lastCreatedAt = evt.createdAt;
            last.events.push(evt);
            continue;
        }

        // ② Non-consecutive activity batch merging.
        // Only applies to STARTED/COMPLETED for a named activity.
        if (
            s !== null &&
            (evt.eventType === "ACTIVITY_STARTED" ||
                evt.eventType === "ACTIVITY_COMPLETED")
        ) {
            // Search backwards for a prior group with the same (type, summary).
            // Stop the search as soon as we encounter a group that is NOT an
            // activity event for the same activity — that signals a boundary
            // between unrelated batches.
            let matchIdx = -1;
            for (let i = groups.length - 1; i >= 0; i--) {
                const g = groups[i];
                if (g.eventType === evt.eventType && g.summary === s) {
                    matchIdx = i;
                    break;
                }
                // Allow skipping past ACTIVITY_STARTED, ACTIVITY_COMPLETED, and
                // ACTIVITY_SCHEDULED for the same activity name; anything else
                // (different activity, different event category) breaks the batch.
                const sameActivity =
                    g.summary === s &&
                    (g.eventType === "ACTIVITY_STARTED" ||
                        g.eventType === "ACTIVITY_COMPLETED" ||
                        g.eventType === "ACTIVITY_SCHEDULED");
                if (!sameActivity) break;
            }
            if (matchIdx !== -1) {
                const match = groups[matchIdx];
                match.count++;
                match.lastCreatedAt = evt.createdAt;
                match.events.push(evt);
                continue;
            }
        }

        // ③ New group
        groups.push({
            eventType: evt.eventType,
            summary: s,
            count: 1,
            firstSeq: evt.seq,
            firstCreatedAt: evt.createdAt,
            lastCreatedAt: evt.createdAt,
            events: [evt],
        });
    }
    return groups;
}

// ── ActivityTimeline ────────────────────────────────────────────────────────

function ActivityTimeline({
    namespace,
    queue,
    taskId,
    taskCreatedAt,
}: {
    namespace: string;
    queue: string;
    taskId: string;
    taskCreatedAt: string;
}) {
    const { data = [], isLoading } = useQuery({
        queryKey: qk.workflows.history(namespace, queue, taskId),
        queryFn: () => getWorkflowHistory(namespace, queue, taskId),
        refetchInterval: 3_000,
    });
    const [expanded, setExpanded] = useState<Set<number>>(new Set());
    const [typeFilter, setTypeFilter] = useState<string | null>(null);

    const baseMs = new Date(taskCreatedAt).getTime();
    const allGroups = groupEvents(data);
    // Unique event types for the filter pills (preserve order of first appearance)
    const eventTypes = Array.from(new Set(data.map((e) => e.eventType)));
    const groups = typeFilter
        ? allGroups.filter((g) => g.eventType === typeFilter)
        : allGroups;

    if (isLoading)
        return (
            <p className="text-xs text-muted-foreground py-4 text-center">
                Loading…
            </p>
        );

    if (allGroups.length === 0)
        return (
            <p className="text-xs text-muted-foreground py-4 text-center">
                No history events yet.
            </p>
        );

    return (
        <div className="space-y-0">
            {/* Event-type filter pills */}
            {eventTypes.length > 1 && (
                <div className="flex flex-wrap gap-1 mb-3">
                    <button
                        onClick={() => setTypeFilter(null)}
                        className={`text-[10px] px-2 py-0.5 rounded-full border transition-colors ${
                            typeFilter === null
                                ? "bg-secondary text-foreground border-border"
                                : "border-border/40 text-muted-foreground hover:text-foreground"
                        }`}
                    >
                        All
                    </button>
                    {eventTypes.map((t) => (
                        <button
                            key={t}
                            onClick={() =>
                                setTypeFilter(typeFilter === t ? null : t)
                            }
                            className={`text-[10px] px-2 py-0.5 rounded-full border transition-colors ${
                                typeFilter === t
                                    ? "bg-secondary text-foreground border-border"
                                    : "border-border/40 text-muted-foreground hover:text-foreground"
                            }`}
                        >
                            {eventLabel(t)}
                        </button>
                    ))}
                </div>
            )}
            {groups.map((grp, gi) => {
                const offsetMs =
                    new Date(grp.firstCreatedAt).getTime() - baseMs;
                const isLast = gi === groups.length - 1;
                const isExpanded = expanded.has(grp.firstSeq);
                const colour = eventColour(grp.eventType);
                const labelTextColour = colour
                    .replace("bg-", "text-")
                    .replace("/40", "");

                return (
                    <div key={grp.firstSeq}>
                        {/* Group header row — always clickable */}
                        <div
                            className="flex gap-3 group cursor-pointer"
                            onClick={() =>
                                setExpanded((prev) => {
                                    const next = new Set(prev);
                                    next.has(grp.firstSeq)
                                        ? next.delete(grp.firstSeq)
                                        : next.add(grp.firstSeq);
                                    return next;
                                })
                            }
                        >
                            <div className="flex flex-col items-center w-5 shrink-0 pt-0.5">
                                <div
                                    className={`w-2 h-2 rounded-full shrink-0 mt-1 ${colour}`}
                                />
                                {(!isLast || (isExpanded && grp.count > 1)) && (
                                    <div className="w-px flex-1 bg-border/40 mt-1" />
                                )}
                            </div>
                            <div className="pb-3 min-w-0 flex-1">
                                <div className="flex items-baseline gap-2 flex-wrap">
                                    {/* Colour-coded label pill */}
                                    <span
                                        className={`text-xs font-medium ${labelTextColour}`}
                                    >
                                        {eventLabel(grp.eventType)}
                                    </span>
                                    {grp.summary && (
                                        <span className="text-[11px] font-mono text-muted-foreground/80 truncate">
                                            {grp.summary}
                                        </span>
                                    )}
                                    {/* ACTIVITY_STARTED: attempt badge + muted worker ID */}
                                    {grp.eventType === "ACTIVITY_STARTED" &&
                                        grp.count === 1 &&
                                        (() => {
                                            const info = parseActivityStarted(
                                                grp.events[0]?.eventData ??
                                                    null,
                                            );
                                            if (!info) return null;
                                            return (
                                                <>
                                                    {info.attempt > 1 && (
                                                        <span className="text-[10px] px-1.5 py-0.5 rounded bg-secondary/70 text-muted-foreground tabular-nums">
                                                            attempt{" "}
                                                            {info.attempt}
                                                        </span>
                                                    )}
                                                    {info.workerID && (
                                                        <span className="text-[10px] font-mono text-muted-foreground/40 truncate">
                                                            {info.workerID}
                                                        </span>
                                                    )}
                                                </>
                                            );
                                        })()}
                                    {/* Count badge for grouped events */}
                                    {grp.count > 1 && (
                                        <span className="text-[10px] px-1.5 py-0.5 rounded bg-secondary text-muted-foreground tabular-nums">
                                            ×{grp.count}
                                        </span>
                                    )}
                                    <span className="text-[10px] text-muted-foreground/40">
                                        {isExpanded ? "▴" : "▾"}
                                    </span>
                                    <span className="text-[11px] text-muted-foreground/60 ml-auto shrink-0 tabular-nums">
                                        +{fmtDuration(offsetMs)}
                                    </span>
                                </div>
                            </div>
                        </div>

                        {/* Expanded content */}
                        {isExpanded &&
                            grp.count === 1 &&
                            grp.events[0].eventData && (
                                <div className="ml-8 mb-3 rounded border border-border/30 bg-secondary/10 p-2 overflow-auto max-h-48">
                                    <JsonView
                                        value={(() => {
                                            const raw = grp.events[0].eventData;
                                            try {
                                                return JSON.stringify(
                                                    JSON.parse(raw),
                                                    null,
                                                    2,
                                                );
                                            } catch {
                                                return raw;
                                            }
                                        })()}
                                    />
                                </div>
                            )}
                        {isExpanded &&
                            grp.count > 1 &&
                            grp.events.map((evt, ei) => {
                                const evtOffsetMs =
                                    new Date(evt.createdAt).getTime() - baseMs;
                                const isEvtLast =
                                    ei === grp.events.length - 1 && isLast;
                                // Extract the step name and optional seq_num from event data.
                                // The group header already shows the event type; here we show
                                // the specific step name (activity / workflow / event name) so
                                // each row is scannable without referring back to the header.
                                const stepName = eventSummary(
                                    evt.eventType,
                                    evt.eventData,
                                );
                                let seqNum: string | null = null;
                                try {
                                    const d = JSON.parse(
                                        evt.eventData ?? "{}",
                                    ) as Record<string, unknown>;
                                    // seq_num may be a string or a number depending on the event source
                                    if (typeof d.seq_num === "string")
                                        seqNum = d.seq_num;
                                    else if (typeof d.seq_num === "number")
                                        seqNum = String(d.seq_num);
                                } catch {}
                                return (
                                    <div key={evt.seq} className="flex gap-3">
                                        <div className="flex flex-col items-center w-5 shrink-0 pt-0.5">
                                            <div className="w-1.5 h-1.5 rounded-full shrink-0 mt-1.5 border border-border/60" />
                                            {!isEvtLast && (
                                                <div className="w-px flex-1 bg-border/20 mt-1" />
                                            )}
                                        </div>
                                        <div className="pb-2 min-w-0 flex-1 pl-1">
                                            <div className="flex items-baseline gap-2 min-w-0">
                                                {stepName ? (
                                                    <span className="text-[11px] font-mono text-foreground/70 truncate">
                                                        {stepName}
                                                    </span>
                                                ) : (
                                                    <span className="text-[11px] text-muted-foreground tabular-nums shrink-0">
                                                        {ei + 1}
                                                    </span>
                                                )}
                                                {seqNum && (
                                                    <span className="text-[10px] text-muted-foreground/40 tabular-nums shrink-0">
                                                        #{seqNum}
                                                    </span>
                                                )}
                                                <span className="text-[11px] text-muted-foreground/60 ml-auto shrink-0 tabular-nums">
                                                    +{fmtDuration(evtOffsetMs)}
                                                </span>
                                            </div>
                                        </div>
                                    </div>
                                );
                            })}
                    </div>
                );
            })}
        </div>
    );
}

// ── ChildActivities ───────────────────────────────────────────────────────

function ChildActivities({
    namespace,
    queue,
    taskId,
    parentCreatedAt,
    parentCompletedAt,
}: {
    namespace: string;
    queue: string;
    taskId: string;
    parentCreatedAt: string;
    parentCompletedAt: string | null;
}) {
    const { data } = useQuery({
        queryKey: qk.tasks.children(namespace, queue, taskId),
        queryFn: () => getChildTasks(namespace, queue, taskId),
        enabled: !!queue && !!taskId,
        refetchInterval: 5_000,
    });

    if (!data || data.items.length === 0) return null;

    const parentStart = new Date(parentCreatedAt).getTime();
    const parentEnd = parentCompletedAt
        ? new Date(parentCompletedAt).getTime()
        : Date.now();
    const parentDuration = Math.max(parentEnd - parentStart, 1);

    return (
        <section className="mt-4">
            <h2 className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                Child Activities ({data.items.length})
            </h2>
            <div className="rounded-lg border border-border bg-card/40 divide-y divide-border/40 overflow-hidden">
                {data.items.map((child) => {
                    const childStart = new Date(child.createdAt).getTime();
                    const childEnd = child.completedAt
                        ? new Date(child.completedAt).getTime()
                        : Date.now();
                    const childDurationMs = childEnd - childStart;
                    const offsetPct =
                        ((childStart - parentStart) / parentDuration) * 100;
                    const widthPct = (childDurationMs / parentDuration) * 100;

                    return (
                        <div
                            key={child.id}
                            className="flex items-center gap-3 px-4 py-2.5 hover:bg-secondary/10 transition-colors"
                        >
                            <StatusBadge state={child.state as TaskState} />
                            <Link
                                to="/$namespace/tasks/$taskId"
                                params={{ namespace, taskId: child.id }}
                                search={{ queue: child.queue }}
                                className="text-xs font-medium text-foreground hover:text-brand transition-colors flex-1 min-w-0 truncate"
                            >
                                {child.name}
                            </Link>
                            {/* Attempt badge — only shown on retry */}
                            {child.attempt > 1 && (
                                <span className="text-[10px] font-mono px-1.5 py-0.5 rounded border bg-amber-500/10 text-amber-500/80 border-amber-500/25 shrink-0">
                                    ×{child.attempt}
                                </span>
                            )}
                            <span className="text-[11px] text-muted-foreground shrink-0 tabular-nums">
                                {fmtDuration(childDurationMs)}
                            </span>
                            {/* Mini Gantt bar */}
                            <div className="relative w-24 h-2 bg-secondary/40 rounded-full shrink-0 overflow-hidden">
                                <div
                                    className="absolute top-0 h-full rounded-full bg-brand/60"
                                    style={{
                                        left: `${Math.min(offsetPct, 95)}%`,
                                        width: `${Math.max(Math.min(widthPct, 100 - offsetPct), 4)}%`,
                                    }}
                                />
                            </div>
                            <Link
                                to="/$namespace/tasks/$taskId"
                                params={{ namespace, taskId: child.id }}
                                search={{ queue: child.queue }}
                                className="text-muted-foreground hover:text-foreground transition-colors shrink-0"
                            >
                                <ArrowUpRight size={13} />
                            </Link>
                        </div>
                    );
                })}
            </div>
        </section>
    );
}

// ── Checkpoint name formatting ───────────────────────────────────────────

/**
 * Convert an internal checkpoint key like `$$activity:FetchISSPositionActivity#2`
 * into a readable label like `FetchISSPositionActivity ×2`.
 */
function formatCheckpointName(raw: string): string {
    // Strip leading $$
    let s = raw.startsWith("$$") ? raw.slice(2) : raw;
    // Extract optional #N repeat suffix
    const repeatMatch = s.match(/^(.*?)#(\d+)$/);
    const repeat = repeatMatch ? ` ×${repeatMatch[2]}` : "";
    if (repeatMatch) s = repeatMatch[1];
    // Strip well-known prefixes
    if (s.startsWith("activity:")) return s.slice(9) + repeat;
    if (s.startsWith("local:")) return s.slice(6) + " (local)" + repeat;
    if (s.startsWith("child:")) return s.slice(6) + " (child)" + repeat;
    if (s.startsWith("waitForEvent:")) return "wait · " + s.slice(13) + repeat;
    if (s.startsWith("version:")) return "version · " + s.slice(8) + repeat;
    if (s === "conditionDeadline" || s.startsWith("conditionDeadline"))
        return "condition deadline" + repeat;
    // Generic: turn camelCase / underscores into readable text, keep ×N
    return s + repeat;
}

// ── RunCheckpoints ────────────────────────────────────────────────────────

function RunCheckpoints({
    namespace,
    queue,
    taskId,
    runId,
}: {
    namespace: string;
    queue: string;
    taskId: string;
    runId: string;
}) {
    const { data = [] } = useQuery({
        queryKey: qk.runs.checkpoints(namespace, queue, taskId, runId),
        queryFn: () => getCheckpoints(namespace, queue, taskId, runId),
    });

    if (data.length === 0)
        return (
            <p className="text-xs text-muted-foreground pl-3 pt-2">
                No checkpoints recorded.
            </p>
        );

    return (
        <div className="pl-3 pt-2 space-y-1.5">
            {data.map((cp: Checkpoint, i: number) => (
                <JsonView
                    key={i}
                    label={formatCheckpointName(cp.name)}
                    value={cp.state}
                />
            ))}
        </div>
    );
}

// ── RunRow ────────────────────────────────────────────────────────────────

function RunRow({
    namespace,
    run,
    queue,
    taskId,
}: {
    namespace: string;
    run: Run;
    queue: string;
    taskId: string;
}) {
    const [open, setOpen] = useState(false);

    const ms =
        run.startedAt && run.finishedAt
            ? new Date(run.finishedAt).getTime() -
              new Date(run.startedAt).getTime()
            : null;

    const duration = ms !== null ? fmtDuration(ms) : null;

    return (
        <div className="rounded border border-border/60 overflow-hidden">
            <button
                onClick={() => setOpen((o) => !o)}
                className="flex w-full items-center gap-2.5 px-3 py-2 text-left hover:bg-secondary/20 transition-colors"
            >
                {open ? (
                    <ChevronDown
                        size={12}
                        className="text-muted-foreground shrink-0"
                    />
                ) : (
                    <ChevronRight
                        size={12}
                        className="text-muted-foreground shrink-0"
                    />
                )}
                <span className="text-xs text-muted-foreground">
                    Attempt {run.attempt}
                </span>
                <StatusBadge state={run.state as TaskState} />
                {duration && (
                    <span className="text-xs text-muted-foreground ml-auto">
                        {duration}
                    </span>
                )}
                {run.sdkVersion && (
                    <span className="text-[11px] font-mono text-muted-foreground/50 border border-border/40 rounded px-1 hidden sm:block">
                        v{run.sdkVersion}
                    </span>
                )}
                {run.workerID && (
                    <span className="text-[11px] font-mono text-muted-foreground/60 ml-1 hidden sm:block truncate max-w-32">
                        {run.workerID}
                    </span>
                )}
            </button>
            {open && (
                <div className="border-t border-border/40 pb-2">
                    {/* Failure reason — shown for failed / cancelled runs */}
                    {run.failureReason && (
                        <div className="px-3 pt-2 pb-1">
                            <p className="text-[10px] uppercase tracking-wide font-medium text-red-400/70 mb-1">
                                Error
                            </p>
                            <FailureReasonView raw={run.failureReason} />
                        </div>
                    )}
                    {/* Next retry — shown only for SLEEPING runs with a scheduled availableAt */}
                    {run.state === "SLEEPING" && run.availableAt && (
                        <div className="px-3 pt-2 pb-1 flex items-center justify-between">
                            <p className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground shrink-0">
                                Next retry
                            </p>
                            <RelativeTime iso={run.availableAt} />
                        </div>
                    )}
                    <RunCheckpoints
                        namespace={namespace}
                        queue={queue}
                        taskId={taskId}
                        runId={run.id}
                    />
                </div>
            )}
        </div>
    );
}

// ── WorkflowStateView ─────────────────────────────────────────────────────

function WorkflowStateView({
    namespace,
    queue,
    taskId,
}: {
    namespace: string;
    queue: string;
    taskId: string;
}) {
    const { data, isLoading } = useQuery({
        queryKey: qk.workflows.state(namespace, queue, taskId),
        queryFn: () => getWorkflowState(namespace, queue, taskId),
        refetchInterval: 5_000,
    });

    if (isLoading)
        return <p className="text-xs text-muted-foreground pt-2">Loading…</p>;

    // No state row at all
    if (!data)
        return (
            <p className="text-xs text-muted-foreground pt-2">
                Not yet persisted — state is saved on the first signal delivery
                or workflow completion.
            </p>
        );

    // Show the raw state — {} is valid and informative (confirms the struct serialised cleanly)
    return <JsonView label="state" value={data.state} />;
}

// ── VersionMarkersPanel ──────────────────────────────────────────────────

function VersionMarkersPanel({ markers }: { markers: VersionMarker[] }) {
    if (markers.length === 0) return null;
    return (
        <div className="rounded-lg border border-border bg-card/40 p-4">
            <h3 className="text-xs font-medium text-muted-foreground uppercase tracking-wide mb-3">
                Version Gates
            </h3>
            <div className="space-y-1">
                {markers.map((m) => (
                    <div
                        key={m.changeId}
                        className="flex items-center gap-2 text-xs"
                    >
                        {/* passed = green ✓, operator-pinned = amber dot */}
                        <span
                            className={`w-4 h-4 flex items-center justify-center rounded-full text-[10px] font-bold shrink-0 ${
                                m.value
                                    ? "bg-green-500/15 text-green-500"
                                    : "bg-amber-500/15 text-amber-500"
                            }`}
                        >
                            {m.value ? "✓" : "·"}
                        </span>
                        <span className="font-mono text-foreground flex-1">
                            {m.changeId}
                        </span>
                        <RelativeTime iso={m.markedAt} />
                    </div>
                ))}
            </div>
        </div>
    );
}

// ── Schedule card ────────────────────────────────────────────────────

/**
 * Format an ISO timestamp as compact absolute UTC: "2026-05-01T10:00"
 * Relative times are meaningless here — you need to know *which* interval this is.
 */
function fmtScheduleTime(iso: string): string {
    return new Date(iso).toISOString().slice(0, 16);
}

function fmtOffset(executionIso: string, partitionIso: string): string {
    const ms =
        new Date(executionIso).getTime() - new Date(partitionIso).getTime();
    const sign = ms >= 0 ? "+" : "-";
    const totalMins = Math.round(Math.abs(ms) / 60_000);
    // Don't show (+0m) — sub-minute offsets are noise from scheduler jitter
    if (totalMins === 0) return "";
    if (totalMins < 60) return `${sign}${totalMins}m`;
    const h = Math.floor(totalMins / 60);
    const m = totalMins % 60;
    return m > 0 ? `${sign}${h}h ${m}m` : `${sign}${h}h`;
}

function ScheduleCard({
    scheduling,
}: {
    scheduling: NonNullable<import("@/api/types").TaskDetail["scheduling"]>;
}) {
    const offset = scheduling.partitionTime
        ? fmtOffset(scheduling.executionTime, scheduling.partitionTime)
        : "";

    return (
        <div className="rounded border border-sky-500/25 bg-sky-500/5 px-3 py-2 text-xs">
            <div className="flex items-center gap-2 flex-wrap text-muted-foreground">
                <span className="text-sky-400 shrink-0">&#9201;</span>
                {scheduling.scheduleName && (
                    <span className="font-mono font-medium text-foreground">
                        {scheduling.scheduleName}
                    </span>
                )}
                {scheduling.scheduleId && (
                    <span className="font-mono text-[10px] text-muted-foreground/50 select-all shrink-0">
                        #{scheduling.scheduleId}
                    </span>
                )}
                <span className="text-muted-foreground/30">·</span>
                <span>
                    Fired{" "}
                    <span className="font-mono text-foreground">
                        {fmtScheduleTime(scheduling.executionTime)}
                    </span>
                </span>
                {scheduling.partitionTime && (
                    <>
                        <span className="text-muted-foreground/30">·</span>
                        <span>
                            Partition{" "}
                            <span className="font-mono text-foreground">
                                {fmtScheduleTime(scheduling.partitionTime)}
                            </span>
                        </span>
                        {scheduling.scheduleOffset && (
                            <span
                                className="font-mono text-xs text-sky-300/60 border border-sky-500/20 rounded px-1"
                                title={`Schedule offset: ${scheduling.scheduleOffset}`}
                            >
                                +{scheduling.scheduleOffset}
                            </span>
                        )}
                        {offset && (
                            <span
                                className="font-mono text-sky-400/70"
                                title="Time between data window start and execution"
                            >
                                ({offset})
                            </span>
                        )}
                    </>
                )}
            </div>
        </div>
    );
}

// ── TaskDetailPage ────────────────────────────────────────────────────────

export function TaskDetailPage() {
    const { taskId, namespace } = useParams({ strict: false }) as {
        taskId: string;
        namespace: string;
    };
    const search = useSearch({ strict: false }) as {
        queue?: string;
        prevId?: string;
        nextId?: string;
    };
    const queue = search.queue ?? "";
    const prevId = search.prevId;
    const nextId = search.nextId;
    const qc = useQueryClient();
    const { intervalMs, setIntervalMs } = useAutoRefresh();

    const {
        data: task,
        isLoading,
        error,
    } = useQuery({
        queryKey: qk.tasks.detail(namespace, queue, taskId),
        queryFn: () => getTask(namespace, queue, taskId),
        refetchInterval: (q) => {
            const d = q.state.data;
            // While active: always poll fast (3s) regardless of user preference
            // While terminal: honour the user's interval (may be "off")
            return d && isTerminal(d.state) ? intervalMs : 3_000;
        },
        placeholderData: keepPreviousData,
    });
    usePageTitle(task?.name ?? "Task");

    const { data: runs = [], isLoading: runsLoading } = useQuery({
        queryKey: qk.runs.list(namespace, queue, taskId),
        queryFn: () => getRuns(namespace, queue, taskId),
        refetchInterval: task && isTerminal(task.state) ? intervalMs : 3_000,
    });

    // Event trigger — set when this task was woken from a waitForEvent suspension
    const { data: eventTrigger } = useQuery({
        queryKey: [
            ...qk.tasks.detail(namespace, queue, taskId),
            "event-trigger",
        ],
        queryFn: () => getEventTriggerForTask(namespace, taskId),
        staleTime: 60_000,
        enabled: !!task,
    });

    const { data: taskMetrics } = useQuery<TaskMetrics>({
        queryKey: [...qk.tasks.detail(namespace, queue, taskId), "metrics"],
        queryFn: () => getTaskMetrics(namespace, task!.name),
        enabled: !!task,
        staleTime: 15_000,
        refetchInterval: 30_000,
    });

    const { data: versionMarkers = [] } = useQuery<VersionMarker[]>({
        queryKey: [
            ...qk.tasks.detail(namespace, task?.queue ?? "", taskId),
            "version-markers",
        ],
        queryFn: () => getVersionMarkers(namespace, task!.queue, taskId),
        enabled: !!task && task.kind === "WORKFLOW" && !isTerminal(task.state),
        staleTime: 10_000,
        refetchInterval: 15_000,
    });

    const [runsOpen, setRunsOpen] = useState(false);
    const [stateOpen, setStateOpen] = useState(false);
    const [retryDialogOpen, setRetryDialogOpen] = useState(false);
    const [signalDialogOpen, setSignalDialogOpen] = useState(false);
    const [updateDialogOpen, setUpdateDialogOpen] = useState(false);
    const [triggerOpen, setTriggerOpen] = useState(false);

    const signalMutation = useMutation({
        mutationFn: ({ name, payload }: { name: string; payload?: string }) =>
            sendSignal(namespace, queue, taskId, name, payload),
        onSuccess: () => {
            setSignalDialogOpen(false);
            qc.invalidateQueries({
                queryKey: qk.workflows.state(namespace, queue, taskId),
            });
        },
    });

    const updateMutation = useMutation({
        mutationFn: ({ name, payload }: { name: string; payload?: string }) =>
            sendUpdate(namespace, queue, taskId, name, payload),
        onSuccess: () => {
            /* do NOT close dialog here — let UpdateDialog show the result */
        },
        onError: () => {
            /* UpdateDialog will show error from result */
        },
    });

    const cancelMutation = useMutation({
        mutationFn: () => cancelTask(namespace, queue, taskId),
        onSuccess: () => {
            qc.invalidateQueries({
                queryKey: qk.tasks.detail(namespace, queue, taskId),
            });
            qc.invalidateQueries({ queryKey: qk.tasks.list(namespace, queue) });
        },
    });

    const navigate = useNavigate();

    const requeueMutation = useMutation({
        mutationFn: (opts: RetryOptions) =>
            requeueTask(namespace, queue, taskId, opts),
        onSuccess: (data) => {
            setRetryDialogOpen(false);
            if (data.taskID.toLowerCase() !== taskId.toLowerCase()) {
                // reRunTask created a brand-new task — navigate to it so the user
                // sees the fresh execution rather than the old completed one.
                navigate({
                    to: "/$namespace/tasks/$taskId",
                    params: { namespace, taskId: data.taskID },
                    search: queue ? { queue } : {},
                });
            } else {
                // retryTask reused the same task ID — refresh in place.
                qc.invalidateQueries({
                    queryKey: qk.tasks.detail(namespace, queue, taskId),
                });
                qc.invalidateQueries({
                    queryKey: qk.tasks.list(namespace, queue),
                });
            }
        },
    });

    if (isLoading)
        return (
            <div className="px-6 py-6">
                <p className="text-sm text-muted-foreground">Loading…</p>
            </div>
        );

    if (error || !task)
        return (
            <div className="px-6 py-6">
                <p className="text-sm text-red-400">Task not found.</p>
            </div>
        );

    const terminal = isTerminal(task.state);
    // Use firstRunAt (when a worker first picked this task up) as the start
    // of the duration clock. Falling back to createdAt is only correct for
    // brand-new tasks that have never been queued; for retried tasks it would
    // include all the idle time between creation and the eventual retry.
    const durationMs = taskDurationMs(
        task.firstRunAt ?? task.createdAt,
        task.completedAt,
    );
    const isWorkflow = task.kind === "WORKFLOW";

    return (
        <div className="px-6 py-5 space-y-4">
            {/* ── Header ──────────────────────────────────────────────────── */}
            <div className="flex items-start gap-4 justify-between flex-wrap">
                <div className="min-w-0">
                    {/* Breadcrumb */}
                    <div className="flex items-center gap-1.5 text-xs text-muted-foreground mb-2 font-mono">
                        {prevId && (
                            <Link
                                to="/$namespace/tasks/$taskId"
                                params={{ namespace, taskId: prevId }}
                                search={{ queue }}
                                className="hover:text-foreground transition-colors"
                                title="Previous task"
                            >
                                ←
                            </Link>
                        )}
                        {nextId && (
                            <Link
                                to="/$namespace/tasks/$taskId"
                                params={{ namespace, taskId: nextId }}
                                search={{ queue }}
                                className="hover:text-foreground transition-colors"
                                title="Next task"
                            >
                                →
                            </Link>
                        )}
                        {(prevId || nextId) && (
                            <span className="opacity-30">|</span>
                        )}
                        <Link
                            to="/$namespace/tasks"
                            params={{ namespace }}
                            search={queue ? { queue } : {}}
                            className="hover:text-foreground transition-colors"
                        >
                            Tasks
                        </Link>
                        <span>/</span>
                        <span className="text-foreground truncate">
                            {task.name}
                        </span>
                    </div>

                    <div className="flex items-center gap-2 flex-wrap">
                        <h1 className="text-lg font-semibold text-foreground">
                            {task.name}
                        </h1>
                        <StatusBadge state={task.state as TaskState} />
                        {/* Kind badge */}
                        <span
                            className={`inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium border ${
                                isWorkflow
                                    ? "bg-blue-500/15 text-blue-400 border-blue-500/20"
                                    : "bg-amber-500/15 text-amber-400 border-amber-500/20"
                            }`}
                        >
                            {isWorkflow ? "Workflow" : "Activity"}
                        </span>
                    </div>

                    {/* ID + Queue + Parent */}
                    <div className="flex items-center gap-2 mt-1 flex-wrap text-xs text-muted-foreground font-mono">
                        <span className="select-all">{task.id}</span>
                        <span>·</span>
                        <span>{task.queue}</span>
                        {task.parentTaskId && (
                            <>
                                <span>·</span>
                                <Link
                                    to="/$namespace/tasks/$taskId"
                                    params={{
                                        namespace,
                                        taskId: task.parentTaskId!,
                                    }}
                                    search={{ queue: task.queue }}
                                    className="flex items-center gap-0.5 hover:text-foreground transition-colors not-font-mono"
                                >
                                    <ArrowUpRight size={12} />
                                    parent
                                </Link>
                            </>
                        )}
                    </div>

                    {/* Timing strip */}
                    <div className="flex items-center gap-3 mt-2 text-xs text-muted-foreground flex-wrap">
                        {durationMs !== null ? (
                            <span className="text-foreground font-medium">
                                {fmtDuration(durationMs)}
                            </span>
                        ) : !terminal && task.firstRunAt ? (
                            <LiveTimer
                                startIso={task.firstRunAt}
                                className="text-foreground font-medium tabular-nums"
                            />
                        ) : null}
                        <span>
                            Created <RelativeTime iso={task.createdAt} />
                        </span>
                        {task.firstRunAt && (
                            <span>
                                Started <RelativeTime iso={task.firstRunAt} />
                            </span>
                        )}
                        {task.completedAt && (
                            <span>
                                Finished <RelativeTime iso={task.completedAt} />
                            </span>
                        )}
                        {task.attempt > 1 && (
                            <span>
                                Attempt {task.attempt}
                                {task.maxAttempts
                                    ? ` / ${task.maxAttempts}`
                                    : ""}
                            </span>
                        )}
                    </div>
                </div>

                {/* Actions */}
                <div className="flex items-center gap-2 flex-wrap shrink-0">
                    <AutoRefreshControl
                        intervalMs={intervalMs}
                        setIntervalMs={setIntervalMs}
                    />
                    {isWorkflow && (
                        <Link
                            to="/$namespace/tasks/$taskId/trace"
                            params={{ namespace, taskId }}
                            search={queue ? { queue } : {}}
                            className="inline-flex items-center gap-1.5 rounded-md border border-border px-2.5 py-1 text-xs font-medium text-muted-foreground hover:text-foreground hover:bg-secondary/40 transition-colors"
                        >
                            <GitBranch size={12} />
                            View Trace
                        </Link>
                    )}
                    {!terminal && isWorkflow && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setSignalDialogOpen(true)}
                        >
                            <Send size={12} /> Signal
                        </Button>
                    )}
                    {!terminal && isWorkflow && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setUpdateDialogOpen(true)}
                            className="gap-1.5"
                        >
                            <Zap size={13} />
                            Update
                        </Button>
                    )}
                    {!terminal && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => cancelMutation.mutate()}
                            disabled={cancelMutation.isPending}
                        >
                            <XCircle size={13} /> Cancel
                        </Button>
                    )}
                    {terminal && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setRetryDialogOpen(true)}
                            disabled={requeueMutation.isPending}
                            title={
                                task.state === "COMPLETED"
                                    ? "Re-run this workflow from scratch"
                                    : "Retry the failed run"
                            }
                        >
                            <RefreshCw size={13} />
                            {task.state === "COMPLETED" ? "Re-run" : "Retry"}
                        </Button>
                    )}
                    {isWorkflow && (
                        <Button
                            variant="outline"
                            size="sm"
                            onClick={() => setTriggerOpen(true)}
                            className="gap-1.5"
                        >
                            <Zap size={12} />
                            Run Again
                        </Button>
                    )}
                </div>
            </div>

            {/* ── Description card (full width, below header, if set) ─────────── */}
            {task.description && (
                <div className="rounded-lg border border-border/60 bg-secondary/10 px-4 py-3">
                    <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-1">
                        Description
                    </p>
                    <p className="text-sm text-foreground">
                        {task.description}
                    </p>
                </div>
            )}

            {/* ── Schedule card (full width, below header) ────────────────────── */}
            {task.scheduling && <ScheduleCard scheduling={task.scheduling} />}

            {/* Performance metrics — sourced from DDSketch broadcast */}
            {taskMetrics &&
                (taskMetrics.p50Ms != null ||
                    taskMetrics.completedCount > 0) && (
                    <div className="rounded-lg border border-border/60 bg-secondary/10 px-4 py-3">
                        <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-2.5">
                            Performance
                        </p>
                        <div className="flex flex-wrap gap-x-6 gap-y-1.5">
                            {taskMetrics.p50Ms != null && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        p50{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-foreground">
                                        {taskMetrics.p50Ms < 1000
                                            ? `${Math.round(taskMetrics.p50Ms)}ms`
                                            : `${(taskMetrics.p50Ms / 1000).toFixed(1)}s`}
                                    </span>
                                </div>
                            )}
                            {taskMetrics.p95Ms != null && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        p95{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-foreground">
                                        {taskMetrics.p95Ms < 1000
                                            ? `${Math.round(taskMetrics.p95Ms)}ms`
                                            : `${(taskMetrics.p95Ms / 1000).toFixed(1)}s`}
                                    </span>
                                </div>
                            )}
                            {taskMetrics.p99Ms != null && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        p99{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-foreground">
                                        {taskMetrics.p99Ms < 1000
                                            ? `${Math.round(taskMetrics.p99Ms)}ms`
                                            : `${(taskMetrics.p99Ms / 1000).toFixed(1)}s`}
                                    </span>
                                </div>
                            )}
                            {taskMetrics.ratePerSec != null && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        rate{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-foreground">
                                        {taskMetrics.ratePerSec.toFixed(2)}/s
                                    </span>
                                </div>
                            )}
                            {taskMetrics.completedCount > 0 && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        ok{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-green-400">
                                        {taskMetrics.completedCount}
                                    </span>
                                </div>
                            )}
                            {taskMetrics.failedCount > 0 && (
                                <div>
                                    <span className="text-[10px] text-muted-foreground">
                                        fail{" "}
                                    </span>
                                    <span className="font-mono text-[11px] text-red-400">
                                        {taskMetrics.failedCount}
                                    </span>
                                </div>
                            )}
                        </div>
                        <p className="text-[9px] text-muted-foreground/40 mt-2">
                            From broadcast window · refreshes every 30s
                        </p>
                    </div>
                )}

            {/* ── Woken by event card ─────────────────────────────── */}
            {eventTrigger && (
                <div className="rounded-lg border border-border/60 bg-secondary/10 px-4 py-3 flex items-center gap-3">
                    <div className="w-2 h-2 rounded-full bg-purple-400 shrink-0" />
                    <div className="flex-1 min-w-0">
                        <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-0.5">
                            Woken by event
                        </p>
                        <div className="flex items-center gap-2 flex-wrap">
                            <span className="font-mono text-sm text-foreground">
                                {eventTrigger.eventName}
                            </span>
                            <span className="text-xs text-muted-foreground">
                                in{" "}
                                <span className="font-mono">
                                    {eventTrigger.queue}
                                </span>
                            </span>
                            <RelativeTime iso={eventTrigger.triggeredAt} />
                        </div>
                        {eventTrigger.emissionId && (
                            <p className="font-mono text-[10px] text-muted-foreground/50 mt-0.5 select-all">
                                {eventTrigger.emissionId}
                            </p>
                        )}
                    </div>
                    {eventTrigger.emissionId && (
                        <Link
                            to="/$namespace/events"
                            params={{ namespace }}
                            className="text-xs text-muted-foreground hover:text-foreground transition-colors shrink-0"
                        >
                            View emission →
                        </Link>
                    )}
                </div>
            )}

            {/* ── Input / Output ───────────────────────────────────────── */}
            <div className="grid md:grid-cols-2 gap-3">
                <div className="rounded-lg border border-border bg-card/40 p-4">
                    <p className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                        Input
                    </p>
                    <JsonView value={task.params} />
                </div>
                <div className="rounded-lg border border-border bg-card/40 p-4">
                    <p className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                        {task.state === "FAILED" ? "Error" : "Output"}
                    </p>
                    {/* For failed tasks task.result is null — pull failure reason from the
              latest run instead (most recent attempt first from the API). */}
                    {task.state === "FAILED" && !task.result ? (
                        (() => {
                            const latestFailure = runs.find(
                                (r) => r.failureReason,
                            )?.failureReason;
                            return latestFailure ? (
                                <FailureReasonView raw={latestFailure} />
                            ) : (
                                <p className="text-xs text-muted-foreground/50 italic">
                                    No error detail available.
                                </p>
                            );
                        })()
                    ) : (
                        <JsonView value={task.result} />
                    )}
                </div>
            </div>

            {/* ── Run Timeline (workflows only) ──────────────────────────── */}
            {isWorkflow && (
                <section>
                    <h2 className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
                        Run Timeline
                    </h2>
                    <div className="rounded-lg border border-border bg-card/40 p-4">
                        <ActivityTimeline
                            namespace={namespace}
                            queue={queue}
                            taskId={taskId}
                            taskCreatedAt={task.createdAt}
                        />
                    </div>
                </section>
            )}

            {/* ── Child Activities ─────────────────────────────────────────── */}
            {isWorkflow && (
                <ChildActivities
                    namespace={namespace}
                    queue={queue}
                    taskId={taskId}
                    parentCreatedAt={task.createdAt}
                    parentCompletedAt={task.completedAt}
                />
            )}

            {/* ── Runs / Checkpoints (collapsible, secondary) ──────────────── */}
            <div className="rounded-lg border border-border bg-card/40 overflow-hidden">
                <button
                    onClick={() => setRunsOpen((o) => !o)}
                    className="flex w-full items-center gap-2.5 px-4 py-3 text-left hover:bg-secondary/20 transition-colors"
                >
                    {runsOpen ? (
                        <ChevronDown
                            size={13}
                            className="text-muted-foreground shrink-0"
                        />
                    ) : (
                        <ChevronRight
                            size={13}
                            className="text-muted-foreground shrink-0"
                        />
                    )}
                    <span className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground">
                        Runs &amp; Checkpoints ({runs.length})
                    </span>
                </button>
                {runsOpen && (
                    <div className="border-t border-border/50 p-3 space-y-2">
                        {runsLoading && runs.length === 0 ? (
                            [0, 1, 2].map((i) => (
                                <div
                                    key={i}
                                    className="rounded border border-border/60 overflow-hidden"
                                >
                                    <div className="flex items-center gap-2.5 px-3 py-2">
                                        <div className="h-3 w-3 rounded bg-muted/40 animate-pulse shrink-0" />
                                        <div
                                            className="h-3 rounded bg-muted/40 animate-pulse"
                                            style={{ width: "80px" }}
                                        />
                                        <div
                                            className="h-5 rounded bg-muted/40 animate-pulse"
                                            style={{ width: `${60 + i * 20}%` }}
                                        />
                                    </div>
                                </div>
                            ))
                        ) : (
                            <>
                                {runs.length === 0 && (
                                    <p className="text-sm text-muted-foreground">
                                        No runs yet.
                                    </p>
                                )}
                                {[...runs].reverse().map((run) => (
                                    <RunRow
                                        key={run.id}
                                        namespace={namespace}
                                        run={run}
                                        queue={queue}
                                        taskId={taskId}
                                    />
                                ))}
                            </>
                        )}
                    </div>
                )}
            </div>

            {/* ── Version Gates ───────────────────────────────────────────── */}
            {isWorkflow && versionMarkers.length > 0 && (
                <VersionMarkersPanel markers={versionMarkers} />
            )}

            {/* ── Workflow State (collapsible, secondary) ───────────────────── */}
            {isWorkflow && (
                <div className="rounded-lg border border-border bg-card/40 overflow-hidden">
                    <button
                        onClick={() => setStateOpen((o) => !o)}
                        className="flex w-full items-center gap-2.5 px-4 py-3 text-left hover:bg-secondary/20 transition-colors"
                    >
                        {stateOpen ? (
                            <ChevronDown
                                size={13}
                                className="text-muted-foreground shrink-0"
                            />
                        ) : (
                            <ChevronRight
                                size={13}
                                className="text-muted-foreground shrink-0"
                            />
                        )}
                        <span className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground">
                            Workflow State
                        </span>
                    </button>
                    {stateOpen && (
                        <div className="border-t border-border/50 p-4">
                            <WorkflowStateView
                                namespace={namespace}
                                queue={queue}
                                taskId={taskId}
                            />
                        </div>
                    )}
                </div>
            )}

            <RetryDialog
                open={retryDialogOpen}
                onClose={() => setRetryDialogOpen(false)}
                onConfirm={(opts) => requeueMutation.mutate(opts)}
                isPending={requeueMutation.isPending}
                taskState={task.state}
            />
            <SignalDialog
                open={signalDialogOpen}
                onClose={() => setSignalDialogOpen(false)}
                onSend={(name, payload) =>
                    signalMutation.mutate({ name, payload })
                }
                isPending={signalMutation.isPending}
            />
            <UpdateDialog
                open={updateDialogOpen}
                onClose={() => {
                    setUpdateDialogOpen(false);
                    updateMutation.reset();
                }}
                onSend={(name, payload) =>
                    updateMutation.mutate({ name, payload })
                }
                isPending={updateMutation.isPending}
                result={updateMutation.data ?? null}
            />
            <TriggerDialog
                open={triggerOpen}
                onClose={() => setTriggerOpen(false)}
                namespace={namespace}
                initialWorkflowName={task.name}
                initialQueue={task.queue}
                initialInput={paramsTemplate(task.params)}
            />
        </div>
    );
}
