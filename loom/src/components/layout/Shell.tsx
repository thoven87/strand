import { Link, useLocation, useParams } from "@tanstack/react-router";
import {
  ListChecks,
  CalendarClock,
  LayoutGrid,
  ChevronLeft,
  ChevronRight,
  Activity,
  Server,
  Workflow,
  BarChart2,
} from "lucide-react";
import { StrandLogo, StrandMark } from "@/components/StrandLogo";
import { useKeyboardNav } from "@/lib/useKeyboardNav";
import { cn } from "@/lib/utils";
import { useState, type ReactNode } from "react";
import { NamespaceSelector } from "./NamespaceSelector";
import { getStoredNamespace } from "@/lib/namespace";

// ── Nav structure ──────────────────────────────────────────────────────────

interface NavItem {
  subPath: string; // relative path without namespace prefix, e.g. "/tasks"
  icon: ReactNode;
  label: string;
  exact?: boolean;
}

interface NavSection {
  title: string;
  items: NavItem[];
}

// Sub-paths only (namespace will be prepended at render time)
const SECTIONS: NavSection[] = [
  {
    title: "Activity",
    items: [
      { subPath: "/tasks", icon: <ListChecks size={15} />, label: "Tasks" },
      { subPath: "/events", icon: <Activity size={15} />, label: "Events" },
      { subPath: "/metrics", icon: <BarChart2 size={15} />, label: "Metrics" },
    ],
  },
  {
    title: "Triggers",
    items: [
      {
        subPath: "/schedules",
        icon: <CalendarClock size={15} />,
        label: "Schedules",
      },
    ],
  },
  {
    title: "Resources",
    items: [
      {
        subPath: "/workflows",
        icon: <Workflow size={15} />,
        label: "Workflows",
      },
      { subPath: "/workers", icon: <Server size={15} />, label: "Workers" },
      {
        subPath: "/queues",
        icon: <LayoutGrid size={15} />,
        label: "Queues",
      },
    ],
  },
];

// ── Nav link ───────────────────────────────────────────────────────────────

function NavLink({
  to,
  subPath,
  icon,
  label,
  collapsed,
  exact,
}: {
  to: string;
  subPath: string;
  icon: ReactNode;
  label: string;
  collapsed: boolean;
  exact?: boolean;
}) {
  const location = useLocation();
  // Active when the pathname ends with the subPath (or an extension of it)
  const active = exact
    ? location.pathname === to
    : location.pathname.includes(subPath);

  return (
    <Link
      to={to as never}
      title={collapsed ? label : undefined}
      className={cn(
        "flex items-center gap-2.5 rounded-md px-2.5 py-1.5 text-sm transition-colors",
        collapsed && "justify-center px-2",
        active
          ? "bg-slate-800 text-foreground"
          : "text-muted-foreground hover:bg-slate-800/60 hover:text-foreground",
      )}
    >
      <span className="shrink-0">{icon}</span>
      {!collapsed && <span className="font-medium">{label}</span>}
    </Link>
  );
}

// ── Shell ──────────────────────────────────────────────────────────────────

export function Shell({ children }: { children: ReactNode }) {
  useKeyboardNav();
  const [collapsed, setCollapsed] = useState(false);

  // Read namespace from URL; fall back to stored namespace when on a
  // non-namespace route (e.g. the root "/" redirect hasn't fired yet).
  const { namespace = getStoredNamespace() } = useParams({
    strict: false,
  }) as { namespace?: string };

  return (
    <div className="flex h-full w-full overflow-hidden">
      {/* Sidebar */}
      <aside
        className={cn(
          "flex flex-col shrink-0 border-r border-border bg-slate-950 transition-[width] duration-200 ease-in-out overflow-hidden",
          collapsed ? "w-[52px]" : "w-52",
        )}
      >
        {/* Logo */}
        <div
          className={cn(
            "flex items-center border-b border-border h-[52px] px-3 shrink-0",
            collapsed && "justify-center px-2",
          )}
        >
          {collapsed ? (
            <StrandMark size={18} className="text-brand" />
          ) : (
            <StrandLogo size={18} className="text-brand" />
          )}
        </div>

        {/* Namespace selector */}
        <NamespaceSelector collapsed={collapsed} />

        {/* Sections */}
        <nav className="flex-1 overflow-y-auto py-3 px-2 space-y-4 [scrollbar-gutter:stable]">
          {SECTIONS.map((section, i) => (
            <div key={section.title}>
              {!collapsed ? (
                <p className="px-2.5 mb-1 font-mono tracking-widest uppercase text-xs text-muted-foreground select-none">
                  {section.title}
                </p>
              ) : (
                i > 0 && <div className="my-2 h-px bg-slate-800 mx-1" />
              )}
              <div className="space-y-0.5">
                {section.items.map((item) => {
                  const to = `/${namespace}${item.subPath}`;
                  return (
                    <NavLink
                      key={item.subPath}
                      to={to}
                      subPath={item.subPath}
                      icon={item.icon}
                      label={item.label}
                      collapsed={collapsed}
                      exact={item.exact}
                    />
                  );
                })}
              </div>
            </div>
          ))}
        </nav>

        {/* Collapse toggle */}
        <button
          onClick={() => setCollapsed((c) => !c)}
          className={cn(
            "flex items-center gap-2 border-t border-border px-3 py-2.5 text-xs text-muted-foreground hover:text-foreground transition-colors shrink-0",
            collapsed && "justify-center px-2",
          )}
        >
          {collapsed ? (
            <ChevronRight size={14} />
          ) : (
            <>
              <ChevronLeft size={14} />
              <span>Collapse</span>
              <span className="ml-auto text-[10px] font-mono text-muted-foreground/40">g+…</span>
            </>
          )}
        </button>
      </aside>

      {/* Main */}
      <main className="flex-1 overflow-y-auto bg-[#050A23] [scrollbar-gutter:stable]">
        {children}
      </main>
    </div>
  );
}
