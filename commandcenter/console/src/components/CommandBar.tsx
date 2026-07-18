import { Waveform } from "./icons.js";

export interface StagedCommand {
  utterance: string;
  preview: string | null;
  targetName: string | null;
  holdMs: number;
  /** Animation restart key. */
  key: number;
}

interface CommandBarProps {
  /** Live interim transcription while capturing. */
  interim: string;
  staged: StagedCommand | null;
  focusedName: string | null;
  onCancel: () => void;
  onSendNow: () => void;
}

/**
 * The global command bar (spec §8 option A): one visible voice locus above
 * the composer. Streams interim words, then shows the parsed preview during
 * the staged parse-before-act beat.
 */
export function CommandBar({
  interim,
  staged,
  focusedName,
  onCancel,
  onSendNow,
}: CommandBarProps) {
  if (!interim && !staged) return null;
  const targetLabel = staged?.preview
    ? "Command"
    : staged?.targetName ?? focusedName ?? "Command";
  return (
    <div className="command-bar" role="status" aria-live="polite">
      <span className="target-chip" key={targetLabel}>
        {staged?.preview ? staged.preview : `To: ${targetLabel}`}
      </span>
      <span className="bar-text">
        {staged ? (
          <span className="bar-staged">{staged.utterance}</span>
        ) : (
          <span className="bar-interim">{interim}</span>
        )}
      </span>
      {staged && staged.holdMs > 0 && (
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
        <Waveform />
        {staged && (
          <button type="button" className="bar-send" onClick={onSendNow}>
            Send now
          </button>
        )}
      </span>
    </div>
  );
}
