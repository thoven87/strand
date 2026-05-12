import { useState } from "react";
import {
    ChevronDown,
    ChevronRight,
    Copy,
    Check,
    Maximize2,
    X,
} from "lucide-react";
import { Highlight, themes } from "prism-react-renderer";
import { cn } from "@/lib/utils";
import { useIsDark } from "@/lib/theme";

interface Props {
    value: string | null;
    label?: string;
    className?: string;
}

function JsonCode({
    pretty,
    className,
}: {
    pretty: string;
    className?: string;
}) {
    const isDark = useIsDark();
    const prismTheme = isDark ? themes.vsDark : themes.vsLight;
    const codeBg = isDark ? "rgba(2,6,23,0.8)" : "rgba(248,250,252,1)";
    const lines = pretty.split("\n");
    const gutterWidth = String(lines.length).length;
    return (
        <Highlight theme={prismTheme} code={pretty} language="json">
            {({
                className: hlClass,
                style,
                tokens,
                getLineProps,
                getTokenProps,
            }) => (
                <pre
                    className={cn(
                        hlClass,
                        className,
                        "rounded-md border border-border/40 px-0 py-2.5 text-xs font-mono leading-relaxed",
                    )}
                    style={{ ...style, backgroundColor: codeBg }}
                >
                    {tokens.map((line, i) => {
                        const { key: _k, ...lineProps } = getLineProps({
                            line,
                        });
                        return (
                            <div key={i} {...lineProps} className="flex px-3.5">
                                <span
                                    className="select-none text-right shrink-0 text-slate-600 mr-4"
                                    style={{ width: `${gutterWidth}ch` }}
                                >
                                    {i + 1}
                                </span>
                                <span className="flex-1">
                                    {line.map((token, key) => {
                                        const { key: _tk, ...tokenProps } =
                                            getTokenProps({ token });
                                        return (
                                            <span key={key} {...tokenProps} />
                                        );
                                    })}
                                </span>
                            </div>
                        );
                    })}
                </pre>
            )}
        </Highlight>
    );
}

export function JsonView({ value, label, className }: Props) {
    const [open, setOpen] = useState(true);
    const [copied, setCopied] = useState(false);
    const [expanded, setExpanded] = useState(false);

    function handleCopy() {
        if (!value) return;
        navigator.clipboard.writeText(value).then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 2000);
        });
    }

    if (!value) {
        return (
            <span className="text-xs text-muted-foreground italic">
                {label ? `${label}: ` : ""}empty
            </span>
        );
    }

    let pretty = value;
    try {
        pretty = JSON.stringify(JSON.parse(value), null, 2);
    } catch {
        /* not JSON — display as-is */
    }

    return (
        <div className={cn(className)}>
            {label && (
                <button
                    onClick={() => setOpen((o) => !o)}
                    className="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground mb-1 transition-colors"
                >
                    {open ? (
                        <ChevronDown size={12} />
                    ) : (
                        <ChevronRight size={12} />
                    )}
                    {label}
                </button>
            )}
            {open && (
                <div className="relative group">
                    {/* Action buttons (top-right corner) */}
                    <div className="absolute top-2 right-2 z-10 flex gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                        <button
                            onClick={() => setExpanded(true)}
                            title="Expand full screen"
                            className="rounded p-1 text-muted-foreground hover:text-foreground hover:bg-secondary/60 transition-colors"
                        >
                            <Maximize2 size={12} />
                        </button>
                        <button
                            onClick={handleCopy}
                            title="Copy to clipboard"
                            className="rounded p-1 text-muted-foreground hover:text-foreground hover:bg-secondary/60 transition-colors"
                        >
                            {copied ? <Check size={12} /> : <Copy size={12} />}
                        </button>
                    </div>
                    <JsonCode
                        pretty={pretty}
                        className="overflow-auto max-h-80"
                    />
                </div>
            )}

            {/* Full-screen modal */}
            {expanded && (
                <div
                    className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 p-6"
                    onClick={() => setExpanded(false)}
                >
                    <div
                        className="relative w-full max-w-5xl max-h-full rounded-xl border border-border shadow-2xl overflow-hidden flex flex-col"
                        style={{ backgroundColor: "rgba(2,6,23,0.97)" }}
                        onClick={(e) => e.stopPropagation()}
                        onKeyDown={(e) =>
                            e.key === "Escape" && setExpanded(false)
                        }
                    >
                        {/* Modal header */}
                        <div className="flex items-center justify-between px-4 py-2.5 border-b border-border/40 shrink-0">
                            <span className="text-xs text-muted-foreground font-mono">
                                {label ?? "JSON"}
                            </span>
                            <div className="flex items-center gap-1">
                                <button
                                    onClick={handleCopy}
                                    className="rounded p-1 text-muted-foreground hover:text-foreground hover:bg-secondary/60 transition-colors"
                                    title="Copy to clipboard"
                                >
                                    {copied ? (
                                        <Check size={12} />
                                    ) : (
                                        <Copy size={12} />
                                    )}
                                </button>
                                <button
                                    onClick={() => setExpanded(false)}
                                    className="rounded p-1 text-muted-foreground hover:text-foreground hover:bg-secondary/60 transition-colors"
                                    title="Close"
                                >
                                    <X size={14} />
                                </button>
                            </div>
                        </div>
                        {/* Scrollable code */}
                        <div className="overflow-auto flex-1">
                            <JsonCode
                                pretty={pretty}
                                className="rounded-none border-0"
                            />
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
}
