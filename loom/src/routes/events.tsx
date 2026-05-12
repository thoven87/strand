import { useState, useMemo } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import { Link, useParams } from "@tanstack/react-router";
import { Search, Zap, ChevronRight, Copy, Check } from "lucide-react";
import { getQueues } from "@/api/queues";
import { getEventsGlobal, emitEvent, getEventWaiters } from "@/api/events";
import type { EventWaiter } from "@/api/events";
import { qk } from "@/lib/queryKeys";
import { cn } from "@/lib/utils";
import { JsonView } from "@/components/JsonView";
import { JsonEditor } from "@/components/JsonEditor";
import { Paginator } from "@/components/Paginator";
import { Select } from "@/components/ui/select";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/EmptyState";
import { RelativeTime } from "@/components/RelativeTime";
import type { StrandEvent } from "@/api/types";

// ── helpers ────────────────────────────────────────────────────────────────

/** Returns the first ~60 visible characters of a JSON string, without newlines. */
function payloadPreview(raw: string | null): string | null {
    if (!raw) return null;
    try {
        const pretty = JSON.stringify(JSON.parse(raw));
        return pretty.length > 72 ? pretty.slice(0, 69) + "…" : pretty;
    } catch {
        return raw.length > 72 ? raw.slice(0, 69) + "…" : raw;
    }
}

// ── CopyButton ─────────────────────────────────────────────────────────────

function CopyButton({ text }: { text: string }) {
    const [copied, setCopied] = useState(false);
    return (
        <button
            onClick={(e) => {
                e.stopPropagation();
                void navigator.clipboard.writeText(text).then(() => {
                    setCopied(true);
                    setTimeout(() => setCopied(false), 1_500);
                });
            }}
            title="Copy event name"
            className="opacity-0 group-hover/row:opacity-100 ml-1 text-muted-foreground/50 hover:text-muted-foreground transition-opacity shrink-0"
        >
            {copied ? <Check size={11} /> : <Copy size={11} />}
        </button>
    );
}

// ── TriggeredFunctionsPanel ──────────────────────────────────────────────

function TriggeredFunctionsPanel({
    tasks,
    namespace,
    queue,
}: {
    tasks: StrandEvent["triggeredTasks"];
    namespace: string;
    queue: string;
}) {
    if (!tasks || tasks.length === 0) {
        return (
            <p className="text-xs text-muted-foreground/50 italic">
                No workflows triggered
            </p>
        );
    }
    return (
        <ul className="space-y-1.5">
            {tasks.map((t) => {
                const dotColor =
                    t.taskState === "COMPLETED"
                        ? "bg-green-500"
                        : t.taskState === "FAILED" ||
                            t.taskState === "CANCELLED"
                          ? "bg-red-500"
                          : t.taskState === "RUNNING"
                            ? "bg-yellow-400 animate-pulse"
                            : "bg-slate-400";
                return (
                    <li key={t.taskId}>
                        <Link
                            to="/$namespace/tasks/$taskId"
                            params={{ namespace, taskId: t.taskId }}
                            search={{ queue }}
                            className="flex items-center gap-2 rounded px-2 py-1.5 hover:bg-secondary/30 transition-colors group"
                            onClick={(e) => e.stopPropagation()}
                        >
                            <span
                                className={cn(
                                    "w-2 h-2 rounded-full shrink-0",
                                    dotColor,
                                )}
                            />
                            {/* Kind badge */}
                            <span
                                className={`shrink-0 text-[9px] font-mono rounded px-[3px] py-px leading-none border ${
                                    t.taskKind === "WORKFLOW"
                                        ? "bg-blue-500/15 text-blue-600 dark:text-blue-300 border-blue-500/20"
                                        : "bg-amber-500/15 text-amber-600 dark:text-amber-300 border-amber-500/20"
                                }`}
                            >
                                {t.taskKind === "WORKFLOW" ? "W" : "A"}
                            </span>
                            <span className="font-mono text-xs text-foreground truncate flex-1">
                                {t.taskName}
                            </span>
                            <span className="text-[10px] text-muted-foreground/60 capitalize shrink-0">
                                {t.taskState.toLowerCase()}
                            </span>
                            <ChevronRight
                                size={11}
                                className="text-muted-foreground/30 shrink-0"
                            />
                        </Link>
                    </li>
                );
            })}
        </ul>
    );
}

