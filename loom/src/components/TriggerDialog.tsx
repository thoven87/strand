import { useState, useEffect } from "react";
import { Loader2, Zap, Play, ExternalLink } from "lucide-react";
import { useMutation } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { JsonEditor } from "@/components/JsonEditor";
import { triggerWorkflow, enqueueActivity } from "@/api/workflows";

/**
 * Shared dialog for dispatching both workflows ("Run") and standalone activities
 * ("Enqueue").  Pass `kind="ACTIVITY"` for the activity variant; the default is
 * `kind="WORKFLOW"`.  The two variants differ only in header text, button colour,
 * the name-field label, and the API call — everything else (queue, JSON input,
 * optional description) is identical.
 */
interface TriggerDialogProps {
    open: boolean;
    onClose: () => void;
    namespace: string;
    kind?: "WORKFLOW" | "ACTIVITY";
    /** Pre-fill the task name field (workflow name or activity name). */
    initialWorkflowName?: string;
    /** Alias for `initialWorkflowName` when kind="ACTIVITY". */
    initialActivityName?: string;
    /** Pre-fill the queue (e.g. when triggered from a task detail page). */
    initialQueue?: string;
    /**
     * Pre-fill the JSON editor with a template derived from a past run's input.
     * Typically produced by `nullifyValues(task.params)` — keys preserved, all
     * primitive values replaced with `null` so the schema is visible but the
     * user is forced to supply fresh values.
     */
    initialInput?: string;
}

