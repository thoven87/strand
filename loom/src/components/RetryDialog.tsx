import { useState } from "react";
import { Loader2, RefreshCw } from "lucide-react";
import { Button } from "@/components/ui/button";
import type { RetryMode, RetryOptions } from "@/api/types";

// ─── Types ───────────────────────────────────────────────────────────────────

interface RetryDialogProps {
  open: boolean;
  onClose: () => void;
  onConfirm: (opts: RetryOptions) => void;
  isPending: boolean;
  taskState: string; // "FAILED" | "CANCELLED" | "COMPLETED" | etc.
}

// ─── Mode options ─────────────────────────────────────────────────────────────

interface ModeOption {
  value: RetryMode;
  label: string;
  description: string;
}

const MODE_OPTIONS: ModeOption[] = [
  {
    value: "all",
    label: "All tasks",
    description: "Retry every task in the workflow.",
  },
  {
    value: "failed_only",
    label: "Only failed tasks",
    description: "Only retry tasks that failed or were cancelled.",
  },
  {
    value: "failed_and_dependents",
    label: "Failed tasks + dependents",
    description:
      "Retry failed tasks and any downstream tasks that depend on them, even if they previously succeeded.",
  },
];

// ─── Component ────────────────────────────────────────────────────────────────

export function RetryDialog({
  open,
  onClose,
  onConfirm,
  isPending,
  taskState: _taskState,
}: RetryDialogProps) {
  const [mode, setMode] = useState<RetryMode>("all");
  const [resetHistory, setResetHistory] = useState(false);

  if (!open) return null;

  const handleConfirm = () => {
    onConfirm({ mode, resetHistory });
  };

  const handleBackdropClick = (e: React.MouseEvent<HTMLDivElement>) => {
    if (e.target === e.currentTarget && !isPending) {
      onClose();
    }
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/60"
      onClick={handleBackdropClick}
    >
      <div
        className="relative w-full max-w-md rounded-xl border border-border bg-background shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-labelledby="retry-dialog-title"
      >
        {/* ── Header ────────────────────────────────────────────────── */}
        <div className="px-6 pt-6 pb-4">
          <h2
            id="retry-dialog-title"
            className="text-base font-semibold text-foreground"
          >
            Retry workflow
          </h2>
          <p className="mt-1 text-sm text-muted-foreground">
            Choose how to retry this workflow.
          </p>
        </div>

        {/* ── Body ──────────────────────────────────────────────────── */}
        <div className="px-6 pb-4 space-y-4">
          {/* Mode selector */}
          <div className="space-y-2">
            {MODE_OPTIONS.map((opt) => {
              const isSelected = mode === opt.value;
              return (
                <button
                  key={opt.value}
                  type="button"
                  onClick={() => setMode(opt.value)}
                  className={`w-full rounded-lg border px-4 py-3 text-left transition-colors focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring ${
                    isSelected
                      ? "border-primary/60 bg-primary/10"
                      : "border-border bg-card/40 hover:bg-secondary/30"
                  }`}
                >
                  <div className="flex items-center gap-3">
                    {/* Radio indicator */}
                    <span
                      className={`mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center rounded-full border-2 transition-colors ${
                        isSelected
                          ? "border-primary"
                          : "border-muted-foreground/40"
                      }`}
                    >
                      {isSelected && (
                        <span className="block h-1.5 w-1.5 rounded-full bg-primary" />
                      )}
                    </span>
                    <div className="min-w-0">
                      <p className="text-sm font-medium text-foreground">
                        {opt.label}
                      </p>
                      <p className="text-xs text-muted-foreground mt-0.5">
                        {opt.description}
                      </p>
                    </div>
                  </div>
                </button>
              );
            })}
          </div>

          {/* Strand note */}
          <div className="rounded-md border border-border/60 bg-muted/20 px-3.5 py-2.5">
            <p className="text-xs text-muted-foreground leading-relaxed">
              In Strand, completed activities are automatically skipped via
              checkpoint replay regardless of mode — retrying a cancelled
              workflow always resumes from the last completed step.
            </p>
          </div>

          {/* Reset history checkbox */}
          <div>
            <p className="text-[10px] uppercase tracking-wide font-medium text-muted-foreground mb-2">
              Options
            </p>
            <label className="flex cursor-pointer items-start gap-3">
              <span className="mt-0.5 flex h-4 w-4 shrink-0 items-center justify-center">
                <input
                  type="checkbox"
                  checked={resetHistory}
                  onChange={(e) => setResetHistory(e.target.checked)}
                  className="h-4 w-4 rounded border-border bg-background accent-primary cursor-pointer"
                />
              </span>
              <div className="min-w-0">
                <p className="text-sm font-medium text-foreground leading-tight">
                  Reset history
                </p>
                <p className="text-xs text-muted-foreground mt-0.5 leading-relaxed">
                  Resets attempt counts and clears error history. If unchecked,
                  attempt count continues from where it left off and max
                  attempts is extended by one.
                </p>
              </div>
            </label>
          </div>
        </div>

        {/* ── Footer ────────────────────────────────────────────────── */}
        <div className="flex items-center justify-end gap-2 border-t border-border px-6 py-4">
          <Button
            variant="outline"
            size="sm"
            onClick={onClose}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            variant="default"
            size="sm"
            onClick={handleConfirm}
            disabled={isPending}
          >
            {isPending ? (
              <Loader2 size={13} className="animate-spin" />
            ) : (
              <RefreshCw size={13} />
            )}
            Retry
          </Button>
        </div>
      </div>
    </div>
  );
}
