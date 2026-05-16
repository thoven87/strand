import { useMemo, useState } from "react";
import type { TraceSpan, SpanState } from "@/components/TraceTree";

// ── Layout constants ──────────────────────────────────────────────────────

const NODE_W = 172; // node width
const NODE_H = 58; // node height
const H_GAP = 20; // horizontal gap between sibling nodes (same depth)
const V_GAP = 68; // vertical gap between depth levels — must fit bezier curves
const OFFSET = 16; // padding from SVG edge so hover strokes are never clipped

// ── State accent colours ──────────────────────────────────────────────────

const STATE_COLOR: Record<SpanState, string> = {
    COMPLETED: "#22c55e",
    RUNNING: "#facc15",
    WAITING: "#94a3b8",
    FAILED: "#ef4444",
    CRASHED: "#ef4444",
    TIMED_OUT: "#ef4444",
    CANCELLED: "#64748b",
    RETRYING: "#f59e0b",
    PENDING: "#3b82f6",
    DELAYED: "#3b82f6",
};

// ── Kind badge ────────────────────────────────────────────────────────────

function kindBadge(kind: TraceSpan["kind"]): { label: string; fill: string } {
    switch (kind) {
        case "WORKFLOW":
            return { label: "W", fill: "#3b82f6" };
        case "ACTIVITY":
            return { label: "A", fill: "#f59e0b" };
        case "SLEEP":
            return { label: "S", fill: "#94a3b8" };
        case "WAIT":
            return { label: "~", fill: "#6366f1" };
        case "SIGNAL":
            return { label: "sig", fill: "#a855f7" };
        case "EMIT":
            return { label: "emit", fill: "#f59e0b" };
        case "CONDITION":
            return { label: "cond", fill: "#94a3b8" };
        case "LOG":
            return { label: "L", fill: "#64748b" };
        default:
            return { label: "?", fill: "#64748b" };
    }
}

// ── Duration formatter ────────────────────────────────────────────────────

function fmtMs(ms: number): string {
    if (!isFinite(ms) || ms < 0) return "—";
    if (ms < 1_000) return `${Math.round(ms)}ms`;
    return `${(ms / 1_000).toFixed(1)}s`;
}

// ── DAG node ──────────────────────────────────────────────────────────────

interface DagNode {
    span: TraceSpan;
    depth: number; // which row (y-axis)
    x: number; // pixel left edge of node
    y: number; // pixel top edge of node
    parentId: string | null;
}

// ── Layout: top-to-bottom, centred over children ──────────────────────────
//
// Phase 1 – leaves get sequential horizontal slots.
// Phase 2 – each internal node centres itself between its leftmost and
//            rightmost child (classic Reingold-Tilford centre pass).
//
// Fan-outs spread horizontally; sequential chains go downward.
// Multiple top-level spans are placed side-by-side.

function layoutNodes(spans: TraceSpan[]): DagNode[] {
    const nodes: DagNode[] = [];
    let leafSlot = 0; // global x-slot counter; each leaf claims one slot

    function visit(
        span: TraceSpan,
        depth: number,
        parentId: string | null,
    ): number /* returns the centre x (in slot units) of this subtree */ {
        const children = span.children ?? [];

        let cx: number;

        if (children.length === 0) {
            // Leaf: claim the next slot.
            cx = leafSlot * (NODE_W + H_GAP);
            leafSlot++;
        } else {
            // Internal: recurse first, then centre over first↔last child.
            const childCentres = children.map((c) =>
                visit(c, depth + 1, span.id),
            );
            cx = (childCentres[0] + childCentres[childCentres.length - 1]) / 2;
        }

        nodes.push({
            span,
            depth,
            x: OFFSET + cx,
            y: OFFSET + depth * (NODE_H + V_GAP),
            parentId,
        });

        return cx;
    }

    spans.forEach((s) => visit(s, 0, null));
    return nodes;
}

// ── Props ─────────────────────────────────────────────────────────────────

export interface WorkflowDagProps {
    spans: TraceSpan[];
    totalMs: number; // API-compat; unused by graph layout
    onViewTask?: (taskId: string) => void;
}

// ── WorkflowDag ───────────────────────────────────────────────────────────

