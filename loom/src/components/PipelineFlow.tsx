import { ChevronRight, GitBranch, Layers } from "lucide-react";
import { cn } from "@/lib/utils";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface PipelineFlowProps {
    taskName: string;
    /** ID of the most recent run task, used for "View last run trace →" link. */
    latestTaskId?: string;
    namespace?: string;
}

interface PipelineStage {
    name: string;
    label: string;
    avgDuration: string;
    detail: string;
}

interface LinearPipeline {
    kind: "linear";
    stages: PipelineStage[];
}

interface FanOutPipeline {
    kind: "fanout";
    input: PipelineStage;
    parallel: PipelineStage[];
    output: PipelineStage;
}

type PipelineSpec = LinearPipeline | FanOutPipeline;

// ── Mock data ─────────────────────────────────────────────────────────────────

const PIPELINES: Record<string, PipelineSpec> = {
    InsightsPipelineWorkflow: {
        kind: "fanout",
        input: {
            name: "TriggerPipeline",
            label: "Trigger",
            avgDuration: "12ms",
            detail: "1 pipeline",
        },
        parallel: [
            {
                name: "CatalogPipeline",
                label: "Catalog",
                avgDuration: "1.8s",
                detail: "120 products",
            },
            {
                name: "RiskPipeline",
                label: "Risk",
                avgDuration: "2.4s",
                detail: "120 signals",
            },
        ],
        output: {
            name: "ExecutiveSummary",
            label: "Summary",
            avgDuration: "340ms",
            detail: "1 report",
        },
    },
};

const DEFAULT_PIPELINE: PipelineSpec = {
    kind: "linear",
    stages: [
        {
            name: "IngestProducts",
            label: "Bronze",
            avgDuration: "200ms",
            detail: "3 records",
        },
        {
            name: "AssemblePrompts",
            label: "Silver",
            avgDuration: "150ms",
            detail: "3 prompts",
        },
        {
            name: "EnrichProducts",
            label: "Gold",
            avgDuration: "2.3s",
            detail: "3 enriched",
        },
    ],
};

// ── Sub-components ────────────────────────────────────────────────────────────

function StageNode({
    stage,
    className,
}: {
    stage: PipelineStage;
    className?: string;
}) {
    return (
        <div
            className={cn(
                "flex flex-col items-center gap-1 px-3 py-2 rounded-lg",
                "border border-border bg-secondary/30 min-w-[120px]",
                className,
            )}
        >
            <span className="text-xs font-medium text-foreground truncate max-w-[110px]">
                {stage.name}
            </span>
            <span className="text-[10px] text-muted-foreground">
                {stage.label}
            </span>
            <span className="text-[10px] font-mono text-muted-foreground">
                {stage.avgDuration}
            </span>
            <span className="text-[9px] text-muted-foreground/60">
                {stage.detail}
            </span>
        </div>
    );
}

function Arrow() {
    return (
        <div className="flex items-center shrink-0">
            <div className="h-px w-8 bg-border" />
            <ChevronRight size={12} className="text-muted-foreground -ml-1" />
        </div>
    );
}

// ── Linear layout ─────────────────────────────────────────────────────────────

function LinearFlow({ stages }: { stages: PipelineStage[] }) {
    return (
        <div className="flex items-center gap-0 flex-wrap">
            {stages.map((stage, i) => (
                <div key={stage.name} className="flex items-center">
                    <StageNode stage={stage} />
                    {i < stages.length - 1 && <Arrow />}
                </div>
            ))}
        </div>
    );
}

// ── Fan-out layout ────────────────────────────────────────────────────────────

function FanOutFlow({
    input,
    parallel,
    output,
}: {
    input: PipelineStage;
    parallel: PipelineStage[];
    output: PipelineStage;
}) {
    return (
        <div className="flex items-center gap-0">
            {/* Input node */}
            <StageNode stage={input} />
            <Arrow />

            {/* Fan-out branch */}
            <div className="flex flex-col gap-2 relative">
                {/* Vertical connector line */}
                <div className="absolute left-0 top-1/2 -translate-x-full w-8 hidden" />

                {parallel.map((stage) => (
                    <div key={stage.name} className="flex items-center">
                        <div className="h-px w-3 bg-border shrink-0" />
                        <StageNode stage={stage} />
                        <div className="h-px w-3 bg-border shrink-0" />
                    </div>
                ))}
            </div>

            <Arrow />
            {/* Output node */}
            <StageNode stage={output} />
        </div>
    );
}

// ── Main component ────────────────────────────────────────────────────────────

export function PipelineFlow({
    taskName,
    latestTaskId,
    namespace,
}: PipelineFlowProps) {
    const spec = PIPELINES[taskName] ?? DEFAULT_PIPELINE;

    const isLinear = spec.kind === "linear";
    const isFanOut = spec.kind === "fanout";

    const stageCount = isLinear
        ? spec.stages.length
        : (isFanOut ? 2 + spec.parallel.length : 0);

    return (
        <section className="rounded-lg border border-border bg-card/40 p-4">
            <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2">
                    <h2 className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                        Pipeline Structure
                    </h2>
                    <span className="inline-flex items-center gap-1 rounded border px-1.5 py-0.5 text-[10px] bg-secondary/40 text-muted-foreground border-border/60">
                        {isFanOut ? (
                            <GitBranch size={10} />
                        ) : (
                            <Layers size={10} />
                        )}
                        {isFanOut ? "fan-out" : "linear"} · {stageCount} stages
                    </span>
                </div>

                {latestTaskId && namespace && (
                    <a
                        href={`/${namespace}/tasks/${latestTaskId}`}
                        className="text-[11px] text-muted-foreground hover:text-foreground transition-colors"
                    >
                        View last run trace →
                    </a>
                )}
            </div>

            <div className="overflow-x-auto pb-1">
                {isLinear && <LinearFlow stages={spec.stages} />}
                {isFanOut && (
                    <FanOutFlow
                        input={spec.input}
                        parallel={spec.parallel}
                        output={spec.output}
                    />
                )}
            </div>

            <p className="mt-3 text-[10px] text-muted-foreground/40 italic">
                Mock data — will be wired to the trace endpoint in a future
                update.
            </p>
        </section>
    );
}
