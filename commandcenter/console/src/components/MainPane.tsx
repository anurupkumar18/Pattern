import {
  useEffect,
  useLayoutEffect,
  useRef,
  useState,
  type FormEvent,
} from "react";

import type { CommandOutcome, FleetSnapshot } from "../../../src/contracts.js";
import {
  relativeTime,
  type ChatTranscriptState,
  type HistoryRow,
} from "../model.js";
import type { ChatSendState } from "../useProtocol.js";
import {
  ArrowUpIcon,
  MicIcon,
  SourceGlyph,
  StopIcon,
  WorkingSpinner,
} from "./icons.js";
import { TranscriptMessage } from "./TranscriptMessage.js";
import "../transcript.css";

interface MainPaneProps {
  selected: HistoryRow | null;
  connection: "connecting" | "open" | "closed";
  outcomes: CommandOutcome[];
  snapshot: FleetSnapshot | null;
  transcript: ChatTranscriptState;
  pending: CommandOutcome | null;
  chatSend: ChatSendState;
  voice: {
    supported: boolean;
    status: "idle" | "connecting" | "listening" | "error";
    interim: string;
    finals: string[];
    start: () => Promise<void>;
    stop: () => void;
  };
  onConfirm: (outcomeId: string) => void;
  onCancelPending: () => void;
  onComposerSubmit: (text: string) => void;
  onInterrupt: (row: HistoryRow) => void;
  composerRef: React.RefObject<HTMLTextAreaElement | null>;
}

export function MainPane({
  selected,
  connection,
  outcomes,
  snapshot,
  transcript,
  pending,
  chatSend,
  voice,
  onConfirm,
  onCancelPending,
  onComposerSubmit,
  onInterrupt,
  composerRef,
}: MainPaneProps) {
  const [draft, setDraft] = useState("");
  const appliedFinals = useRef(0);
  const readOnlyChat =
    selected?.kind === "chat" && selected.source === "cursor";
  const selectedSend =
    chatSend.chatId === selected?.id ? chatSend : null;

  useEffect(() => {
    if (voice.finals.length <= appliedFinals.current) return;
    const finalText = voice.finals.slice(appliedFinals.current).join(" ").trim();
    appliedFinals.current = voice.finals.length;
    if (!finalText) return;
    setDraft((current) => `${current.trim()} ${finalText}`.trim());
  }, [voice.finals]);

  function submit(event: FormEvent) {
    event.preventDefault();
    if (readOnlyChat) return;
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
            transcript={transcript}
          />
        </>
      ) : (
        <EmptyState />
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
        {voice.interim && (
          <span className="composer-interim" aria-live="polite">
            {voice.interim}
          </span>
        )}
        <textarea
          ref={composerRef}
          value={draft}
          rows={1}
          placeholder={
            readOnlyChat
              ? "Mirrored from Cursor (read-only)"
              : selected
              ? `Message ${selected.title}…`
              : "Type a command…"
          }
          disabled={readOnlyChat}
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
            {readOnlyChat
              ? "Mirrored from Cursor (read-only)"
              : selectedSend?.status === "sending"
                ? "Sending…"
                : selectedSend?.status === "sent"
                  ? "Sent"
                  : selectedSend?.status === "error"
                    ? selectedSend.error
                    : selected
                      ? selected.title
                      : "Command"}
          </span>
          <span className="composer-actions">
            <button
              type="button"
              className={
                voice.status === "listening" || voice.status === "connecting"
                  ? "icon-button mic on"
                  : "icon-button mic"
              }
              aria-label={
                voice.status === "listening" || voice.status === "connecting"
                  ? "Stop voice"
                  : "Start voice"
              }
              title={
                voice.status === "listening"
                  ? "Stop voice"
                  : voice.status === "connecting"
                    ? "Voice loading"
                    : "Start voice"
              }
              disabled={!voice.supported}
              onClick={() => {
                if (
                  voice.status === "listening" ||
                  voice.status === "connecting"
                ) {
                  voice.stop();
                } else {
                  void voice.start();
                }
              }}
            >
              <MicIcon size={14} />
            </button>
            {!readOnlyChat && (
              <button
                type="submit"
                className={draft.trim() ? "send-button ready" : "send-button"}
                aria-label="Send"
                disabled={!draft.trim() || selectedSend?.status === "sending"}
              >
                <ArrowUpIcon />
              </button>
            )}
          </span>
        </div>
      </form>
    </div>
  );
}

function EmptyState() {
  return (
    <div className="empty-state">
      <span>Select a conversation</span>
    </div>
  );
}

function ActivityStream({
  outcomes,
  snapshot,
  selected,
  transcript,
}: {
  outcomes: CommandOutcome[];
  snapshot: FleetSnapshot | null;
  selected: HistoryRow;
  transcript: ChatTranscriptState;
}) {
  if (selected.kind === "chat") {
    return <TranscriptStream selected={selected} transcript={transcript} />;
  }
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
        {relevantOutcomes.length > 0 &&
          relevantOutcomes
            .slice()
            .reverse()
            .map((outcome) => (
              <OutcomeEvent
                key={outcome.id}
                outcome={outcome}
                snapshot={snapshot}
              />
            ))}
      </div>
    </div>
  );
}

function TranscriptStream({
  selected,
  transcript,
}: {
  selected: HistoryRow;
  transcript: ChatTranscriptState;
}) {
  const streamRef = useRef<HTMLDivElement>(null);
  const nearBottomRef = useRef(true);
  const selectedIdRef = useRef(selected.id);

  useLayoutEffect(() => {
    const stream = streamRef.current;
    if (!stream) return;
    if (selectedIdRef.current !== selected.id) {
      selectedIdRef.current = selected.id;
      nearBottomRef.current = true;
    }
    if (nearBottomRef.current) {
      stream.scrollTop = stream.scrollHeight;
    }
  }, [
    selected.id,
    transcript.messages.length,
    transcript.status,
    transcript.updatedAt,
  ]);

  return (
    <div
      ref={streamRef}
      className="stream transcript-stream"
      aria-live="polite"
      onScroll={(event) => {
        const element = event.currentTarget;
        nearBottomRef.current =
          element.scrollHeight - element.scrollTop - element.clientHeight < 96;
      }}
    >
      <div className="stream-column transcript-column">
        {transcript.status === "loading" ? (
          <TranscriptSkeleton />
        ) : transcript.status === "error" ? (
          <div className="transcript-state transcript-error" role="status">
            <span className="detail-kicker">Local conversation unavailable</span>
            <p>{transcript.error}</p>
          </div>
        ) : transcript.messages.length === 0 ? (
          <div className="transcript-state" role="status">
            <span className="detail-kicker">No visible messages</span>
            <p>
              This local session has no user or assistant text to display.
            </p>
          </div>
        ) : (
          <div className="transcript" aria-label="Conversation history">
            {transcript.messages.map((message) => (
              <TranscriptMessage key={message.id} message={message} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function TranscriptSkeleton() {
  return (
    <div className="transcript-skeleton" role="status" aria-label="Loading messages">
      <div className="skeleton-turn user">
        <span />
        <span />
      </div>
      <div className="skeleton-turn assistant">
        <span />
        <span />
        <span />
      </div>
    </div>
  );
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
