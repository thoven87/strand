import type { Config } from "tailwindcss";

// Theme configuration has moved to src/index.css (@theme inline).
// This file is kept only for explicit content path declaration.
export default {
    content: ["./index.html", "./src/**/*.{ts,tsx}"],
} satisfies Config;
