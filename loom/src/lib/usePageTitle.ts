import { useEffect } from "react";

/**
 * Sets `document.title` to `"${title} — Loom"` while the component is mounted
 * and restores the previous title on unmount.
 */
export function usePageTitle(title: string) {
  useEffect(() => {
    const prev = document.title;
    document.title = `${title} — Loom`;
    return () => {
      document.title = prev;
    };
  }, [title]);
}
