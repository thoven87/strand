import { useState } from "react";
import { Loader2, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { JsonView } from "@/components/JsonView";
import type { UpdateResult } from "@/api/workflows";

interface UpdateDialogProps {
    open: boolean;
    onClose: () => void;
    onSend: (name: string, payload: string | undefined) => void;
    isPending: boolean;
    result: UpdateResult | null; // null while pending or not yet sent
}

export function UpdateDialog({
    open,
    onClose,
    onSend,
    isPending,
    result,
}: UpdateDialogProps) {
    const [name, setName] = useState("");
    const [payload, setPayload] = useState("");

    if (!open) return null;

    const hasResult = result !== null;

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
                        Send update
                    </h2>
                    <p className="text-xs text-muted-foreground mt-0.5">
                        Updates validate before applying and return a result.
                    </p>
                </div>

                {/* Body */}
                <div className="px-5 py-4 space-y-4">
                    {!hasResult ? (
                        <>
                            {/* Update name */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    Update name
                                </label>
                                <input
                                    autoFocus
                                    className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring"
                                    placeholder="e.g. setPriority, approve, escalate"
                                    value={name}
                                    onChange={(e) => setName(e.target.value)}
                                    onKeyDown={(e) => {
                                        if (e.key === "Enter" && !e.shiftKey)
                                            handleSend();
                                    }}
                                />
                            </div>

                            {/* Payload */}
                            <div className="space-y-1.5">
                                <label className="text-xs font-medium text-foreground">
                                    Payload (JSON)
                                </label>
                                <textarea
                                    rows={4}
                                    className="w-full rounded border border-border bg-secondary/30 px-3 py-2 text-sm font-mono placeholder:text-muted-foreground/50 focus:outline-none focus:ring-1 focus:ring-ring resize-none"
                                    placeholder='{"key": "value"}'
                                    value={payload}
                                    onChange={(e) => setPayload(e.target.value)}
                                />
                            </div>
                        </>
                    ) : (
                        /* Result display */
                        <div className="space-y-3">
                            {result.timedOut && (
                                <div className="rounded-md border border-amber-500/30 bg-amber-500/10 px-3 py-2.5">
                                    <p className="text-xs font-medium text-amber-400">
                                        Timed out — the workflow may still be
                                        processing.
                                    </p>
                                </div>
                            )}
                            {result.result !== null && (
                                <JsonView
                                    label="Result"
                                    value={result.result}
                                />
                            )}
                            {result.error !== null && (
                                <div className="space-y-1.5">
                                    <p className="text-xs font-medium text-red-400">
                                        Error
                                    </p>
                                    <div className="rounded-md border border-red-500/30 bg-red-500/10 px-3 py-2.5">
                                        <p className="text-xs font-mono text-red-300 break-all">
                                            {result.error}
                                        </p>
                                    </div>
                                </div>
                            )}
                        </div>
                    )}
                </div>

                {/* Footer */}
                <div className="px-5 pb-5 flex items-center justify-end gap-2">
                    {hasResult ? (
                        <Button size="sm" onClick={handleClose}>
                            Close
                        </Button>
                    ) : (
                        <>
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
                                    <Loader2
                                        size={13}
                                        className="animate-spin"
                                    />
                                ) : (
                                    <Send size={13} />
                                )}
                                Send update
                            </Button>
                        </>
                    )}
                </div>
            </div>
        </div>
    );
}
