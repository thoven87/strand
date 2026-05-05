import React, { useState, useCallback, useRef, useEffect } from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import {
  ChevronDown,
  ChevronRight,
  CheckCircle2,
  Loader2,
  Clock,
  RefreshCw,
  XCircle,
  Timer,
  AlertTriangle,
  Ban,
  Search,
  ExternalLink,
  Copy,
} from "lucide-react";
import { cn } from "@/lib/utils";

// ── Public types ─────────────────────────────────────────────────────────────

export type SpanState =
  | "COMPLETED"
  | "RUNNING" // in-flight, pulsing bar
  | "WAITING" // blocked on condition/waitForEvent (dark slate, no pulse)
  | "RETRYING" // actively being retried (amber)
  | "FAILED" // terminal failure
  | "TIMED_OUT" // exceeded timeout
  | "CRASHED" // unexpected failure (different icon from FAILED)
  | "CANCELLED"
  | "DELAYED" // queued but not started yet
  | "PENDING";

export interface TraceSpan {
  id: string;
  name: string;
  kind: "WORKFLOW" | "ACTIVITY" | "SLEEP" | "WAIT" | "LOG";
  state: SpanState;
  startMs: number;
  durationMs: number;
  /** Time spent queued before execution begins. Shown as a dashed prefix bar. */
  queuedMs?: number;
  /** Attempt number — shows ×N badge when > 1. */
  attempt?: number;
  /** Max attempts — shows ×N/M badge when set. */
  maxAttempts?: number;
  /** Error message shown below the span name and in the inspector. */
  errorMessage?: string;
  /** Log level for LOG kind rows. */
  logLevel?: "INFO" | "WARN" | "ERROR" | "DEBUG";
  /** True when this span is still in-flight (drives the live current-time line). */
  isLive?: boolean;
  /** ISO timestamp when the task was enqueued (queued/triggered). */
  createdAt?: string;
  /** ISO timestamp when the run was claimed by a worker (dequeued). */
  startedAt?: string;
  /** ISO timestamp when the run finished (completed, failed, etc.). */
  completedAt?: string;
  /** Worker that processed this run, e.g. "hostname:pid". */
  workerID?: string;
  /** Task UUID for linking to the task detail page. */
  taskId?: string;
  children?: TraceSpan[];
}

export interface TraceTreeProps {
  spans: TraceSpan[];
  totalMs: number;
  /**
   * IDs that start expanded. When omitted the component expands all depth-0
   * spans (the root level) by default.
   */
  defaultExpanded?: string[];
  /** True when the overall trace is still running (enables live current-time line). */
  isLive?: boolean;
  /** Epoch ms when the trace root started — needed for the live current-time line. */
  traceStartEpochMs?: number;
  /** Extra Tailwind classes applied to the outer wrapper div (e.g. "h-full"). */
  className?: string;
  /**
   * Called when the user clicks "View task" in the inspector panel.
   * Receives the span's taskId. When omitted the button is hidden.
   */
  onViewTask?: (taskId: string) => void;
  /** Called when a span is selected; should resolve to { input, output } for that task. */
  onLoadSpanDetail?: (
    taskId: string,
  ) => Promise<{ input: string | null; output: string | null }>;
}

// ── Internal types ────────────────────────────────────────────────────────────

interface FlatRow extends TraceSpan {
  depth: number;
  hasChildren: boolean;
  isExpanded: boolean;
}

// ── Layout constants ──────────────────────────────────────────────────────────

const LEFT_W = 300; // left panel pixel width
const HEADER_H = 28; // h-7 → 28 px
const TOOLBAR_H = 36; // approximate toolbar height (py-2 + text-xs row)
const INDENT = 20; // px per depth level

// ── Tree utilities ────────────────────────────────────────────────────────────

/** Collect span IDs down to maxDepth (0 = root only). */
function collectIds(spans: TraceSpan[], maxDepth: number, depth = 0): string[] {
  const ids: string[] = [];
  for (const s of spans) {
    if (depth <= maxDepth) {
      ids.push(s.id);
      if (s.children?.length)
        ids.push(...collectIds(s.children, maxDepth, depth + 1));
    }
  }
  return ids;
}

/** Recursively checks whether any span (or descendant) has isLive set. */
function hasAnyLiveSpan(spans: TraceSpan[]): boolean {
  return spans.some(
    (s) => s.isLive || (s.children ? hasAnyLiveSpan(s.children) : false),
  );
}

/** True for spans that count as "errors" for the Errors-only filter. */
function isErrorSpan(span: TraceSpan): boolean {
  return (
    span.state === "FAILED" ||
    span.state === "CRASHED" ||
    span.state === "TIMED_OUT" ||
    (span.kind === "LOG" && span.logLevel === "ERROR")
  );
}

/**
 * Returns the set of span IDs that should be visible when a filter is active:
 * all matching spans PLUS all their ancestors (so the tree stays navigable).
 */
function getFilterIds(
  spans: TraceSpan[],
  predicate: (s: TraceSpan) => boolean,
): Set<string> {
  // Phase 1: collect direct matches.
  const matches = new Set<string>();
  function collectMatches(span: TraceSpan) {
    if (predicate(span)) matches.add(span.id);
    span.children?.forEach(collectMatches);
  }
  spans.forEach(collectMatches);

  // Phase 2: walk top-down and mark ancestors of matches.
  const result = new Set<string>(matches);
  function collectAncestors(span: TraceSpan, path: string[]): boolean {
    let thisOrDescMatches = matches.has(span.id);
    for (const child of span.children ?? []) {
      if (collectAncestors(child, [...path, span.id])) thisOrDescMatches = true;
    }
    if (thisOrDescMatches) path.forEach((id) => result.add(id));
    return thisOrDescMatches;
  }
  spans.forEach((s) => collectAncestors(s, []));
  return result;
}

