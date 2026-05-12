import { api } from "./client";
import type { CursorPage, StrandEvent, EventTrigger } from "./types";

export interface EventWaiter {
    taskId: string;
    taskName: string;
    taskState: string;
    seqNum: number;
    timeoutAt: string | null;
}

export const getEvents = (
    namespace: string,
    queue: string,
    opts: { cursor?: string; limit?: number } = {},
) =>
    api
        .get<
            CursorPage<StrandEvent>
        >(`/api/${namespace}/queues/${queue}/events`, { params: opts })
        .then((r) => r.data);

export const getEventsGlobal = (
    namespace: string,
    opts: {
        queue?: string;
        name?: string;
        cursor?: string;
        limit?: number;
        since?: string;
    } = {},
) =>
    api
        .get<CursorPage<StrandEvent & { queue: string }>>(
            `/api/${namespace}/events`,
            { params: opts },
        )
        .then((r) => r.data)
        .catch(
            () =>
                ({ items: [], nextCursor: null }) as CursorPage<
                    StrandEvent & { queue: string }
                >,
        );

export const getEventWaiters = (
    namespace: string,
    queue: string,
    eventName: string,
): Promise<EventWaiter[]> =>
    api
        .get<EventWaiter[]>(
            `/api/${namespace}/queues/${encodeURIComponent(queue)}/events/${encodeURIComponent(eventName)}/waiters`,
        )
        .then((r) => r.data)
        .catch(() => [] as EventWaiter[]);

export const emitEvent = (
    namespace: string,
    queue: string,
    name: string,
    payload?: string,
): Promise<{ message: string; id: string }> =>
    api
        .post(`/api/${namespace}/queues/${queue}/events`, {
            name,
            payload: payload ?? null,
        })
        .then((r) => r.data);

export const getEventTriggerForTask = async (
    namespace: string,
    taskId: string,
): Promise<EventTrigger | null> => {
    try {
        const res = await api.get<EventTrigger>(
            `/api/${namespace}/tasks/${taskId}/event-trigger`,
        );
        return res.data;
    } catch (err: unknown) {
        // 404 means no event trigger for this task — return null
        if (
            err &&
            typeof err === "object" &&
            "response" in err &&
            (err as { response?: { status?: number } }).response?.status === 404
        ) {
            return null;
        }
        throw err;
    }
};
