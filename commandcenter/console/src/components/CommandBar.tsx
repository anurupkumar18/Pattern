export interface StagedCommand {
  utterance: string;
  preview: string | null;
  targetName: string | null;
  holdMs: number;
  /** Animation restart key. */
  key: number;
}

interface CommandBarProps {
  staged: StagedCommand | null;
  onCancel: () => void;
  onSendNow: () => void;
}

export function CommandBar({
  staged,
  onCancel,
  onSendNow,
}: CommandBarProps) {
  if (!staged) return null;
  const targetLabel = staged.preview ? "Command" : staged.targetName ?? "Command";
  return (
    <div className="command-bar" role="status" aria-live="polite">
      <span className="target-chip" key={targetLabel}>
        {staged.preview ? staged.preview : `To: ${targetLabel}`}
      </span>
      <span className="bar-text">
        <span className="bar-staged">{staged.utterance}</span>
      </span>
      {staged.holdMs > 0 && (
        <span
          key={staged.key}
          className="hold-track"
          style={{ animationDuration: `${staged.holdMs}ms` }}
          aria-hidden
        />
      )}
      <span className="bar-controls">
        <button type="button" className="quiet" onClick={onCancel}>
          Esc Cancel
        </button>
        <button type="button" className="bar-send" onClick={onSendNow}>
          Send now
        </button>
      </span>
    </div>
  );
}