/** Walk the tree and emit only the rows that should be visible. */
function flattenVisible(
  spans: TraceSpan[],
  expanded: Set<string>,
  filterIds: Set<string> | null,
  depth = 0,
): FlatRow[] {
  const rows: FlatRow[] = [];
  for (const span of spans) {
    if (filterIds && !filterIds.has(span.id)) continue;
    const hasChildren = !!span.children?.length;
    // When a filter is active, auto-expand any ancestor whose direct child is
    // also in the filter set — this surfaces matching descendants automatically.
    const isExpanded = filterIds
      ? hasChildren && span.children!.some((c) => filterIds.has(c.id))
      : expanded.has(span.id);
    rows.push({ ...span, depth, hasChildren, isExpanded });
    if (hasChildren && isExpanded) {
      rows.push(
        ...flattenVisible(span.children!, expanded, filterIds, depth + 1),
      );
    }
  }
  return rows;
}

// ── Time-axis utilities ───────────────────────────────────────────────────────

function generateTicks(totalMs: number): number[] {
  let interval: number;
  if (totalMs <= 2_000) interval = 250;
  else if (totalMs <= 5_000) interval = 500;
  else if (totalMs <= 15_000) interval = 1_000;
  else if (totalMs <= 30_000) interval = 2_000;
  else if (totalMs <= 60_000) interval = 5_000;
  else interval = 10_000;

  const ticks: number[] = [];
  for (let t = 0; t <= totalMs; t += interval) ticks.push(t);
  return ticks;
}

function tickLabel(t: number): string {
  if (t === 0) return "0";
  if (t < 1_000) return `${t}ms`;
  const s = t / 1_000;
  return Number.isInteger(s) ? `${s}s` : `${s.toFixed(1)}s`;
}

/** Duration label — < 1 s → "Xms", < 1 m → "X.Xs", ≥ 1 m → "Xm Xs". */
function fmtDuration(ms: number): string {
  if (ms < 1_000) return `${ms}ms`;
  if (ms < 60_000) {
    const s = ms / 1_000;
    return Number.isInteger(s) ? `${s}s` : `${s.toFixed(1)}s`;
  }
  const m = Math.floor(ms / 60_000);
  const s = Math.floor((ms % 60_000) / 1_000);
  return `${m}m ${s}s`;
}

/** Fine-grained cursor time (two decimal places). */
function fmtCursorTime(ms: number): string {
  if (ms < 1_000) return `${ms}ms`;
  const s = ms / 1_000;
  return `${s.toFixed(2)}s`;
}

// ── Visual style helpers ──────────────────────────────────────────────────────

function barClass(kind: TraceSpan["kind"], state: SpanState): string {
  // SLEEP / WAIT always render as a dashed bar regardless of state.
  if (kind === "SLEEP" || kind === "WAIT")
    return "bg-slate-500/40 border border-dashed border-slate-400/70";

  switch (state) {
    case "FAILED":
      return "bg-red-500/80";
    case "CRASHED":
      return "bg-red-700/80";
    case "TIMED_OUT":
      return "bg-orange-500/80";
    case "CANCELLED":
      return "bg-slate-500/50";
    case "WAITING":
      return "bg-slate-600/60";
    case "RETRYING":
      return "bg-amber-600/80";
    case "DELAYED":
      return "border border-dashed border-slate-500 bg-transparent";
    case "PENDING":
      return "border border-dashed border-blue-500/40 bg-transparent";
    case "RUNNING":
      return kind === "WORKFLOW"
        ? "animate-pulse bg-blue-400/80"
        : "animate-pulse bg-amber-400/80";
    case "COMPLETED":
    default:
      if (kind === "WORKFLOW") return "bg-blue-500/80";
      if (kind === "ACTIVITY") return "bg-amber-500/80";
      return "bg-slate-500/60";
  }
}

/** Color class for the small left-cell state dot. */
function dotClass(state: SpanState): string {
  switch (state) {
    case "COMPLETED":
      return "bg-emerald-400";
    case "RUNNING":
      return "bg-blue-400 animate-pulse";
    case "FAILED":
      return "bg-red-500";
    case "CRASHED":
      return "bg-red-700";
    case "TIMED_OUT":
      return "bg-orange-500";
    case "RETRYING":
      return "bg-amber-500";
    case "WAITING":
      return "bg-slate-500";
    case "CANCELLED":
      return "bg-slate-500";
    case "DELAYED":
      return "bg-slate-400";
    case "PENDING":
      return "bg-yellow-400";
    default:
      return "bg-slate-500";
  }
}

/** Color class for the Gantt-panel dot on LOG kind rows. */
function logDotClass(logLevel?: "INFO" | "WARN" | "ERROR" | "DEBUG"): string {
  switch (logLevel) {
    case "INFO":
      return "bg-blue-400";
    case "WARN":
      return "bg-amber-400";
    case "ERROR":
      return "bg-red-400";
    case "DEBUG":
      return "bg-slate-400";
    default:
      return "bg-slate-400";
  }
}

