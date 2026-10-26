import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Backend, Commands, EventMap, EventName, ImageOptions, ImageVariant, Unlisten } from "./backend";
import type { CaptureItem, IpcError, LiveViewFrame } from "./types";

/** `sessionsList` → `sessions_list`. */
export function commandName(method: string): string {
  return method.replace(/[A-Z]/g, (c) => "_" + c.toLowerCase());
}

/** Thrown for every rejected command; `code` comes from the Rust `IpcError`. */
export class BackendError extends Error {
  code: string;
  constructor(e: IpcError) {
    super(e.message);
    this.code = e.code;
  }
}

function toError(raw: unknown): BackendError {
  if (raw && typeof raw === "object" && "code" in raw && "message" in raw) {
    return new BackendError(raw as IpcError);
  }
  return new BackendError({ code: "internal", message: typeof raw === "string" ? raw : String(raw) });
}

/** Origin of the custom `tether` URI scheme (macOS/Linux use scheme://localhost, Windows http://scheme.localhost). */
export function schemeOrigin(): string {
  return /Windows/i.test(navigator.userAgent) ? "http://tether.localhost" : "tether://localhost";
}

export function captureImageUrl(capture: Pick<CaptureItem, "id" | "revision">, variant: ImageVariant, opts?: ImageOptions): string {
  const params = new URLSearchParams();
  params.set("rev", String(opts?.revision ?? capture.revision ?? 0));
  if (opts?.look?.lookId && variant !== "original") {
    params.set("look", opts.look.lookId);
    params.set("strength", opts.look.strength.toFixed(2));
  }
  return `${schemeOrigin()}/capture/${encodeURIComponent(capture.id)}/${variant}?${params.toString()}`;
}

export function createTauriBackend(): Backend {
  function on<E extends EventName>(event: E, handler: (payload: EventMap[E]) => void): Unlisten {
    let un: (() => void) | null = null;
    let cancelled = false;
    listen<EventMap[E]>(event, (e) => {
      let payload = e.payload;
      if (event === "liveview:frame") {
        // Rust sends { sequence, width, height }; the JPEG is served by the URI scheme.
        const f = payload as unknown as Omit<LiveViewFrame, "url">;
        payload = { ...f, url: `${schemeOrigin()}/liveview/${f.sequence}.jpg` } as unknown as EventMap[E];
      }
      handler(payload);
    }).then((fn) => {
      if (cancelled) fn();
      else un = fn;
    });
    return () => {
      cancelled = true;
      un?.();
    };
  }

  const base = {
    kind: "tauri" as const,
    on,
    imageUrl: captureImageUrl,
  };

  return new Proxy(base, {
    get(target, prop, receiver) {
      // `then` must stay undefined or the backend would look like a promise.
      if (typeof prop === "string" && prop !== "then" && prop !== "toJSON" && !(prop in target)) {
        return (args?: Record<string, unknown>) =>
          invoke(commandName(prop), args ?? {}).catch((e: unknown) => {
            throw toError(e);
          });
      }
      return Reflect.get(target, prop, receiver);
    },
  }) as unknown as Backend & Commands;
}