// ── WaitersPanel ──────────────────────────────────────────────────────────

function WaitersPanel({
    namespace,
    queue,
    eventName,
    onEmitted,
}: {
    namespace: string;
    queue: string;
    eventName: string;
    onEmitted: () => void;
}) {
    const [showForm, setShowForm] = useState(false);
    const [payload, setPayload] = useState("{}");
    const queryClient = useQueryClient();

    const { data, isLoading } = useQuery({
        queryKey: ["event-waiters", namespace, queue, eventName],
        queryFn: () => getEventWaiters(namespace, queue, eventName),
        refetchInterval: 4_000,
    });
    const waiters: EventWaiter[] = data ?? [];

    const mutation = useMutation({
        mutationFn: () => emitEvent(namespace, queue, eventName, payload),
        onSuccess: () => {
            setShowForm(false);
            setPayload("{}");
            void queryClient.invalidateQueries({
                queryKey: ["event-waiters", namespace, queue, eventName],
            });
            onEmitted();
        },
    });

    return (
        <div className="space-y-2">
            <div className="flex items-center justify-between">
                <div className="flex items-center gap-1.5">
                    <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
                        Waiting for this event
                    </p>
                    {waiters.length > 0 && (
                        <span className="rounded-full bg-yellow-500/15 text-yellow-500 dark:text-yellow-400 text-[9px] font-medium px-1.5 py-px">
                            {waiters.length}
                        </span>
                    )}
                </div>
                {waiters.length > 0 && !showForm && (
                    <button
                        onClick={(e) => {
                            e.stopPropagation();
                            setShowForm(true);
                        }}
                        className="text-[10px] text-brand hover:text-brand/80 font-medium transition-colors"
                    >
                        Emit response ↗
                    </button>
                )}
            </div>

            {isLoading && waiters.length === 0 ? (
                <p className="text-[10px] text-muted-foreground/50">Loading…</p>
            ) : waiters.length === 0 ? (
                <p className="text-[10px] text-muted-foreground/50 italic">
                    No workflows currently waiting
                </p>
            ) : (
                <ul className="space-y-1">
                    {waiters.map((w) => (
                        <li
                            key={`${w.taskId}-${w.seqNum}`}
                            className="flex items-center gap-2 text-xs"
                        >
                            <span className="w-1.5 h-1.5 rounded-full bg-yellow-400 animate-pulse shrink-0" />
                            <span className="font-mono text-foreground/80 truncate flex-1">
                                {w.taskName}
                            </span>
                            {w.timeoutAt && (
                                <span className="text-[10px] text-muted-foreground/60 shrink-0 whitespace-nowrap">
                                    expires <RelativeTime iso={w.timeoutAt} />
                                </span>
                            )}
                        </li>
                    ))}
                </ul>
            )}

            {showForm && (
                <div
                    className="space-y-2 pt-2 border-t border-border/30"
                    onClick={(e) => e.stopPropagation()}
                >
                    <p className="text-[10px] font-mono text-muted-foreground/70 truncate">
                        → {eventName}
                    </p>
                    <JsonEditor
                        value={payload}
                        onChange={setPayload}
                        placeholder='{"approved": true}'
                        minHeight="72px"
                    />
                    {mutation.error && (
                        <p className="text-[10px] text-red-400">
                            {String(mutation.error)}
                        </p>
                    )}
                    <div className="flex gap-2">
                        <Button
                            size="sm"
                            className="h-6 text-[11px] px-2"
                            onClick={() => mutation.mutate()}
                            disabled={mutation.isPending}
                        >
                            <Zap size={10} />
                            Emit
                        </Button>
                        <Button
                            variant="outline"
                            size="sm"
                            className="h-6 text-[11px] px-2"
                            onClick={() => setShowForm(false)}
                            disabled={mutation.isPending}
                        >
                            Cancel
                        </Button>
                    </div>
                </div>
            )}
        </div>
    );
}

// ── EventRow ───────────────────────────────────────────────────────────────

type EventItem = StrandEvent & { queue: string };

