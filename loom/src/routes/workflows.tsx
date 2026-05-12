import { useEffect } from "react";
import { useNavigate, useParams } from "@tanstack/react-router";

/** /workflows was replaced by /tasks. Redirect immediately. */
export function WorkflowsPage() {
    const { namespace } = useParams({ strict: false }) as { namespace: string };
    const navigate = useNavigate();
    useEffect(() => {
        void navigate({
            to: "/$namespace/tasks",
            params: { namespace },
            replace: true,
        });
    }, [namespace, navigate]);
    return null;
}
