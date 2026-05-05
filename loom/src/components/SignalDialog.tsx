import { useState } from "react";
import { Loader2, Send } from "lucide-react";
import { Button } from "@/components/ui/button";

interface SignalDialogProps {
  open: boolean;
  onClose: () => void;
  onSend: (name: string, payload: string | undefined) => void;
  isPending: boolean;
}

export function SignalDialog({
  open,
  onClose,
  onSend,
  isPending,
}: SignalDialogProps) {
  const [name, setName] = useState("");
  const [payload, setPayload] = useState("");

  if (!open) return null;

  const handleSend = () => {
    if (!name.trim()) return;
    onSend(name.trim(), payload.trim() || undefined);
  };

  const handleClose = () => {
    if (isPending) return;
    setName("");
    setPayload("");
    onClose();
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") handleClose();
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center"
      onKeyDown={handleKeyDown}
    >
      {/* Backdrop */}
      <div
        className="absolute inset-0 bg-black/60"
        onClick={handleClose}
      />

      {/* Dialog */}
      <div className="relative z-10 w-full max-w-md rounded-lg border border-border bg-background shadow-xl mx-4">
        {/* Header */}
        <div className="px-5 pt-5 pb-4 border-b border-border">
          <h2 className="text-sm font-semibold text-foreground">
            Send signal
          </h2>
          <p className="text-xs text-muted-foreground mt-0.5">
            Deliver a named signal to this workflow. The handler receives it
            on the next activation.
          </p>
        </div>

        {/* Body */}
        <div className="px-5 py-4 space-y-4">
          {/* Signal name */}
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-foreground">
              Signal name
            </label>
            <input
              autoFocus
              className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
              placeholder="e.g. approve, pause, resume"
              value={name}
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey) handleSend();
              }}
            />
          </div>

          {/* Payload */}
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-foreground">
              Payload{" "}
              <span className="text-muted-foreground font-normal">
                (optional JSON)
              </span>
            </label>
            <textarea
              rows={4}
              className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring resize-none"
              placeholder='{"key": "value"}'
              value={payload}
              onChange={(e) => setPayload(e.target.value)}
            />
          </div>
        </div>

        {/* Footer */}
        <div className="px-5 pb-5 flex items-center justify-end gap-2">
          <Button
            variant="outline"
            size="sm"
            onClick={handleClose}
            disabled={isPending}
          >
            Cancel
          </Button>
          <Button
            size="sm"
            disabled={!name.trim() || isPending}
            onClick={handleSend}
          >
            {isPending ? (
              <Loader2 size={13} className="animate-spin" />
            ) : (
              <Send size={13} />
            )}
            Send signal
          </Button>
        </div>
      </div>
    </div>
  );
}