function EventRow({
    event,
    showQueue,
    namespace,
}: {
    event: EventItem;
    showQueue: boolean;
    namespace: string;
}) {
    const [expanded, setExpanded] = useState(false);
    const preview = payloadPreview(event.payload);

    return (
        <>
            <tr
                className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors cursor-pointer group/row"
                onClick={() => setExpanded((e) => !e)}
            >
                {/* Timestamp — first column like Inngest */}
                <td className="px-4 py-2.5 whitespace-nowrap">
                    <RelativeTime iso={event.createdAt} />
                </td>

                {/* Event name + copy */}
                <td className="px-4 py-2.5">
                    <div className="flex items-center gap-0.5 min-w-0">
                        <span className="font-mono text-sm text-foreground truncate">
                            {event.name}
                        </span>
                        <CopyButton text={event.name} />
                    </div>
                    {/* Triggered task pills — "functions triggered" */}
                    {event.triggeredTasks &&
                        event.triggeredTasks.length > 0 && (
                            <div
                                className="flex items-center gap-1 mt-1.5 flex-wrap"
                                onClick={(e) => e.stopPropagation()}
                            >
                                {event.triggeredTasks.slice(0, 3).map((t) => {
                                    const dotColor =
                                        t.taskState === "COMPLETED"
                                            ? "bg-green-500"
                                            : t.taskState === "FAILED" ||
                                                t.taskState === "CANCELLED"
                                              ? "bg-red-500"
                                              : t.taskState === "RUNNING"
                                                ? "bg-yellow-400 animate-pulse"
                                                : "bg-slate-400";
                                    return (
                                        <Link
                                            key={t.taskId}
                                            to="/$namespace/tasks/$taskId"
                                            params={{
                                                namespace,
                                                taskId: t.taskId,
                                            }}
                                            search={{ queue: event.queue }}
                                            className="inline-flex items-center gap-1 rounded border border-border/40 bg-secondary/20 px-1.5 py-0.5 text-[10px] font-mono text-foreground/80 hover:bg-secondary/50 hover:text-foreground transition-colors max-w-[140px]"
                                        >
                                            <span
                                                className={cn(
                                                    "w-1.5 h-1.5 rounded-full shrink-0",
                                                    dotColor,
                                                )}
                                            />
                                            <span className="truncate">
                                                {t.taskName}
                                            </span>
                                        </Link>
                                    );
                                })}
                                {event.triggeredTasks.length > 3 && (
                                    <span className="text-[9px] text-muted-foreground/50">
                                        +{event.triggeredTasks.length - 3}
                                    </span>
                                )}
                            </div>
                        )}
                </td>

                {/* Queue */}
                {showQueue && (
                    <td className="px-4 py-2.5 text-xs text-muted-foreground font-mono">
                        {event.queue}
                    </td>
                )}

                {/* Inline payload preview */}
                <td className="px-4 py-2.5 max-w-xs">
                    {preview ? (
                        <span className="text-xs text-muted-foreground/60 font-mono truncate block">
                            {preview}
                        </span>
                    ) : (
                        <span className="text-xs text-muted-foreground/30 italic">
                            no payload
                        </span>
                    )}
                </td>

                {/* Expand chevron */}
                <td className="px-3 py-2.5 w-8">
                    <ChevronRight
                        size={13}
                        className={`text-muted-foreground/40 transition-transform duration-150 ${
                            expanded ? "rotate-90" : ""
                        }`}
                    />
                </td>
            </tr>

            {expanded && (
                <tr className="border-b border-border/40 bg-secondary/5">
                    <td colSpan={showQueue ? 5 : 4} className="p-0">
                        <div className="flex w-full min-h-[180px] divide-x divide-border/30">
                            {/* Left — Payload */}
                            <div className="flex-[3] min-w-0 p-4 overflow-hidden">
                                {/* overflow-hidden is still useful here: even with
                                 * table-fixed, the JsonView <pre> can push the flex
                                 * item wider than its flex-[3] allocation. The actual
                                 * horizontal scroll lives inside <pre overflow-auto>. */}

                                {/* Emission ID */}
                                <div className="flex items-center gap-1.5 mb-3">
                                    <span className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
                                        Emission
                                    </span>
                                    <span className="font-mono text-[11px] text-muted-foreground/70 select-all">
                                        {event.id}
                                    </span>
                                </div>

                                <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-2">
                                    Payload
                                </p>
                                {event.payload ? (
                                    <JsonView value={event.payload} />
                                ) : (
                                    <p className="text-xs text-muted-foreground/50 italic">
                                        No payload
                                    </p>
                                )}
                            </div>

                            {/* Right — Functions triggered + waiters */}
                            <div className="flex-[2] min-w-0 flex flex-col divide-y divide-border/30">
                                {/* Triggered functions */}
                                <div className="p-4">
                                    <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-2.5">
                                        Triggered runs
                                    </p>
                                    <TriggeredFunctionsPanel
                                        tasks={event.triggeredTasks}
                                        namespace={namespace}
                                        queue={event.queue}
                                    />
                                </div>

                                {/* Waiters + inline emit */}
                                <div className="p-4 flex-1">
                                    <WaitersPanel
                                        namespace={namespace}
                                        queue={event.queue}
                                        eventName={event.name}
                                        onEmitted={() => {
                                            setExpanded(false);
                                        }}
                                    />
                                </div>
                            </div>
                        </div>
                    </td>
                </tr>
            )}
        </>
    );
}

