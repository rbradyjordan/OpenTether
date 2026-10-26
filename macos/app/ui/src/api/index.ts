import type { Backend } from "./backend";
import { createMockBackend } from "./mock";
import { createTauriBackend } from "./tauri";

export * from "./types";
export type { Backend, EventMap, EventName, ImageVariant, ImageOptions } from "./backend";

/** True inside the Tauri webview. */
export const inTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

/** The one backend the UI talks to: Tauri when available, otherwise the in-browser mock. */
export const api: Backend = inTauri ? createTauriBackend() : createMockBackend();

/** Mock-only: simulates the camera dropping off, to exercise the reconnect sheet. */
export function simulateDisconnect(): void {
  (api as Backend & { simulateDisconnect?: () => void }).simulateDisconnect?.();
}

export function errorMessage(e: unknown): string {
  if (e instanceof Error) return e.message;
  if (e && typeof e === "object" && "message" in e) return String((e as { message: unknown }).message);
  return String(e);
}
