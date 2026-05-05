import { useState } from "react";
import { usePageTitle } from "@/lib/usePageTitle";
import { useQuery } from "@tanstack/react-query";
import { getQueues } from "@/api/queues";
import { getEventsGlobal } from "@/api/events";
import { qk } from "@/lib/queryKeys";
import { useParams } from "@tanstack/react-router";
import { JsonView } from "@/components/JsonView";
import { Paginator } from "@/components/Paginator";
import { Select } from "@/components/ui/select";
import { EmptyState } from "@/components/EmptyState";
import type { StrandEvent } from "@/api/types";

function formatRelative(iso: string) {
    const diff = Date.now() - new Date(iso).getTime();
    if (diff < 60_000) return `${Math.floor(diff / 1000)}s ago`;
    if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
    if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
    return new Date(iso).toLocaleDateString();
}

function EventRow({ event }: { event: StrandEvent & { queue?: string } }) {
    const [expanded, setExpanded] = useState(false);

    return (
        <>
            <tr
                className="border-b border-border/40 last:border-0 hover:bg-secondary/10 transition-colors cursor-pointer"
                onClick={() => event.payload && setExpanded((e) => !e)}
            >
                <td className="px-4 py-2.5">
                    <span className="font-mono text-sm text-foreground">
                        {event.name}
                    </span>
                </td>
                {event.queue !== undefined && (
                    <td className="px-4 py-2.5 text-xs text-muted-foreground font-mono">
                        {event.queue}
                    </td>
                )}
                <td className="px-4 py-2.5 text-xs text-muted-foreground">
                    {event.createdAt ? formatRelative(event.createdAt) : "—"}
                </td>
                <td className="px-4 py-2.5">
                    {event.payload ? (
                        <span className="text-xs text-brand hover:underline cursor-pointer">
                            {expanded ? "Hide payload" : "View payload"}
                        </span>
                    ) : (
                        <span className="text-xs text-muted-foreground/50">
                            no payload
                        </span>
                    )}
                </td>
            </tr>
            {expanded && event.payload && (
                <tr className="border-b border-border/40 bg-secondary/10">
                    <td
                        colSpan={event.queue !== undefined ? 4 : 3}
                        className="px-4 pb-3 pt-1"
                    >
                        <JsonView value={event.payload} />
                    </td>
                </tr>
            )}
        </>
    );
}

export function EventsPage() {
    usePageTitle("Events");
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const [selectedQueue, setSelectedQueue] = useState("");
    const [cursor, setCursor] = useState<string | undefined>(undefined);
    const [history, setHistory] = useState<string[]>([]);

    const { data: queues = [] } = useQuery({
        queryKey: qk.queues.list(namespace),
        queryFn: () => getQueues(namespace),
    });

    const { data, isLoading } = useQuery({
        queryKey: ["events-global", namespace, selectedQueue, cursor],
        queryFn: () =>
            getEventsGlobal(namespace, {
                queue: selectedQueue || undefined,
                cursor,
                limit: 50,
            }),
        refetchInterval: 10_000,
    });

    const showQueueCol = !selectedQueue;

    return (
        <div className="px-6 py-5">
            <div className="flex items-center justify-between mb-4">
                <h1 className="text-base font-semibold text-foreground">
                    Events
                </h1>
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
            </div>

            <div className="rounded-lg border border-border/50 bg-secondary/10 px-4 py-3 mb-4 text-xs text-muted-foreground space-y-1.5">
                <p>
                    <strong className="text-foreground">Events</strong> are
                    named payloads stored in{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        strand.events
                    </code>{" "}
                    and emitted via{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        client.emitEvent()
                    </code>
                    . A workflow blocked in{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        ctx.waitForEvent()
                    </code>{" "}
                    wakes and receives the payload. If the event arrives before
                    the workflow reaches the wait, it is already stored — no
                    race condition.
                </p>
                <p>
                    <strong className="text-foreground">Signals</strong> are
                    different: they mutate workflow state via{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        handleSignal()
                    </code>{" "}
                    and are sent to a specific task UUID via{" "}
                    <code className="font-mono bg-secondary/60 px-1 rounded">
                        handle.signal()
                    </code>
                    . Signals do not appear here.
                </p>
            </div>

            {isLoading && (
                <p className="text-sm text-muted-foreground">Loading…</p>
            )}

            {data && (
                <>
                    {data.items.length === 0 ? (
                        <EmptyState
                            variant="events"
                            title="No events emitted yet"
                            description="Events appear here when emitted via client.emitEvent()."
                        />
                    ) : (
                        <div className="rounded-lg border border-border overflow-hidden">
                            <table className="w-full text-sm">
                                <thead>
                                    <tr className="border-b border-border bg-secondary/20">
                                        <th className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
                                            Event
                                        </th>
                                        {showQueueCol && (
                                            <th className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
                                                Queue
                                            </th>
                                        )}
                                        <th className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
                                            Seen At
                                        </th>
                                        <th className="text-left px-4 py-2.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide">
                                            Payload
                                        </th>
                                    </tr>
                                </thead>
                                <tbody>
                                    {data.items.map((ev, i) => (
                                        <EventRow
                                            key={i}
                                            event={
                                                showQueueCol
                                                    ? ev
                                                    : {
                                                          ...ev,
                                                          queue: undefined,
                                                      }
                                            }
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
        </div>
    );
}