/**
 * A pulsing skeleton that mimics a JSON code block.
 * Matches the border, background, and padding of the `<pre>` it replaces so
 * the transition from loading to loaded causes no layout shift.
 */
function JsonSkeleton() {
  return (
    <div className="bg-secondary/20 border border-border/30 rounded p-2 space-y-[6px] animate-pulse">
      {/* Simulate 5 lines of JSON with varying indentation / width */}
      <div className="h-[9px] rounded bg-secondary/50 w-1/4" />
      <div className="h-[9px] rounded bg-secondary/40 w-3/5 ml-3" />
      <div className="h-[9px] rounded bg-secondary/40 w-2/3 ml-3" />
      <div className="h-[9px] rounded bg-secondary/40 w-1/2 ml-3" />
      <div className="h-[9px] rounded bg-secondary/50 w-1/6" />
    </div>
  );
}

/** Right-side status icon shown in the left cell. Not rendered for LOG rows. */
function StatusIcon({ span }: { span: TraceSpan }) {
  if (span.kind === "LOG") return null;
  const size = 12;
  const wrap = "shrink-0 w-4 h-4 flex items-center justify-center";
  switch (span.state) {
    case "COMPLETED":
      return (
        <span className={wrap}>
          <CheckCircle2 size={size} className="text-emerald-400" />
        </span>
      );
    case "RUNNING":
      return (
        <span className={wrap}>
          <Loader2 size={size} className="text-blue-400 animate-spin" />
        </span>
      );
    case "WAITING":
      return (
        <span className={wrap}>
          <Clock size={size} className="text-slate-400" />
        </span>
      );
    case "RETRYING":
      return (
        <span className={wrap}>
          <RefreshCw size={size} className="text-amber-500" />
        </span>
      );
    case "FAILED":
      return (
        <span className={wrap}>
          <XCircle size={size} className="text-red-400" />
        </span>
      );
    case "TIMED_OUT":
      return (
        <span className={wrap}>
          <Timer size={size} className="text-orange-400" />
        </span>
      );
    case "CRASHED":
      return (
        <span className={wrap}>
          <AlertTriangle size={size} className="text-red-400" />
        </span>
      );
    case "CANCELLED":
      return (
        <span className={wrap}>
          <Ban size={size} className="text-slate-400" />
        </span>
      );
    case "DELAYED":
      return (
        <span className={wrap}>
          <Clock size={size} className="text-slate-400/60" />
        </span>
      );
    default:
      return null;
  }
}

// ── Timeline helpers ────────────────────────────────────────────────────────────

