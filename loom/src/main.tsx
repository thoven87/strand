import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { router } from "./router";
import "./index.css";

const queryClient = new QueryClient({
    defaultOptions: {
        queries: { staleTime: 3_000, retry: 1 },
    },
});

declare module "@tanstack/react-router" {
    interface Register {
        router: typeof router;
    }
}

// Apply theme from system preference; keeps in sync with OS changes.
const mq = window.matchMedia("(prefers-color-scheme: dark)");
document.documentElement.classList.toggle("dark", mq.matches);
mq.addEventListener("change", (e) =>
  document.documentElement.classList.toggle("dark", e.matches),
);

createRoot(document.getElementById("root")!).render(
    <StrictMode>
        <QueryClientProvider client={queryClient}>
            <RouterProvider router={router} />
        </QueryClientProvider>
    </StrictMode>,
);