// ── EmitEventDialog ────────────────────────────────────────────────────────

function EmitEventDialog({
    open,
    onClose,
    namespace,
    queues,
    onEmitted,
}: {
    open: boolean;
    onClose: () => void;
    namespace: string;
    queues: string[];
    onEmitted: () => void;
}) {
    // Seeded empty — effectiveQueue below handles the stale-init problem.
    const [queue, setQueue] = useState("");
    // EmitEventDialog is always mounted (returns null when closed, but hooks
    // still run). useState initialises before queues load so queue=="".
    // effectiveQueue falls back to queues[0] so the Emit button is never
    // disabled simply because the state initialised before data arrived.
    const effectiveQueue = queue || queues[0] || "";
    const [name, setName] = useState("");
    const [payload, setPayload] = useState("{}");

    const mutation = useMutation({
        mutationFn: () =>
            emitEvent(namespace, effectiveQueue, name.trim(), payload),
        onSuccess: () => {
            onEmitted();
            onClose();
            setName("");
            setPayload("{}");
        },
    });

    if (!open) return null;

    return (
        <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
            onClick={(e) => e.target === e.currentTarget && onClose()}
        >
            <div
                className="w-full max-w-xl rounded-xl border border-border bg-background shadow-2xl"
                role="dialog"
                aria-modal="true"
                onKeyDown={(e) => e.key === "Escape" && onClose()}
            >
                {/* Header */}
                <div className="px-6 pt-5 pb-4 border-b border-border">
                    <h2 className="text-base font-semibold text-foreground">
                        Emit event
                    </h2>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Sends a named event — wakes any workflow blocked in{" "}
                        <code className="font-mono bg-secondary/60 px-1 rounded">
                            ctx.waitForEvent()
                        </code>
                        .
                    </p>
                </div>

                {/* Body */}
                <div className="px-6 py-5 space-y-4">
                    {mutation.error && (
                        <div className="rounded border border-red-500/30 bg-red-500/10 px-3 py-2 text-xs text-red-400">
                            {String(mutation.error)}
                        </div>
                    )}

                    {/* Queue */}
                    <div className="space-y-1.5">
                        <label className="text-xs font-medium text-foreground">
                            Queue
                        </label>
                        <Select
                            value={effectiveQueue}
                            onChange={(e) => setQueue(e.target.value)}
                        >
                            {queues.map((q) => (
                                <option key={q} value={q}>
                                    {q}
                                </option>
                            ))}
                        </Select>
                    </div>

                    {/* Event name */}
                    <div className="space-y-1.5">
                        <label className="text-xs font-medium text-foreground">
                            Event name <span className="text-red-400">*</span>
                        </label>
                        <input
                            autoFocus
                            className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
                            placeholder="order.shipped"
                            value={name}
                            onChange={(e) => setName(e.target.value)}
                            onKeyDown={(e) => {
                                if (e.key === "Enter" && name.trim())
                                    mutation.mutate();
                            }}
                        />
                    </div>

                    {/* Payload */}
                    <div className="space-y-1.5">
                        <label className="text-xs font-medium text-foreground">
                            Payload (JSON)
                        </label>
                        <JsonEditor
                            value={payload}
                            onChange={setPayload}
                            placeholder='{"orderId": "abc123"}'
                            minHeight="120px"
                        />
                    </div>
                </div>

                {/* Footer */}
                <div className="flex items-center justify-end gap-2 border-t border-border px-6 py-4">
                    <Button
                        variant="outline"
                        size="sm"
                        onClick={onClose}
                        disabled={mutation.isPending}
                    >
                        Cancel
                    </Button>
                    <Button
                        size="sm"
                        onClick={() => mutation.mutate()}
                        disabled={
                            mutation.isPending ||
                            !name.trim() ||
                            !effectiveQueue
                        }
                    >
                        <Zap size={13} />
                        Emit
                    </Button>
                </div>
            </div>
        </div>
    );
}

