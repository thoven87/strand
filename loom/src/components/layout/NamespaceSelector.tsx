import { useState, useRef, useEffect } from "react";
import { useQuery } from "@tanstack/react-query";
import { useNavigate, useParams } from "@tanstack/react-router";
import { Database, ChevronDown, Check } from "lucide-react";
import { listNamespaces } from "@/api/namespaces";
import { getStoredNamespace, setStoredNamespace } from "@/lib/namespace";
import { qk } from "@/lib/queryKeys";
import { cn } from "@/lib/utils";

interface NamespaceSelectorProps {
  collapsed: boolean;
}

export function NamespaceSelector({ collapsed }: NamespaceSelectorProps) {
  const [open, setOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const navigate = useNavigate();

  // Read current namespace from URL; fall back to stored value on non-namespace routes
  const { namespace: urlNamespace } = useParams({ strict: false }) as {
    namespace?: string;
  };
  const current = urlNamespace ?? getStoredNamespace();

  const { data: namespaces = [] } = useQuery({
    queryKey: qk.namespaces.list(),
    queryFn: listNamespaces,
    staleTime: 60_000,
  });

  // Close dropdown on outside click
  useEffect(() => {
    if (!open) return;
    function onMouseDown(e: MouseEvent) {
      if (
        containerRef.current &&
        !containerRef.current.contains(e.target as Node)
      ) {
        setOpen(false);
      }
    }
    document.addEventListener("mousedown", onMouseDown);
    return () => document.removeEventListener("mousedown", onMouseDown);
  }, [open]);

  function select(id: string) {
    if (id === current) {
      setOpen(false);
      return;
    }
    setStoredNamespace(id);
    // Always land on Tasks — the previous page's data belongs to the old
    // namespace and would be stale or confusing in the new context.
    void navigate({
      to: "/$namespace/tasks",
      params: { namespace: id },
    });
    setOpen(false);
  }

  return (
    <div ref={containerRef} className="relative border-b border-border">
      <button
        onClick={() => setOpen((o) => !o)}
        title={`Namespace: ${current}`}
        className={cn(
          "flex items-center gap-2 w-full px-3 py-2 text-xs text-muted-foreground hover:text-foreground hover:bg-slate-800/50 transition-colors",
          collapsed && "justify-center px-2",
        )}
      >
        <Database size={13} className="shrink-0 text-brand/70" />
        {!collapsed && (
          <>
            <span className="flex-1 text-left truncate font-mono text-[11px]">
              {current}
            </span>
            <ChevronDown
              size={11}
              className={cn(
                "shrink-0 transition-transform duration-150",
                open && "rotate-180",
              )}
            />
          </>
        )}
      </button>

      {open && (
        <div
          className={cn(
            "absolute z-50 bg-slate-900 border border-border rounded-md shadow-xl py-1 min-w-[160px]",
            collapsed ? "left-full ml-2 top-0" : "left-2 right-2 top-full mt-1",
          )}
        >
          <p className="px-3 py-1 text-[10px] uppercase tracking-widest font-medium text-muted-foreground/60 select-none">
            Namespace
          </p>
          {namespaces.length === 0 && (
            <p className="px-3 py-2 text-xs text-muted-foreground">Loading…</p>
          )}
          {namespaces.map((ns) => (
            <button
              key={ns.id}
              onClick={() => select(ns.id)}
              className="flex items-center gap-2 w-full px-3 py-1.5 text-left hover:bg-slate-800 transition-colors"
            >
              <span className="flex-1 font-mono text-xs text-foreground truncate">
                {ns.displayName ?? ns.id}
              </span>
              {ns.id === current && (
                <Check size={11} className="text-brand shrink-0" />
              )}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
