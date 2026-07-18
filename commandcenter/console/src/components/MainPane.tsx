import { useState, type FormEvent } from "react";

import type { CommandOutcome, FleetSnapshot } from "../../../src/contracts.js";
import { relativeTime, type HistoryRow } from "../model.js";
import {
  ArrowUpIcon,
  MicIcon,
  SourceGlyph,
  StopIcon,
  WorkingSpinner,
} from "./icons.js";

interface MainPaneProps {
  selected: HistoryRow | null;
  connection: "connecting" | "open" | "closed";
  outcomes: CommandOutcome[];
  snapshot: FleetSnapshot | null;
  pending: CommandOutcome | null;
  listening: boolean;
  onConfirm: (outcomeId: string) => void;
  onCancelPending: () => void;
  onComposerSubmit: (text: string) => void;
  onInterrupt: (row: HistoryRow) => void;
  onToggleVoice: () => void;
  composerRef: React.RefObject<HTMLTextAreaElement | null>;
}

export function MainPane({
  selected,
  connection,
  outcomes,
  snapshot,
  pending,
  listening,
  onConfirm,
  onCancelPending,
  onComposerSubmit,
  onInterrupt,
  onToggleVoice,
  composerRef,
}: MainPaneProps) {
  const [draft, setDraft] = useState("");

  function submit(event: FormEvent) {
    event.preventDefault();
    const text = draft.trim();
    if (!text) return;
    onComposerSubmit(text);
    setDraft("");
  }

  return (
    <div className="main-content">
      {connection !== "open" && (
        <div className="reconnect-banner" role="status">
          Reconnecting… Commands are paused.
        </div>
      )}

      {selected ? (
        <>
          <div className="conversation-meta">
            {selected.working && (
              <button
                type="button"
                className="interrupt-button"
                title="Interrupt this chat"
                onClick={() => onInterrupt(selected)}
              >
                <StopIcon />
                Interrupt
              </button>
            )}
          </div>
          <ActivityStream
            outcomes={outcomes}
            snapshot={snapshot}
            selected={selected}
          />
        </>
      ) : (
        <EmptyState listening={listening} onToggleVoice={onToggleVoice} />
      )}

      {pending && (
        <div className="confirm-card" role="alertdialog" aria-label="Confirm">
          <div className="confirm-copy">
            <span className="confirm-title">
              {pending.command.verb === "interrupt" ? "Interrupt" : "Confirm"}{" "}
              {targetName(pending.command.resolvedTargetId, snapshot) ?? ""}
            </span>
            <span className="confirm-sub">“{pending.command.rawUtterance}”</span>
          </div>
          <div className="confirm-actions">
            <button type="button" className="quiet" onClick={onCancelPending}>
              Cancel
            </button>
            <button
              type="button"
              className="danger"
              onClick={() => onConfirm(pending.id)}
            >
              {pending.command.verb === "interrupt" ? "Interrupt" : "Confirm"}
            </button>
          </div>
        </div>
      )}

      <form className="composer" onSubmit={submit}>
        <textarea
          ref={composerRef}
          value={draft}
          rows={1}
          placeholder={
            selected
              ? `Message ${selected.title}…`
              : "Type a command, or say the word…"
          }
          onChange={(event) => setDraft(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && !event.shiftKey) {
              event.preventDefault();
              submit(event);
            }
          }}
          spellCheck={false}
        />
        <div className="composer-row">
          <span className="composer-context">
            {selected ? selected.title : "Command"}
          </span>
          <span className="composer-actions">
            <button
              type="button"
              className={listening ? "icon-button mic on" : "icon-button mic"}
              aria-label="Toggle voice"
              onClick={onToggleVoice}
            >
              <MicIcon size={14} />
            </button>
            <button
              type="submit"
              className={draft.trim() ? "send-button ready" : "send-button"}
              aria-label="Send"
              disabled={!draft.trim()}
            >
              <ArrowUpIcon />
            </button>
          </span>
        </div>
      </form>
    </div>
  );
}

function EmptyState({
  listening,
  onToggleVoice,
}: {
  listening: boolean;
  onToggleVoice: () => void;
}) {
  return (
    <div className="empty-state">
      <span className="empty-wordmark">Dictator</span>
      <span className="empty-tagline">Your word is their command.</span>
      <span className="empty-cta">say the word.</span>
      <button
        type="button"
        className={listening ? "voice-pill on large" : "voice-pill large"}
        onClick={onToggleVoice}
      >
        <MicIcon />
        <span>{listening ? "Listening" : "Turn on voice"}</span>
      </button>
    </div>
  );
}

