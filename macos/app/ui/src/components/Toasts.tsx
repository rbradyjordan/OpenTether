import { useEffect } from "react";
import { useApp } from "../state/store";
import { Icon } from "./Icon";
import type { ToastMessage } from "../api";

function ToastView({ t }: { t: ToastMessage }) {
  const dismiss = useApp((s) => s.dismissToast);
  useEffect(() => {
    const timer = window.setTimeout(() => dismiss(t.id), t.action ? 5000 : 3200);
    return () => clearTimeout(timer);
  }, [t.id, t.action, dismiss]);
  return (
    <div className="toast glass" role="status">
      <Icon name={t.symbol} size={15} className="c-accent" />
      <span className="truncate">{t.text}</span>
      {t.action ? (
        <button
          className="btn plain small"
          onClick={() => {
            if (t.action?.command === "shoot.showNewest") useApp.getState().showNewest();
            dismiss(t.id);
          }}
        >
          {t.action.title}
        </button>
      ) : null}
    </div>
  );
}

export function ToastHost() {
  const toasts = useApp((s) => s.toasts);
  return (
    <div className="toast-host" aria-live="polite">
      {toasts.map((t) => (
        <ToastView key={t.id} t={t} />
      ))}
    </div>
  );
}