// ── EventsPage ─────────────────────────────────────────────────────────────

export function EventsPage() {
    usePageTitle("Events");
    const { namespace } = useParams({ strict: false }) as {
        namespace: string;
    };

    const [selectedQueue, setSelectedQueue] = useState("");
    const [nameSearch, setNameSearch] = useState("");
    const [cursor, setCursor] = useState<string | undefined>(undefined);
    const [history, setHistory] = useState<string[]>([]);
    const [emitOpen, setEmitOpen] = useState(false);
    const [timeRange, setTimeRange] = useState<"1h" | "24h" | "7d" | "all">(
        "24h",
    );

    const since = useMemo(() => {
        const nowSec = Date.now() / 1000;
        if (timeRange === "1h") return String(Math.floor(nowSec - 3_600));
        if (timeRange === "24h") return String(Math.floor(nowSec - 86_400));
        if (timeRange === "7d") return String(Math.floor(nowSec - 7 * 86_400));
        return undefined;
    }, [timeRange]);

    const { data: queues = [] } = useQuery({
        queryKey: qk.queues.list(namespace),
        queryFn: () => getQueues(namespace),
    });

    const { data, isLoading, refetch } = useQuery({
        queryKey: [
            "events-global",
            namespace,
            selectedQueue,
            nameSearch,
            cursor,
            timeRange,
            since,
        ],
        queryFn: () =>
            getEventsGlobal(namespace, {
                queue: selectedQueue || undefined,
                name: nameSearch || undefined,
                cursor,
                limit: 50,
                since,
            }),
        refetchInterval: 10_000,
    });

    const showQueue = !selectedQueue;

    const headers = [
        "Emitted",
        "Event name",
        ...(showQueue ? ["Queue"] : []),
        "Payload",
        "",
    ];

    return (
        <div className="px-6 py-5 space-y-4">
            {/* ── Header ──────────────────────────────────────────────── */}
            <div className="flex items-center gap-3 flex-wrap">
                <div className="mr-auto">
                    <h1 className="text-base font-semibold text-foreground">
                        Events
                    </h1>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Named events emitted via{" "}
                        <code className="font-mono text-[11px] bg-secondary/60 px-1 rounded">
                            client.emitEvent()
                        </code>
                        {data?.items.length != null && (
                            <span className="ml-2 text-muted-foreground/60">
                                · {data.items.length} shown
                            </span>
                        )}
                    </p>
                </div>

                {/* Name search */}
                <div className="relative">
                    <Search
                        size={12}
                        className="absolute left-2.5 top-1/2 -translate-y-1/2 text-muted-foreground pointer-events-none"
                    />
                    <input
                        type="search"
                        placeholder="Filter by name…"
                        value={nameSearch}
                        onChange={(e) => {
                            setNameSearch(e.target.value);
                            setCursor(undefined);
                            setHistory([]);
                        }}
                        className="pl-7 pr-3 py-1.5 rounded border border-border bg-secondary/30 text-foreground text-xs w-44 focus:outline-none focus:ring-1 focus:ring-ring placeholder:text-muted-foreground/50"
                    />
                </div>

                {/* Time range */}
                <div className="flex items-center rounded-md border border-border overflow-hidden text-xs">
                    {(["1h", "24h", "7d", "all"] as const).map((r) => (
                        <button
                            key={r}
                            onClick={() => {
                                setTimeRange(r);
                                setCursor(undefined);
                                setHistory([]);
                            }}
                            className={`px-2.5 py-1.5 transition-colors border-r border-border last:border-0 ${
                                timeRange === r
                                    ? "bg-brand/15 text-brand font-medium"
                                    : "text-muted-foreground hover:text-foreground hover:bg-secondary/40"
                            }`}
                        >
                            {r}
                        </button>
                    ))}
                </div>

                {/* Queue filter */}
                <Select
                    value={selectedQueue}
                    onChange={(e) => {
                        setSelectedQueue(e.target.value);
                        setCursor(undefined);
                        setHistory([]);
                    }}
                >
                    <option value="">All queues</option>
                    {queues.map((q) => (
                        <option key={q.name} value={q.name}>
                            {q.name}
                        </option>
                    ))}
                </Select>

                {/* Emit event button */}
                <Button
                    size="sm"
                    onClick={() => setEmitOpen(true)}
                    className="gap-1.5"
                >
                    <Zap size={12} />
                    Emit event
                </Button>
            </div>

            {/* ── Signals callout ─────────────────────────────────────── */}
            <div className="rounded-lg border border-border/40 bg-secondary/10 px-4 py-2.5 text-xs text-muted-foreground flex items-start gap-2">
                <span className="shrink-0 mt-0.5 text-muted-foreground/50">
                    ℹ
                </span>
                <span>
                    <strong className="text-foreground font-medium">
                        Signals
                    </strong>{" "}
                    (sent via{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        handle.signal()
                    </code>
                    ) are delivered directly to a task UUID and are <em>not</em>{" "}
                    stored here. Only{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        emitEvent()
                    </code>{" "}
                    events appear in this list.
                </span>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {data && (
                <>
                    {data.items.length === 0 ? (
                        <EmptyState
                            variant="events"
                            title="No events found"
                            description={
                                nameSearch
                                    ? `No events matching "${nameSearch}".`
                                    : "Events appear here when emitted via client.emitEvent()."
                            }
                        />
                    ) : (
                        <div className="rounded-lg border border-border overflow-hidden">
                            {/*
                             * table-fixed prevents the table from growing beyond w-full
                             * based on cell content (the default auto layout lets <pre>
                             * content push columns wider than the viewport, which breaks
                             * the split-pane layout in expanded rows).
                             *
                             * Column widths are set via <colgroup>. The Event name column
                             * (no explicit col width) takes all remaining space.
                             */}
                            <table className="w-full text-sm table-fixed">
                                <colgroup>
                                    {/* Emitted */}
                                    <col style={{ width: "110px" }} />
                                    {/* Event name — flexible, takes remaining space */}
                                    <col />
                                    {/* Queue — only rendered when showQueue */}
                                    {showQueue && (
                                        <col style={{ width: "100px" }} />
                                    )}
                                    {/* Payload preview */}
                                    <col style={{ width: "220px" }} />
                                    {/* Expand chevron */}
                                    <col style={{ width: "36px" }} />
                                </colgroup>
                                <thead>
                                    <tr className="border-b border-border bg-secondary/20">
                                        {headers.map((h) => (
                                            <th
                                                key={h}
                                                className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide whitespace-nowrap"
                                            >
                                                {h}
                                            </th>
                                        ))}
                                    </tr>
                                </thead>
                                <tbody>
                                    {data.items.map((ev) => (
                                        <EventRow
                                            key={ev.id}
                                            event={ev as EventItem}
                                            showQueue={showQueue}
                                            namespace={namespace}
                                        />
                                    ))}
                                </tbody>
                            </table>
                        </div>
                    )}

                    <Paginator
                        hasNext={!!data.nextCursor}
                        hasPrev={history.length > 0}
                        onNext={() => {
                            if (!data.nextCursor) return;
                            setHistory((h) => [...h, cursor ?? ""]);
                            setCursor(data.nextCursor ?? undefined);
                        }}
                        onPrev={() => {
                            const p = history[history.length - 1];
                            setHistory((h) => h.slice(0, -1));
                            setCursor(p || undefined);
                        }}
                    />
                </>
            )}

            {/* ── Emit event dialog ───────────────────────────────────── */}
            <EmitEventDialog
                open={emitOpen}
                onClose={() => setEmitOpen(false)}
                namespace={namespace}
                queues={queues.map((q) => q.name)}
                onEmitted={() => void refetch()}
            />
        </div>
    );
}