/**
 * Chat transcripts are a protocol gap (no chat.messages event yet), so the
 * detail view shows the command activity ledger for now.
 */
function ActivityStream({
  outcomes,
  snapshot,
  selected,
}: {
  outcomes: CommandOutcome[];
  snapshot: FleetSnapshot | null;
  selected: HistoryRow;
}) {
  const relevantOutcomes = outcomes.filter(
    (outcome) => outcome.command.resolvedTargetId === selected.id,
  );
  return (
    <div className="stream" aria-live="polite">
      <div className="stream-column">
        <div className="stream-context">
          <SourceGlyph source={selected.source} />
          <span>{selected.title}</span>
          {selected.working && (
            <span className="stream-working">
              <WorkingSpinner /> Working
            </span>
          )}
        </div>
        {relevantOutcomes.length === 0 ? (
          <div className="detail-empty">
            <span className="detail-kicker">Conversation detail</span>
            <h2>Message history stays in {sourceName(selected.source)}</h2>
            <p>
              Dictator can focus and direct this chat. Open{" "}
              {sourceName(selected.source)} to read the full conversation.
            </p>
          </div>
        ) : (
          relevantOutcomes
            .slice()
            .reverse()
            .map((outcome) => (
              <OutcomeEvent
                key={outcome.id}
                outcome={outcome}
                snapshot={snapshot}
              />
            ))
        )}
      </div>
    </div>
  );
}

function sourceName(source: HistoryRow["source"]): string {
  switch (source) {
    case "cursor":
      return "Cursor";
    case "claude":
      return "Claude Code";
    case "codex":
      return "Codex";
    case "gemini":
      return "Gemini";
    case "shell":
      return "the shell";
    default:
      return "the source app";
  }
}

function OutcomeEvent({
  outcome,
  snapshot,
}: {
  outcome: CommandOutcome;
  snapshot: FleetSnapshot | null;
}) {
  const [open, setOpen] = useState(false);
  const target = targetName(outcome.command.resolvedTargetId, snapshot);
  const verification = outcome.verification[0];
  return (
    <div className="event">
      <button
        type="button"
        className="event-summary"
        onClick={() => setOpen((value) => !value)}
      >
        <span className="event-caret">{open ? "▾" : "▸"}</span>
        <span className="event-label">
          {describeOutcome(outcome, target)}
        </span>
        <span className="event-state">{stateLabel(outcome)}</span>
        <span className="event-time">
          {relativeTime(Date.parse(outcome.createdAt))}
        </span>
      </button>
      {open && (
        <div className="event-detail">
          <p className="event-quote">“{outcome.command.rawUtterance}”</p>
          {outcome.executor && <p>{outcome.executor.evidence}</p>}
          {verification && (
            <p className={verification.passed ? "verified" : "unverified"}>
              {verification.passed ? "Verified: " : "Not verified: "}
              {verification.evidence}
            </p>
          )}
        </div>
      )}
    </div>
  );
}

function describeOutcome(
  outcome: CommandOutcome,
  target: string | null,
): string {
  const suffix = target ? ` ${target}` : "";
  switch (outcome.command.verb) {
    case "focus":
      return `Moved to${suffix}`;
    case "send":
    case "dictate":
      return `Sent to${suffix}`;
    case "interrupt":
      return `Interrupted${suffix}`;
    case "spawn":
      return "Started a new chat";
    case "status":
      return "Checked what needs you";
    case "listen_ctl":
      return "Voice control";
    case "noise":
      return "Heard, no command";
  }
}

function stateLabel(outcome: CommandOutcome): string {
  switch (outcome.state) {
    case "SUCCEEDED":
      return "Verified";
    case "FAILED":
      return "Failed";
    case "AWAITING_CONFIRMATION":
      return "Waiting";
    case "EXECUTED":
      return "Done";
    case "UNVERIFIED":
      return "Done";
  }
}

function targetName(
  id: string | null,
  snapshot: FleetSnapshot | null,
): string | null {
  if (!id) return null;
  return snapshot?.agents.find((agent) => agent.id === id)?.name ?? id;
}
