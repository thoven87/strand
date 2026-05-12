import { useState, useEffect } from "react";

/** Theme stored in localStorage. Absent = follow system preference. */
type StoredTheme = "dark" | "light";

export function getIsDark(): boolean {
    return document.documentElement.classList.contains("dark");
}

export function toggleTheme(): boolean {
    const nowDark = !getIsDark();
    document.documentElement.classList.toggle("dark", nowDark);
    localStorage.setItem("strand-theme", nowDark ? "dark" : "light");
    return nowDark;
}

/** Call once at app startup — reads localStorage, then falls back to system preference. */
export function initTheme() {
    const stored = localStorage.getItem("strand-theme") as StoredTheme | null;
    if (stored === "dark" || stored === "light") {
        document.documentElement.classList.toggle("dark", stored === "dark");
    } else {
        const mq = window.matchMedia("(prefers-color-scheme: dark)");
        document.documentElement.classList.toggle("dark", mq.matches);
        mq.addEventListener("change", (e) =>
            document.documentElement.classList.toggle("dark", e.matches),
        );
    }
}

/**
 * React hook that returns `true` when the page is in dark mode.
 * Reacts to theme toggles by watching for `.dark` class changes on `<html>`.
 */
export function useIsDark(): boolean {
    const [isDark, setIsDark] = useState(getIsDark);
    useEffect(() => {
        const obs = new MutationObserver(() => setIsDark(getIsDark()));
        obs.observe(document.documentElement, {
            attributes: true,
            attributeFilter: ["class"],
        });
        return () => obs.disconnect();
    }, []);
    return isDark;
}
