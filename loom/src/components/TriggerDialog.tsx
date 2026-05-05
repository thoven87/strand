import { useState, useEffect } from "react";
import { Loader2, Zap, ExternalLink } from "lucide-react";
import { useMutation } from "@tanstack/react-query";
import { Button } from "@/components/ui/button";
import { triggerWorkflow } from "@/api/workflows";

interface TriggerDialogProps {
  open: boolean;
  onClose: () => void;
  namespace: string;
}

export function TriggerDialog({
  open,
  onClose,
  namespace,
}: TriggerDialogProps) {
  const [workflowName, setWorkflowName] = useState("");
  const [queue, setQueue] = useState("");
  const [input, setInput] = useState("{}");
  const [result, setResult] = useState<{
    taskID: string;
    runID: string;
    attempt: number;
  } | null>(null);

  const mutation = useMutation({
    mutationFn: () =>
      triggerWorkflow(
        namespace,
        workflowName.trim(),
        input,
        queue.trim() || undefined,
      ),
    onSuccess: (data) => {
      setResult(data);
      // Auto-close after 4s if user doesn't interact
      const timer = setTimeout(() => {
        handleClose();
      }, 4_000);
      return () => clearTimeout(timer);
    },
  });

  // Reset state when dialog opens
  useEffect(() => {
    if (open) {
      setWorkflowName("");
      setQueue("");
      setInput("{}");
      setResult(null);
      mutation.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open]);

  function handleClose() {
    if (mutation.isPending) return;
    onClose();
  }

  function handleTrigger() {
    if (!workflowName.trim()) return;
    mutation.mutate();
  }

  function handleBackdropClick(e: React.MouseEvent<HTMLDivElement>) {
    if (e.target === e.currentTarget) handleClose();
  }

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
      onClick={handleBackdropClick}
    >
      <div
        className="relative w-full max-w-md rounded-xl border border-border bg-background shadow-2xl"
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
            Trigger workflow
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Run a workflow immediately with a custom input.
          </p>
        </div>

        {/* Body */}
        <div className="px-6 py-5 space-y-4">
          {/* Success state */}
          {result ? (
            <div className="rounded-lg border border-green-500/30 bg-green-500/10 p-4 space-y-2">
              <p className="text-sm font-medium text-green-300">
                Workflow triggered successfully
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
                href={`/${namespace}/tasks/${result.taskID}?queue=${encodeURIComponent(queue)}`}
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

              {/* Workflow name */}
              <div className="space-y-1.5">
                <label className="text-xs font-medium text-foreground">
                  Workflow name <span className="text-red-400">*</span>
                </label>
                <input
                  autoFocus
                  className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
                  placeholder="e.g. SpaceMissionWorkflow"
                  value={workflowName}
                  onChange={(e) => setWorkflowName(e.target.value)}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") handleTrigger();
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
                <textarea
                  rows={6}
                  className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring resize-none"
                  placeholder='{"key": "value"}'
                  value={input}
                  onChange={(e) => setInput(e.target.value)}
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
              onClick={handleTrigger}
              disabled={mutation.isPending || !workflowName.trim()}
            >
              {mutation.isPending ? (
                <Loader2 size={13} className="animate-spin" />
              ) : (
                <Zap size={13} />
              )}
              Trigger
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}
