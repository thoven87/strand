import { api } from "./client";
import type { CursorPage, StrandEvent } from "./types";

export const getEvents = (
    namespace: string,
    queue: string,
    opts: { cursor?: string; limit?: number } = {},
) =>
    api
        .get<CursorPage<StrandEvent>>(
            `/api/${namespace}/queues/${queue}/events`,
            {
                params: opts,
            },
        )
        .then((r) => r.data);

export const getEventsGlobal = (
    namespace: string,
    opts: { queue?: string; cursor?: string; limit?: number } = {},
) =>
    api
        .get<CursorPage<StrandEvent & { queue?: string }>>(
            `/api/${namespace}/events`,
            { params: opts },
        )
        .then((r) => r.data)
        .catch(
            () => ({ items: [], nextCursor: null }) as CursorPage<StrandEvent>,
        );