function fmtIso(iso: string): string {
  const d = new Date(iso);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())} ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())} UTC`;
}

function fmtRelative(iso: string): string {
  const ms = Date.now() - new Date(iso).getTime();
  if (ms < 60_000) return `${Math.round(ms / 1000)}s ago`;
  if (ms < 3_600_000) return `${Math.round(ms / 60_000)}m ago`;
  return `${Math.round(ms / 3_600_000)}h ago`;
}

function fmtGap(fromIso: string, toIso: string): string {
  const ms = new Date(toIso).getTime() - new Date(fromIso).getTime();
  if (ms < 1000) return `${ms}ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)}s`;
  return `${Math.round(ms / 60_000)}m ${Math.round((ms % 60_000) / 1000)}s`;
}

interface TimelineEventProps {
  label: string;
  iso: string;
  prev?: string;
  next?: string;
  variant: "start" | "mid" | "end" | "error";
}

function TimelineEvent({
  label,
  iso,
  prev,
  next,
  variant,
}: TimelineEventProps) {
  const dotColor =
    variant === "error"
      ? "bg-red-500"
      : variant === "end"
        ? "bg-green-500"
        : "bg-blue-400";
  const lineColor = "bg-border/40";
  return (
    <div className="flex gap-2.5">
      {/* Dot + line column */}
      <div
        className="flex flex-col items-center shrink-0"
        style={{ width: 10 }}
      >
        <div className={cn("w-2 h-2 rounded-full shrink-0 mt-1", dotColor)} />
        {next && (
          <div
            className={cn("w-px flex-1 mt-1", lineColor)}
            style={{ minHeight: 20 }}
          />
        )}
      </div>
      {/* Content */}
      <div className="pb-3 min-w-0 flex-1">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-[10px] font-medium text-foreground">
            {label}
          </span>
          {prev && (
            <span className="text-[9px] text-muted-foreground/60 font-mono">
              {fmtGap(prev, iso)}
            </span>
          )}
        </div>
        <p className="text-[9px] font-mono text-muted-foreground mt-0.5">
          {fmtIso(iso)}
        </p>
        <p className="text-[9px] text-muted-foreground/50 mt-0.5">
          {fmtRelative(iso)}
        </p>
      </div>
    </div>
  );
}

// ── TraceTree ─────────────────────────────────────────────────────────────────

export function TraceTree({
  spans,
  totalMs,
  defaultExpanded,
  isLive: propIsLive = false,
  traceStartEpochMs,
  className,
  onViewTask,
  onLoadSpanDetail,
}: TraceTreeProps) {
  const [expanded, setExpanded] = useState<Set<string>>(
    () => new Set(defaultExpanded ?? collectIds(spans, 0)),
  );
  const [hoveredId, setHoveredId] = useState<string | null>(null);
  const [selected, setSelected] = useState<TraceSpan | null>(null);
  const [inspectorTab, setInspectorTab] = useState<"overview" | "details">(
    "overview",
  );
  // cursorX is relative to the LEFT edge of the Gantt area (already minus LEFT_W).
  const [cursorX, setCursorX] = useState<number | null>(null);
  const [ganttW, setGanttW] = useState(0);
  const [search, setSearch] = useState("");
  const [errorsOnly, setErrorsOnly] = useState(false);
  const [showDurations, setShowDurations] = useState(false);
  const [nowMs, setNowMs] = useState(() => Date.now());
  const outerRef = useRef<HTMLDivElement>(null);
  const [spanDetail, setSpanDetail] = useState<{
    input: string | null;
    output: string | null;
  } | null>(null);

  const hasLiveSpan = propIsLive || hasAnyLiveSpan(spans);
  const elapsedMs = traceStartEpochMs ? nowMs - traceStartEpochMs : 0;

  // Tick the live current-time indicator every second.
  useEffect(() => {
    if (!hasLiveSpan) return;
    const id = setInterval(() => setNowMs(Date.now()), 1_000);
    return () => clearInterval(id);
  }, [hasLiveSpan]);

  // Keep ganttW in sync with container size for cursor-time calculation.
  useEffect(() => {
    const el = outerRef.current;
    if (!el) return;
    const obs = new ResizeObserver((entries) => {
      setGanttW(Math.max(0, entries[0].contentRect.width - LEFT_W));
    });
    obs.observe(el);
    return () => obs.disconnect();
  }, []);

  // Reset inspector tab when a different span is selected.
  useEffect(() => {
    setInspectorTab("overview");
  }, [selected?.id]);

  // Lazy-load span detail (input/output) when a span is selected.
  useEffect(() => {
    if (!selected || !onLoadSpanDetail || !selected.taskId) {
      setSpanDetail(null);
      return;
    }
    setSpanDetail(null);
    onLoadSpanDetail(selected.taskId)
      .then(setSpanDetail)
      .catch(() => setSpanDetail(null));
  }, [selected?.taskId]); // eslint-disable-line react-hooks/exhaustive-deps

  // Build the filter ID set from the active search / errorsOnly toggles.
  const activeSearch = search.trim().toLowerCase();
  const filterIds: Set<string> | null =
    !activeSearch && !errorsOnly
      ? null
      : getFilterIds(spans, (s) => {
          if (activeSearch && !s.name.toLowerCase().includes(activeSearch))
            return false;
          if (errorsOnly && !isErrorSpan(s)) return false;
          return true;
        });

  const toggle = useCallback((id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }, []);

  const handleMouseMove = useCallback((e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const x = e.clientX - rect.left - LEFT_W;
    setCursorX(x >= 0 && x <= rect.width - LEFT_W ? x : null);
  }, []);

  const handleMouseLeave = useCallback(() => {
    setCursorX(null);
    setHoveredId(null);
  }, []);

  const flatRows = flattenVisible(spans, expanded, filterIds);

  const rowVirtualizer = useVirtualizer({
    count: flatRows.length,
    getScrollElement: () => outerRef.current,
    estimateSize: () => 36, // h-9 = 36px per row
    overscan: 20,
  });

  const ticks = generateTicks(totalMs);
  const cursorTimeMs =
    cursorX !== null && ganttW > 0
      ? Math.round((cursorX / ganttW) * totalMs)
      : null;

  // Helper: convert ms to % string relative to totalMs.
  const pct = (ms: number) => `${(ms / totalMs) * 100}%`;
  const pctN = (ms: number) => (ms / totalMs) * 100;

  // End-tick color: green for clean traces, red if any root span failed.
  const rootFailed = spans.some(
    (s) =>
      s.state === "FAILED" || s.state === "CRASHED" || s.state === "TIMED_OUT",
  );
  const endTickClass = rootFailed ? "text-red-400" : "text-green-400";

  return (
    <div
      className={cn(
        "flex flex-row rounded-lg border border-border overflow-hidden",
        className,
      )}
    >
      {/* ── Left: trace tree ────────────────────────────────────────────────────── */}
      {/* overflow-y-auto: lets the row grid scroll within the fixed-height
          container for large fan-outs (100+ spans). The sticky time-axis
          header keeps working because sticky is relative to the scroll parent. */}
      <div
        ref={outerRef}
        className="relative bg-slate-950 flex-1 min-w-0 overflow-y-auto"
        onMouseMove={handleMouseMove}
        onMouseLeave={handleMouseLeave}
      >
        {/* ── Toolbar ─────────────────────────────────────────────────────── */}
        <div className="flex items-center gap-3 px-3 py-2 border-b border-border bg-secondary/10">
          {/* Search */}
          <div className="flex items-center gap-1 flex-1 min-w-0">
            <Search size={12} className="text-muted-foreground shrink-0" />
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Filter spans…"
              className="bg-transparent text-xs outline-none placeholder:text-muted-foreground/50 flex-1 min-w-0"
            />
          </div>

          {/* Errors only toggle */}
          <button
            onClick={() => setErrorsOnly((v) => !v)}
            className={cn(
              "text-xs px-2 py-0.5 rounded border transition-colors whitespace-nowrap",
              errorsOnly
                ? "border-red-500/60 text-red-400 bg-red-500/10"
                : "border-border text-muted-foreground",
            )}
          >
            Errors only
          </button>

          {/* Show durations toggle */}
          <button
            onClick={() => setShowDurations((v) => !v)}
            className={cn(
              "text-xs px-2 py-0.5 rounded border transition-colors whitespace-nowrap",
              showDurations
                ? "border-blue-500/60 text-blue-400 bg-blue-500/10"
                : "border-border text-muted-foreground",
            )}
          >
            Durations
          </button>
        </div>

        {/* ── Sticky time-axis header ──────────────────────────────────────── */}
        <div
          className="sticky top-0 z-10 grid border-b border-border"
          style={{
            gridTemplateColumns: `${LEFT_W}px 1fr`,
            background: "rgba(7, 11, 36, 0.97)",
            backdropFilter: "blur(8px)",
          }}
        >
          {/* Left header */}
          <div className="h-7 px-3 flex items-center text-[11px] font-medium text-muted-foreground tracking-widest uppercase border-r border-border/20">
            Span
          </div>

          {/* Right header — tick marks + vertical grid lines */}
          <div className="relative h-7 overflow-hidden">
            {/* Vertical grid lines at each tick */}
            {ticks.slice(1).map((t) => (
              <div
                key={`vg-${t}`}
                className="absolute top-0 bottom-0 border-r border-border/10"
                style={{ left: `${pctN(t)}%` }}
              />
            ))}

            {/* Tick labels + bottom tick marks */}
            {ticks.map((t) => {
              const isEnd = t === ticks[ticks.length - 1];
              return (
                <div
                  key={t}
                  className="absolute top-0 bottom-0 flex flex-col"
                  style={{ left: `${pctN(t)}%` }}
                >
                  <span
                    className={cn(
                      "mt-[5px] ml-[3px] text-[9px] font-mono whitespace-nowrap leading-none select-none",
                      isEnd ? endTickClass : "text-muted-foreground/55",
                    )}
                  >
                    {tickLabel(t)}
                  </span>
                  <div className="mt-auto w-px h-[7px] bg-border/35" />
                </div>
              );
            })}

            {/* Live current-time red line */}
            {hasLiveSpan && traceStartEpochMs && (
              <div
                className="absolute top-0 bottom-0 w-px bg-red-500/70 z-10"
                style={{
                  left: `${Math.min((elapsedMs / totalMs) * 100, 100)}%`,
                }}
              >
                <span className="absolute -top-0.5 left-1 text-[9px] text-red-400 font-mono whitespace-nowrap">
                  {fmtDuration(elapsedMs)}
                </span>
              </div>
            )}
          </div>
        </div>

        {/* ── Row grid — virtualized for large traces ─────────────────── */}
        <div
          style={{
            height: `${rowVirtualizer.getTotalSize()}px`,
            position: "relative",
          }}
        >
          {rowVirtualizer.getVirtualItems().map((virtualRow) => {
            const row = flatRows[virtualRow.index];
            const isHovered = hoveredId === row.id;
            const isSelected = selected?.id === row.id;
            const queuedMs = row.queuedMs ?? 0;
            const execStart = row.startMs + queuedMs;
            const execDuration = Math.max(0, row.durationMs - queuedMs);
            const leftPadPx = row.depth * INDENT + 8;
            const isLog = row.kind === "LOG";
            const endPct = pctN(row.startMs + row.durationMs);
            const labelNearEdge = endPct > 85;

            return (
              <div
                key={row.id}
                style={{
                  position: "absolute",
                  top: 0,
                  left: 0,
                  width: "100%",
                  height: `${virtualRow.size}px`,
                  transform: `translateY(${virtualRow.start}px)`,
                  display: "grid",
                  gridTemplateColumns: `${LEFT_W}px 1fr`,
                }}
              >
                {/* ── Left cell ───────────────────────────────────────────── */}
                <div
                  className={cn(
                    "relative flex items-center h-9 gap-[5px] border-b border-border/20 pr-2 transition-colors duration-75",
                    // Expansion is disabled while a filter is active.
                    row.hasChildren && !filterIds
                      ? "cursor-pointer"
                      : "cursor-default",
                    isSelected
                      ? "bg-white/[0.06]"
                      : isHovered
                        ? "bg-white/[0.04]"
                        : "hover:bg-white/[0.025]",
                  )}
                  style={{ paddingLeft: `${leftPadPx}px` }}
                  onClick={() => {
                    // Toggle expansion only when no filter is active.
                    if (row.hasChildren && !filterIds) toggle(row.id);
                    setSelected(isSelected ? null : row);
                  }}
                  onMouseEnter={() => setHoveredId(row.id)}
                  onMouseLeave={() => setHoveredId(null)}
                >
                  {/* Tree connector lines — one vertical rule per ancestor */}
                  {row.depth > 0 &&
                    Array.from({ length: row.depth }).map((_, i) => (
                      <div
                        key={i}
                        className="absolute top-0 bottom-0"
                        style={{
                          left: `${i * INDENT + 15}px`,
                          width: "1px",
                          background: "rgba(148,163,184,0.10)",
                        }}
                      />
                    ))}

                  {/* Chevron — hidden when filter is active */}
                  <span className="relative shrink-0 w-3.5 h-3.5 flex items-center justify-center">
                    {row.hasChildren && !filterIds ? (
                      row.isExpanded ? (
                        <ChevronDown
                          size={11}
                          className="text-muted-foreground/50"
                        />
                      ) : (
                        <ChevronRight
                          size={11}
                          className="text-muted-foreground/50"
                        />
                      )
                    ) : null}
                  </span>

                  {/* State dot (log-level color for LOG rows) */}
                  <span
                    className={cn(
                      "relative shrink-0 rounded-full w-[6px] h-[6px]",
                      isLog ? logDotClass(row.logLevel) : dotClass(row.state),
                    )}
                  />

                  {/* Span name + attempt badge + optional error message */}
                  <span className="relative flex-1 min-w-0 flex flex-col justify-center overflow-hidden">
                    <span className="flex items-center gap-0.5 overflow-hidden">
                      <span className="font-mono text-[11px] text-foreground/80 truncate leading-none">
                        {row.name}
                      </span>
                      {row.attempt && row.attempt > 1 && (
                        <span className="shrink-0 ml-1 text-[9px] font-mono text-muted-foreground bg-secondary/60 rounded px-1 whitespace-nowrap leading-none">
                          ×{row.attempt}
                          {row.maxAttempts ? `/${row.maxAttempts}` : ""}
                        </span>
                      )}
                    </span>
                    {row.errorMessage && (
                      <span className="text-[9px] text-red-400 truncate leading-tight">
                        {row.errorMessage}
                      </span>
                    )}
                  </span>

                  {/* Kind badge */}
                  {row.kind === "WORKFLOW" && (
                    <span className="relative shrink-0 text-[9px] bg-blue-500/20 text-blue-300 border border-blue-500/25 rounded px-[5px] font-mono py-[2px] leading-none">
                      wf
                    </span>
                  )}
                  {(row.kind === "SLEEP" || row.kind === "WAIT") && (
                    <span className="relative shrink-0 text-[9px] bg-slate-600/30 text-slate-400 border border-slate-500/25 rounded px-[5px] font-mono py-[2px] leading-none">
                      {row.kind === "SLEEP" ? "zzz" : "wait"}
                    </span>
                  )}
                  {row.kind === "LOG" && (
                    <span className="relative shrink-0 text-[9px] bg-slate-700/40 text-slate-400 border border-slate-500/25 rounded px-[5px] font-mono py-[2px] leading-none">
                      {row.logLevel ?? "log"}
                    </span>
                  )}

                  {/* Right-aligned status icon */}
                  <StatusIcon span={row} />
                </div>

                {/* ── Right cell — Gantt bar ───────────────────────────────── */}
                <div
                  className={cn(
                    "relative h-9 border-b border-border/20 border-l border-border/10 overflow-hidden transition-colors duration-75",
                    isSelected
                      ? "bg-white/[0.06]"
                      : isHovered
                        ? "bg-white/[0.04]"
                        : "",
                  )}
                  onMouseEnter={() => setHoveredId(row.id)}
                  onMouseLeave={() => setHoveredId(null)}
                  onClick={() => setSelected(isSelected ? null : row)}
                >
                  {/* Vertical grid lines at each tick */}
                  {ticks.slice(1).map((t) => (
                    <div
                      key={t}
                      className="absolute top-0 bottom-0 w-px bg-white/[0.03]"
                      style={{ left: pct(t) }}
                    />
                  ))}

                  {isLog ? (
                    /* LOG kind: small colored dot instead of a bar */
                    <div
                      className={cn(
                        "absolute top-1/2 -translate-y-1/2 size-2 rounded-full",
                        logDotClass(row.logLevel),
                      )}
                      style={{ left: pct(row.startMs) }}
                    />
                  ) : (
                    <>
                      {/* Queued prefix bar (dashed, shows time-in-queue) */}
                      {queuedMs > 0 && (
                        <div
                          className="absolute top-1/2 -translate-y-1/2 h-5 border border-dashed border-current opacity-30 rounded-sm"
                          style={{
                            left: pct(row.startMs),
                            width: `max(4px, ${pctN(queuedMs)}%)`,
                          }}
                        />
                      )}

                      {/* Execution bar */}
                      <div
                        className={cn(
                          "absolute top-1/2 -translate-y-1/2 h-5 rounded-sm",
                          barClass(row.kind, row.state),
                        )}
                        style={{
                          left: pct(execStart),
                          width: `max(4px, ${pctN(execDuration)}%)`,
                        }}
                      />

                      {/* Duration label — smart positioning avoids right-edge clipping */}
                      <span
                        className={cn(
                          "absolute top-1/2 -translate-y-1/2 text-[10px] font-mono whitespace-nowrap pointer-events-none transition-opacity",
                          labelNearEdge
                            ? "text-foreground/70" // inside bar: lighter text for contrast
                            : "text-muted-foreground ml-1", // outside bar: muted
                          isHovered || showDurations
                            ? "opacity-100"
                            : "opacity-0",
                        )}
                        style={
                          labelNearEdge
                            ? { right: `${100 - endPct + 2}%` } // right-anchored inside the cell
                            : { left: `calc(${endPct}% + 5px)` } // left-anchored outside bar (original)
                        }
                      >
                        {fmtDuration(row.durationMs)}
                      </span>
                    </>
                  )}
                </div>
              </div>
            );
          })}
        </div>

        {/* ── Inspector panel (shown when a row is selected) ───────────────── */}
      </div>

      {/* ── Right: inspector panel ──────────────────────────────────────── */}
      <div
        className={cn(
          "border-l border-border bg-slate-950/90 flex flex-col text-xs transition-all duration-200 overflow-hidden select-text",
          selected ? "w-96 opacity-100" : "w-0 opacity-0",
        )}
      >
        {selected && (
          <>
            {/* ── Panel header ─────────────────────────────────────────── */}
            <div className="px-4 pt-3 pb-2 border-b border-border shrink-0 space-y-2">
              {/* Name + close */}
              <div className="flex items-start justify-between gap-2">
                <p className="font-mono text-[11px] text-foreground leading-snug break-all flex-1">
                  {selected.name}
                </p>
                <button
                  onClick={() => setSelected(null)}
                  className="text-muted-foreground hover:text-foreground transition-colors shrink-0 mt-0.5 text-base leading-none"
                >
                  ✕
                </button>
              </div>

              {/* State badge row */}
              <div className="flex items-center gap-1.5">
                <span
                  className={cn(
                    "w-[7px] h-[7px] rounded-full shrink-0",
                    dotClass(selected.state),
                  )}
                />
                <span className="text-[10px] text-muted-foreground">
                  {selected.state}
                </span>
                <span className="text-[10px] text-muted-foreground/40">·</span>
                <span className="text-[10px] text-muted-foreground font-mono">
                  {selected.kind}
                </span>
              </div>

              {/* Action buttons */}
              {selected.taskId && onViewTask && (
                <div className="flex items-center gap-1.5">
                  <button
                    onClick={() => onViewTask(selected.taskId!)}
                    className="flex items-center gap-1 text-[10px] px-2 py-1 rounded border border-border text-muted-foreground hover:text-foreground hover:border-border/80 transition-colors"
                  >
                    <ExternalLink size={10} /> View task
                  </button>
                </div>
              )}

              {/* Tab bar */}
              <div className="flex gap-0">
                {(["overview", "details"] as const).map((tab) => (
                  <button
                    key={tab}
                    onClick={() => setInspectorTab(tab)}
                    className={cn(
                      "text-[10px] px-3 py-1 capitalize transition-colors border-b-2",
                      inspectorTab === tab
                        ? "text-foreground border-blue-500"
                        : "text-muted-foreground border-transparent hover:text-foreground",
                    )}
                  >
                    {tab}
                  </button>
                ))}
              </div>
            </div>

            {/* ── Overview tab ─────────────────────────────────────────── */}
            {inspectorTab === "overview" && (
              <div className="flex-1 overflow-y-auto p-4 space-y-4">
                {/* Lifecycle timeline */}
                {(selected.createdAt ||
                  selected.startedAt ||
                  selected.completedAt) && (
                  <div className="space-y-0">
                    <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider mb-2">
                      Timeline
                    </p>
                    {selected.createdAt && (
                      <TimelineEvent
                        label="Triggered"
                        iso={selected.createdAt}
                        variant="start"
                        next={selected.startedAt ?? selected.completedAt}
                      />
                    )}
                    {selected.startedAt && (
                      <TimelineEvent
                        label="Claimed"
                        iso={selected.startedAt}
                        prev={selected.createdAt}
                        variant="mid"
                        next={selected.completedAt}
                      />
                    )}
                    {selected.completedAt && (
                      <TimelineEvent
                        label={
                          selected.state === "FAILED" ||
                          selected.state === "CRASHED" ||
                          selected.state === "TIMED_OUT"
                            ? "Failed"
                            : "Finished"
                        }
                        iso={selected.completedAt}
                        prev={selected.startedAt ?? selected.createdAt}
                        variant={
                          selected.state === "FAILED" ||
                          selected.state === "CRASHED"
                            ? "error"
                            : "end"
                        }
                      />
                    )}
                  </div>
                )}

                {/* Input & Output — both fetched lazily via onLoadSpanDetail.
                     isDetailLoading is derived directly from span selection state so
                     the skeleton appears on the very first render after a span is
                     clicked, with no flash of empty content before the effect fires. */}
                {(() => {
                  const isDetailLoading = !!selected && !spanDetail;
                  return (
                    <>
                      {/* Input */}
                      <div className="space-y-1">
                        <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
                          Input
                        </p>
                        {isDetailLoading ? (
                          <JsonSkeleton />
                        ) : spanDetail?.input ? (
                          <pre className="bg-secondary/30 border border-border/40 rounded p-2 text-[10px] font-mono text-foreground/80 overflow-x-auto whitespace-pre-wrap break-all leading-relaxed select-text transition-opacity duration-150">
                            {JSON.stringify(
                              JSON.parse(spanDetail.input),
                              null,
                              2,
                            )}
                          </pre>
                        ) : (
                          <p className="text-[10px] text-muted-foreground/50 italic">
                            —
                          </p>
                        )}
                      </div>

                      {/* Output */}
                      <div className="space-y-1">
                        <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
                          Output
                        </p>
                        {isDetailLoading ? (
                          <JsonSkeleton />
                        ) : spanDetail?.output ? (
                          <pre className="bg-secondary/30 border border-border/40 rounded p-2 text-[10px] font-mono text-foreground/80 overflow-x-auto whitespace-pre-wrap break-all leading-relaxed select-text transition-opacity duration-150">
                            {JSON.stringify(
                              JSON.parse(spanDetail.output),
                              null,
                              2,
                            )}
                          </pre>
                        ) : (
                          <p className="text-[10px] text-muted-foreground/50 italic">
                            —
                          </p>
                        )}
                      </div>
                    </>
                  );
                })()}

                {/* Error */}
                {selected.errorMessage &&
                  (() => {
                    let parsed: {
                      name?: string;
                      message?: string;
                      cause?: { name?: string; message?: string };
                    } | null = null;
                    try {
                      parsed = JSON.parse(selected.errorMessage);
                    } catch {}
                    return (
                      <div className="space-y-1.5">
                        <p className="text-[10px] font-medium text-muted-foreground uppercase tracking-wider">
                          Error
                        </p>
                        {parsed ? (
                          <div className="rounded border border-red-500/20 bg-red-500/5 overflow-hidden">
                            {parsed.name && (
                              <div className="px-2 py-1 border-b border-red-500/20 bg-red-500/10">
                                <span className="text-[10px] font-semibold text-red-400 font-mono">
                                  {parsed.name}
                                </span>
                              </div>
                            )}
                            {parsed.message && (
                              <p className="px-2 py-1.5 text-[10px] text-red-300/80 leading-relaxed">
                                {parsed.message}
                              </p>
                            )}
                            {parsed.cause?.message && (
                              <div className="px-2 py-1 border-t border-red-500/20 bg-red-500/5">
                                <p className="text-[10px] text-red-300/60 leading-relaxed">
                                  <span className="font-medium">Cause: </span>
                                  {parsed.cause.message}
                                </p>
                              </div>
                            )}
                          </div>
                        ) : (
                          <pre className="bg-red-500/10 border border-red-500/20 rounded p-2 text-red-400 font-mono text-[10px] leading-relaxed break-words whitespace-pre-wrap">
                            {selected.errorMessage}
                          </pre>
                        )}
                      </div>
                    );
                  })()}
              </div>
            )}

            {/* ── Details tab ──────────────────────────────────────────── */}
            {inspectorTab === "details" && (
              <div className="flex-1 overflow-y-auto p-4">
                <div className="space-y-1.5">
                  {(
                    [
                      ["Kind", selected.kind],
                      ["State", selected.state],
                      selected.attempt
                        ? [
                            "Attempt",
                            selected.attempt > 1
                              ? `${selected.attempt}${selected.maxAttempts ? `/${selected.maxAttempts}` : ""}`
                              : "1",
                          ]
                        : null,
                      selected.queuedMs
                        ? ["Queue wait", fmtDuration(selected.queuedMs)]
                        : null,
                      ["Offset", fmtDuration(selected.startMs) + " from root"],
                      ["Duration", fmtDuration(selected.durationMs)],
                      selected.logLevel
                        ? ["Log level", selected.logLevel]
                        : null,
                    ] as ([string, string] | null)[]
                  )
                    .filter((x): x is [string, string] => x !== null)
                    .map(([label, value]) => (
                      <div
                        key={label}
                        className="flex items-start justify-between gap-3 py-1.5 border-b border-border/20 last:border-0"
                      >
                        <span className="text-[10px] text-muted-foreground shrink-0 w-20">
                          {label}
                        </span>
                        <span className="text-[10px] font-mono text-foreground/80 text-right break-all">
                          {value}
                        </span>
                      </div>
                    ))}
                  {selected.workerID && (
                    <div className="flex items-start justify-between gap-3 py-1.5 border-b border-border/20 last:border-0">
                      <span className="text-[10px] text-muted-foreground shrink-0 w-20">
                        Worker
                      </span>
                      <div className="flex items-center gap-1 min-w-0">
                        <span className="text-[10px] font-mono text-foreground/80 text-right break-all flex-1">
                          {selected.workerID}
                        </span>
                        <button
                          onClick={() =>
                            navigator.clipboard.writeText(selected.workerID!)
                          }
                          className="shrink-0 text-muted-foreground hover:text-foreground transition-colors"
                          title="Copy worker ID"
                        >
                          <Copy size={10} />
                        </button>
                      </div>
                    </div>
                  )}
                  {selected.taskId && (
                    <div className="flex items-start justify-between gap-3 py-1.5 border-b border-border/20 last:border-0">
                      <span className="text-[10px] text-muted-foreground shrink-0 w-20">
                        Task ID
                      </span>
                      <div className="flex items-center gap-1 min-w-0">
                        <span className="text-[10px] font-mono text-foreground/80 text-right break-all flex-1">
                          {selected.taskId}
                        </span>
                        <button
                          onClick={() =>
                            navigator.clipboard.writeText(selected.taskId!)
                          }
                          className="shrink-0 text-muted-foreground hover:text-foreground transition-colors"
                          title="Copy task ID"
                        >
                          <Copy size={10} />
                        </button>
                      </div>
                    </div>
                  )}
                </div>
              </div>
            )}
          </>
        )}
        {/* ── Hover cursor line + floating time label ──────────────────── */}
        {cursorX !== null && (
          <>
            {/* Cursor line — starts below toolbar + time-axis header */}
            <div
              className="absolute bottom-0 pointer-events-none z-20"
              style={{
                top: `${TOOLBAR_H + HEADER_H}px`,
                left: `${LEFT_W + cursorX}px`,
                width: "1px",
                background: "rgba(96,165,250,0.40)",
              }}
            />

            {/* Floating time tooltip pinned just below the header */}
            {cursorTimeMs !== null && (
              <div
                className="absolute pointer-events-none z-30"
                style={{
                  top: `${TOOLBAR_H + HEADER_H + 6}px`,
                  left: `${LEFT_W + cursorX}px`,
                  transform: "translateX(-50%)",
                }}
              >
                <div className="bg-slate-800/95 border border-slate-600/50 text-blue-300 text-[9px] font-mono px-1.5 py-[3px] rounded shadow-lg whitespace-nowrap">
                  {fmtCursorTime(cursorTimeMs)}
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
