import { formatDistanceToNow, parseISO, format } from "date-fns";
import { useTimeFormat, toggleTimeFormat } from "@/lib/timeFormat";

interface Props {
  iso: string | null;
  fallback?: string;
}

/**
 * Renders a timestamp as relative ("3 minutes ago") or absolute
 * ("2026-05-04 20:36:05") depending on the global time-format preference.
 * Clicking any instance toggles the format for all instances simultaneously.
 */
export function RelativeTime({ iso, fallback = "—" }: Props) {
  const fmt = useTimeFormat();

  if (!iso)
    return <span className="text-muted-foreground">{fallback}</span>;

  const date = parseISO(iso);
  const relative = formatDistanceToNow(date, { addSuffix: true });
  const absolute = format(date, "yyyy-MM-dd HH:mm:ss");

  const label = fmt === "relative" ? relative : absolute;
  const title = fmt === "relative" ? absolute : relative;

  return (
    <time
      dateTime={iso}
      title={`${title} — click to toggle`}
      onClick={(e) => {
        e.stopPropagation();
        toggleTimeFormat();
      }}
      className="text-muted-foreground text-xs cursor-pointer hover:text-foreground transition-colors select-none"
    >
      {label}
    </time>
  );
}
