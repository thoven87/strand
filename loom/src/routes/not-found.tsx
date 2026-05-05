import { Link } from "@tanstack/react-router";
import { getStoredNamespace } from "@/lib/namespace";

export function NotFound() {
  const ns = getStoredNamespace();
  return (
    <div className="flex flex-col items-center justify-center h-64 gap-3">
      <p className="text-3xl font-semibold text-muted-foreground">404</p>
      <p className="text-sm text-muted-foreground">Page not found.</p>
      <Link
        to={`/${ns}/tasks` as never}
        className="text-xs text-brand hover:underline"
      >
        Back to Tasks
      </Link>
    </div>
  );
}