export function TriggerDialog({
    open,
    onClose,
    namespace,
    kind = "WORKFLOW",
    initialWorkflowName,
    initialActivityName,
    initialQueue,
    initialInput,
}: TriggerDialogProps) {
    const isActivity = kind === "ACTIVITY";
    const initialName = isActivity
        ? (initialActivityName ?? initialWorkflowName ?? "")
        : (initialWorkflowName ?? "");

    const [taskName, setTaskName] = useState("");
    const [queue, setQueue] = useState("");
    const [input, setInput] = useState("{}");
    const [description, setDescription] = useState("");
    const [result, setResult] = useState<{
        taskID: string;
        runID: string;
        attempt: number;
    } | null>(null);

    const mutation = useMutation({
        mutationFn: () => {
            const desc = description.trim() || undefined;
            if (isActivity) {
                return enqueueActivity(
                    namespace,
                    taskName.trim(),
                    input,
                    queue.trim() || undefined,
                    desc,
                );
            }
            return triggerWorkflow(
                namespace,
                taskName.trim(),
                input,
                queue.trim() || undefined,
                desc,
            );
        },
        onSuccess: (data) => {
            setResult(data);
            const timer = setTimeout(() => {
                handleClose();
            }, 4_000);
            return () => clearTimeout(timer);
        },
    });

    // Reset state when dialog opens
    useEffect(() => {
        if (open) {
            setTaskName(initialName);
            setQueue(initialQueue ?? "");
            setInput(initialInput ?? "{}");
            setDescription("");
            setResult(null);
            mutation.reset();
        }
        // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [open]);

    function handleClose() {
        if (mutation.isPending) return;
        onClose();
    }

    function handleSubmit() {
        if (!taskName.trim()) return;
        mutation.mutate();
    }

    function handleBackdropClick(e: React.MouseEvent<HTMLDivElement>) {
        if (e.target === e.currentTarget) handleClose();
    }

    if (!open) return null;

    const nameLabel = isActivity ? "Activity name" : "Workflow name";
    const namePlaceholder = isActivity
        ? "e.g. ChargeCardActivity"
        : "e.g. SpaceMissionWorkflow";
    const isNameReadOnly = !!initialName;

    return (
        <div
            className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
            onClick={handleBackdropClick}
        >
            <div
                className="relative w-full max-w-2xl rounded-xl border border-border bg-background shadow-2xl"
                role="dialog"
                aria-modal="true"
                aria-labelledby="trigger-dialog-title"
                onKeyDown={(e) => {
                    if (e.key === "Escape") handleClose();
                }}
            >
                {/* Header */}
                <div className="px-6 pt-6 pb-4 border-b border-border">
                    <h2
                        id="trigger-dialog-title"
                        className="text-base font-semibold text-foreground"
                    >
                        {isActivity ? "Enqueue activity" : "Run workflow"}
                    </h2>
                    <p className="mt-1 text-sm text-muted-foreground">
                        {isActivity
                            ? "Dispatch a standalone activity immediately with a custom input."
                            : "Run a workflow immediately with a custom input."}
                    </p>
                </div>

                {/* Body */}
                <div className="px-6 py-5 space-y-4">
                    {/* Success state */}
                    {result ? (
                        <div className="rounded-lg border border-green-500/30 bg-green-500/10 p-4 space-y-2">
                            <p className="text-sm font-medium text-green-300">
                                {isActivity
                                    ? "Activity enqueued"
                                    : "Workflow started"}
                            </p>
                            <div className="space-y-1">
                                <p className="text-xs text-muted-foreground">
                                    Task ID:{" "}
                                    <span className="font-mono text-foreground">
                                        {result.taskID}
                                    </span>
                                </p>
                                <p className="text-xs text-muted-foreground">
                                    Run ID:{" "}
                                    <span className="font-mono text-foreground">
                                        {result.runID}
                                    </span>
                                </p>
                                <p className="text-xs text-muted-foreground">
                                    Attempt:{" "}
                                    <span className="font-mono text-foreground">
                                        {result.attempt}
                                    </span>
                                </p>
                            </div>
                            <a
                                href={`/${namespace}/tasks/${result.taskID}?queue=${encodeURIComponent(queue || "default")}`}
                                className="inline-flex items-center gap-1.5 text-xs text-brand hover:underline mt-1"
                            >
                                <ExternalLink size={11} />
                                View task
                            </a>
                        </div>
                    ) : (
                        <>
                            {/* Error */}
                            {mutation.error && (
                                <div className="rounded-md border border-red-500/30 bg-red-500/10 px-3.5 py-2.5">
                                    <p className="text-xs text-red-400">
                                        {String(mutation.error)}
                                    </p>
                                </div>
                            )}

                            {/* Task name */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    {nameLabel}{" "}
                                    <span className="text-red-400">*</span>
                                </label>
                                <input
                                    autoFocus={!isNameReadOnly}
                                    readOnly={isNameReadOnly}
                                    className={`w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring ${isNameReadOnly ? "opacity-70 cursor-default" : ""}`}
                                    placeholder={namePlaceholder}
                                    value={taskName}
                                    onChange={(e) =>
                                        !isNameReadOnly &&
                                        setTaskName(e.target.value)
                                    }
                                    onKeyDown={(e) => {
                                        if (e.key === "Enter") handleSubmit();
                                    }}
                                />
                            </div>

                            {/* Queue */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    Queue{" "}
                                    <span className="text-muted-foreground font-normal">
                                        (optional)
                                    </span>
                                </label>
                                <input
                                    className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
                                    placeholder="orders (leave blank for default)"
                                    value={queue}
                                    onChange={(e) => setQueue(e.target.value)}
                                />
                            </div>

                            {/* Input JSON */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    Input (JSON)
                                </label>
                                <JsonEditor
                                    value={input}
                                    onChange={setInput}
                                    placeholder='{"key": "value"}'
                                    minHeight="120px"
                                />
                            </div>

                            {/* Description */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    Description{" "}
                                    <span className="text-muted-foreground font-normal">
                                        (optional)
                                    </span>
                                </label>
                                <input
                                    className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
                                    placeholder="What does this execution do?"
                                    value={description}
                                    onChange={(e) =>
                                        setDescription(e.target.value)
                                    }
                                />
                            </div>
                        </>
                    )}
                </div>

                {/* Footer */}
                <div className="flex items-center justify-end gap-2 border-t border-border px-6 py-4">
                    <Button
                        variant="outline"
                        size="sm"
                        onClick={handleClose}
                        disabled={mutation.isPending}
                    >
                        {result ? "Close" : "Cancel"}
                    </Button>
                    {!result && (
                        <Button
                            variant="default"
                            size="sm"
                            onClick={handleSubmit}
                            disabled={mutation.isPending || !taskName.trim()}
                            className={
                                isActivity
                                    ? "gap-1.5 bg-amber-600 hover:bg-amber-500 text-white border-0"
                                    : "gap-1.5"
                            }
                        >
                            {mutation.isPending ? (
                                <Loader2 size={13} className="animate-spin" />
                            ) : isActivity ? (
                                <Play size={13} />
                            ) : (
                                <Zap size={13} />
                            )}
                            {isActivity ? "Enqueue" : "Run"}
                        </Button>
                    )}
                </div>
            </div>
        </div>
    );
}
