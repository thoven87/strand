import {
    createRootRoute,
    createRoute,
    createRouter,
    Outlet,
    redirect,
} from "@tanstack/react-router";
import { Shell } from "@/components/layout/Shell";
import { TasksPage } from "@/routes/tasks";
import { RunsPage } from "@/routes/runs";
import { TaskDetailPage } from "@/routes/tasks_/$taskId";
import { EventsPage } from "@/routes/events";
import { SchedulesPage } from "@/routes/schedules";
import { ScheduleDetailPage } from "@/routes/schedules_/$scheduleId";
import { QueuesPage } from "@/routes/queues";
import { QueueDetailPage } from "@/routes/queues_/$queue";
import { WorkersPage } from "@/routes/workers";
import { WorkerDetailPage } from "@/routes/workers_/$workerId";
import { WorkflowsPage } from "@/routes/workflows";
import { MetricsPage } from "@/routes/metrics";
import { TaskTracePage } from "@/routes/tasks_/$taskId.trace";
import { NotFound } from "@/routes/not-found";
import { getStoredNamespace } from "@/lib/namespace";

// ── Root ───────────────────────────────────────────────────────────────────

const rootRoute = createRootRoute({
    component: () => (
        <Shell>
            <Outlet />
        </Shell>
    ),
    notFoundComponent: NotFound,
});

// ── Index → /{storedNamespace}/tasks ──────────────────────────────────────

const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    beforeLoad: () => {
        throw redirect({ to: `/${getStoredNamespace()}/tasks` as never });
    },
});

// ── /$namespace parent ─────────────────────────────────────────────────────
// All user-facing routes live under this parent so the namespace is always
// present in the URL path. The component just renders <Outlet />.

const namespaceRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "$namespace",
    component: () => <Outlet />,
});

// Redirect bare /$namespace → /$namespace/tasks
const namespaceIndexRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "/",
    beforeLoad: ({ params }) => {
        throw redirect({
            to: "/$namespace/tasks",
            params: { namespace: params.namespace },
        });
    },
});

// ── /$namespace/runs ─────────────────────────────────────────────────────

const runsRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "runs",
    component: RunsPage,
});

// ── /$namespace/tasks ──────────────────────────────────────────────────────

const tasksRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "tasks",
    component: TasksPage,
});

// ── /$namespace/tasks/$taskId ──────────────────────────────────────────────

const taskDetailRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "tasks/$taskId",
    component: TaskDetailPage,
});

// ── /$namespace/tasks/$taskId/trace ───────────────────────────────────────

const taskTraceRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "tasks/$taskId/trace",
    component: TaskTracePage,
});

// ── /$namespace/events ─────────────────────────────────────────────────────

const eventsRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "events",
    component: EventsPage,
});

// ── /$namespace/schedules ──────────────────────────────────────────────────

const schedulesRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "schedules",
    component: SchedulesPage,
});

// ── /$namespace/schedules/$scheduleId ──────────────────────────────────────

const scheduleDetailRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "schedules/$scheduleId",
    component: ScheduleDetailPage,
});

// ── /$namespace/queues ─────────────────────────────────────────────────────

const queuesRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "queues",
    component: QueuesPage,
});

// ── /$namespace/workers ────────────────────────────────────────────────────

const workersRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "workers",
    component: WorkersPage,
});

// ── /$namespace/workers/$workerId ──────────────────────────────────────
// $workerId is URL-encoded (":" → "%3A") — decoded in the page component.

const workerDetailRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "workers/$workerId",
    component: WorkerDetailPage,
});

// ── /$namespace/workflows ──────────────────────────────────────────────────

const workflowsRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "workflows",
    component: WorkflowsPage,
});

// ── /$namespace/queues/$queue ─────────────────────────────────────────────

const queueDetailRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "queues/$queue",
    component: QueueDetailPage,
});

// ── /$namespace/metrics ────────────────────────────────────────────────────────

const metricsRoute = createRoute({
    getParentRoute: () => namespaceRoute,
    path: "metrics",
    component: MetricsPage,
});

// ── Legacy redirects ────────────────────────────────────────────────────────
// Old flat routes redirect to the namespace-scoped equivalents using the
// stored namespace so any existing bookmarks keep working.

const legacyTasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks",
    beforeLoad: () => {
        throw redirect({
            to: `/${getStoredNamespace()}/runs` as never,
        });
    },
});

const legacyQueueRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/queues/$queue",
    beforeLoad: ({ params }) => {
        throw redirect({
            to: `/${getStoredNamespace()}/tasks` as never,
            search: { queue: params.queue } as never,
        });
    },
});

const legacyQueueTasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/queues/$queue/tasks/$taskId",
    beforeLoad: ({ params }) => {
        throw redirect({
            to: `/${getStoredNamespace()}/tasks/${params.taskId}` as never,
            search: { queue: params.queue } as never,
        });
    },
});

const legacyQueueEventsRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/queues/$queue/events",
    beforeLoad: ({ params }) => {
        throw redirect({
            to: `/${getStoredNamespace()}/events` as never,
            search: { queue: params.queue } as never,
        });
    },
});

// ── Router ─────────────────────────────────────────────────────────────────

const routeTree = rootRoute.addChildren([
    indexRoute,
    namespaceRoute.addChildren([
        namespaceIndexRoute,
        tasksRoute,
        runsRoute,
        taskDetailRoute,
        taskTraceRoute,
        eventsRoute,
        schedulesRoute,
        scheduleDetailRoute,
        queuesRoute,
        queueDetailRoute,
        workersRoute,
        workerDetailRoute,
        workflowsRoute,
        metricsRoute,
    ]),
    legacyTasksRoute,
    legacyQueueRoute,
    legacyQueueTasksRoute,
    legacyQueueEventsRoute,
]);

export const router = createRouter({ routeTree });