export function WorkflowDag({ spans, onViewTask }: WorkflowDagProps) {
    const [hoveredId, setHoveredId] = useState<string | null>(null);

    const nodes = useMemo(() => layoutNodes(spans), [spans]);

    // SVG canvas size — just large enough to contain all nodes + offset.
    const { svgW, svgH } = useMemo(() => {
        if (nodes.length === 0) return { svgW: 320, svgH: 160 };
        const maxX = Math.max(...nodes.map((n) => n.x));
        const maxDepth = Math.max(...nodes.map((n) => n.depth));
        return {
            svgW: maxX + NODE_W + OFFSET,
            svgH: OFFSET + (maxDepth + 1) * (NODE_H + V_GAP) - V_GAP + OFFSET,
        };
    }, [nodes]);

    const nodeById = useMemo(() => {
        const m = new Map<string, DagNode>();
        nodes.forEach((n) => m.set(n.span.id, n));
        return m;
    }, [nodes]);

    // Bezier edges: bottom-centre of parent → top-centre of child.
    // Control points meet at the vertical midpoint so curves are symmetric.
    const edges = useMemo(() => {
        const out: { id: string; d: string }[] = [];
        for (const child of nodes) {
            if (!child.parentId) continue;
            const parent = nodeById.get(child.parentId);
            if (!parent) continue;

            const px = parent.x + NODE_W / 2; // parent bottom-centre
            const py = parent.y + NODE_H;
            const cx = child.x + NODE_W / 2; // child  top-centre
            const cy = child.y;
            const my = (py + cy) / 2; // shared y of control points

            out.push({
                id: `${parent.span.id}→${child.span.id}`,
                d: `M ${px} ${py} C ${px} ${my}, ${cx} ${my}, ${cx} ${cy}`,
            });
        }
        return out;
    }, [nodes, nodeById]);

    if (spans.length === 0) {
        return (
            <div className="flex h-full items-center justify-center">
                <p className="text-sm text-muted-foreground">
                    No spans to display.
                </p>
            </div>
        );
    }

    return (
        <div className="overflow-auto h-full select-none p-4">
            <svg
                width={svgW}
                height={svgH}
                style={{ display: "block", margin: "0 auto" }}
            >
                {/* Clip paths — one per node, shaped to card bounds so the
                    top accent bar is clipped to the card's rounded top corners */}
                <defs>
                    {nodes.map(({ span, x, y }) => (
                        <clipPath key={span.id} id={`nc-${span.id}`}>
                            <rect
                                x={x}
                                y={y}
                                width={NODE_W}
                                height={NODE_H}
                                rx={6}
                            />
                        </clipPath>
                    ))}
                </defs>

                {/* ── Edges ────────────────────────────────────────────── */}
                {edges.map(({ id, d }) => (
                    <path
                        key={id}
                        d={d}
                        fill="none"
                        stroke="hsl(var(--border))"
                        strokeWidth={1.5}
                    />
                ))}

                {/* ── Nodes ────────────────────────────────────────────── */}
                {nodes.map((node) => {
                    const { span, x, y } = node;
                    const hovered = hoveredId === span.id;
                    const clickable = !!span.taskId && !!onViewTask;
                    const accent = STATE_COLOR[span.state] ?? "#94a3b8";
                    const { label: badgeLabel, fill: badgeFill } = kindBadge(
                        span.kind,
                    );
                    const name =
                        span.name.length > 21
                            ? `${span.name.slice(0, 21)}\u2026`
                            : span.name;

                    return (
                        <g
                            key={span.id}
                            style={{
                                cursor: clickable ? "pointer" : "default",
                            }}
                            onMouseEnter={() => setHoveredId(span.id)}
                            onMouseLeave={() => setHoveredId(null)}
                            onClick={() =>
                                clickable && onViewTask!(span.taskId!)
                            }
                        >
                            {/* Card background */}
                            <rect
                                x={x}
                                y={y}
                                width={NODE_W}
                                height={NODE_H}
                                rx={6}
                                fill="hsl(var(--card))"
                                stroke={
                                    hovered
                                        ? "hsl(var(--primary))"
                                        : "hsl(var(--border))"
                                }
                                strokeWidth={hovered ? 1.75 : 1}
                            />

                            {/* Top accent stripe — clipped so it respects
                                the card's rounded top corners */}
                            <rect
                                x={x}
                                y={y}
                                width={NODE_W}
                                height={4}
                                fill={accent}
                                clipPath={`url(#nc-${span.id})`}
                            />

                            {/* Task name */}
                            <text
                                x={x + 10}
                                y={y + 26}
                                fontSize={12}
                                fill="hsl(var(--foreground))"
                                fontFamily="ui-sans-serif, system-ui, sans-serif"
                            >
                                {name}
                            </text>

                            {/* Duration */}
                            <text
                                x={x + 10}
                                y={y + 43}
                                fontSize={10}
                                fill="hsl(var(--muted-foreground))"
                                fontFamily="ui-sans-serif, system-ui, sans-serif"
                            >
                                {fmtMs(span.durationMs)}
                            </text>

                            {/* Kind badge (top-right) */}
                            <rect
                                x={x + NODE_W - 24}
                                y={y + 6}
                                width={18}
                                height={13}
                                rx={3}
                                fill={badgeFill}
                                opacity={0.9}
                            />
                            <text
                                x={x + NODE_W - 15}
                                y={y + 16}
                                fontSize={9}
                                textAnchor="middle"
                                fill="white"
                                fontWeight="bold"
                                fontFamily="ui-sans-serif, system-ui, sans-serif"
                            >
                                {badgeLabel}
                            </text>
                        </g>
                    );
                })}
            </svg>
        </div>
    );
}
