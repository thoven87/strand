import { useState } from "react";
import { ChevronDown, ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  value: string | null;
  label?: string;
  className?: string;
}

export function JsonView({ value, label, className }: Props) {
  const [open, setOpen] = useState(true);

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
    /* not JSON */
  }

  return (
    <div className={cn(className)}>
      {label && (
        <button
          onClick={() => setOpen((o) => !o)}
          className="flex items-center gap-1 text-xs font-medium text-muted-foreground hover:text-foreground mb-1 transition-colors"
        >
          {open ? <ChevronDown size={12} /> : <ChevronRight size={12} />}
          {label}
        </button>
      )}
      {open && (
        <pre className="rounded-md bg-slate-950/80 border border-border/40 px-3.5 py-2.5 text-xs overflow-auto max-h-80 font-mono leading-relaxed text-slate-300">
          {pretty}
        </pre>
      )}
    </div>
  );
}
