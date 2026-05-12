import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { RouterProvider } from "@tanstack/react-router";
import { router } from "./router";
import { initTheme } from "./lib/theme";
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

initTheme();

createRoot(document.getElementById("root")!).render(
    <StrictMode>
        <QueryClientProvider client={queryClient}>
            <RouterProvider router={router} />
        </QueryClientProvider>
    </StrictMode>,
);
