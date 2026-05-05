/// <reference types="vite/client" />
import axios from "axios";

export const api = axios.create({
  baseURL:
    (import.meta as unknown as { env: Record<string, string> }).env[
      "VITE_API_URL"
    ] ?? "",
  headers: { "Content-Type": "application/json" },
});

api.interceptors.response.use(
  (r) => r,
  (err) => {
    const message =
      err.response?.data?.error?.message ??
      err.response?.data?.message ??
      err.message;
    return Promise.reject(new Error(message));
  },
);
