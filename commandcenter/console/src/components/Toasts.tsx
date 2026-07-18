import { useEffect } from "react";

import { SourceGlyph } from "./icons.js";
import type { RowSource } from "../model.js";

export interface Toast {
  id: string;
  source: RowSource | null;
  title: string;
  body: string;
  kind: "finished" | "needs-input" | "failed";
  onOpen?: () => void;
}

interface ToastsProps {
  toasts: Toast[];
  onDismiss: (id: string) => void;
}

export function ToastViewport({ toasts, onDismiss }: ToastsProps) {
  return (
    <div className="toast-viewport">
      {toasts.slice(0, 1).map((toast) => (
        <ToastCard key={toast.id} toast={toast} onDismiss={onDismiss} />
      ))}
    </div>
  );
}

function ToastCard({
  toast,
  onDismiss,
}: {
  toast: Toast;
  onDismiss: (id: string) => void;
}) {
  useEffect(() => {
    const ttl = toast.kind === "needs-input" ? 10_000 : 5_000;
    const timer = window.setTimeout(() => onDismiss(toast.id), ttl);
    return () => window.clearTimeout(timer);
  }, [toast.id, toast.kind, onDismiss]);

  return (
    <div className="toast" role="status">
      <div className="toast-head">
        {toast.source && <SourceGlyph source={toast.source} />}
        <span className="toast-title">{toast.title}</span>
      </div>
      <div className="toast-body">
        <span
          className={
            toast.kind === "failed" ? "toast-kind danger" : "toast-kind"
          }
        >
          {toast.kind === "finished"
            ? "Finished"
            : toast.kind === "needs-input"
              ? "Needs input"
              : "Failed"}
        </span>
        <span className="toast-text">{toast.body}</span>
        {toast.onOpen && (
          <button type="button" className="quiet" onClick={toast.onOpen}>
            Open
          </button>
        )}
      </div>
    </div>
  );
}
