import { FormEvent, useCallback, useEffect, useRef, useState } from "react";

import type {
  CommandOutcome,
  FleetCommand,
  FleetSnapshot,
} from "../../src/contracts.js";
import type { CommandLoopEvent } from "../../src/loop/command-loop.js";
import { useSpeechRecognition } from "./useSpeechRecognition.js";

interface ChatEntry {
  id: string;
  source: "cursor" | "claude" | "codex";
  name: string;
  status: string;
  generating: boolean;
  lastUpdatedAt: number;
}

type ServerEvent =
  | CommandLoopEvent
  | { type: "server.error"; message: string }
  | { type: "cursor.chats"; chats: ChatEntry[] };

// Herdr's spinner frames (src/ui.rs), advanced at ~8fps.
const SPINNERS = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];

type AgentStatus = "working" | "blocked" | "done" | "idle" | string;

// Local chat status → herdr state idiom.
function chatState(chat: ChatEntry): {
  status: AgentStatus;
  label: string;
} {
  if (chat.generating) return { status: "working", label: "working" };
  if (chat.status === "aborted") return { status: "blocked", label: "aborted" };
  if (
    chat.status === "completed" ||
    chat.status === "finished" ||
    chat.status === "done"
  ) {
    return { status: "idle", label: "done" };
  }
  return { status: "unknown", label: "idle" };
}

function relativeTime(timestamp: number): string {
  const deltaSeconds = Math.max(0, (Date.now() - timestamp) / 1000);
  if (deltaSeconds < 60) return "now";
  if (deltaSeconds < 3600) return `${Math.floor(deltaSeconds / 60)}m ago`;
  return `${Math.floor(deltaSeconds / 3600)}h ago`;
}

function stateIcon(status: AgentStatus, tick: number): string {
  // Mirrors herdr agent_icon (src/ui/status.rs).
  switch (status) {
    case "blocked":
      return "◉";
    case "working":
      return SPINNERS[tick % SPINNERS.length];
    case "done":
      return "●";
    case "idle":
      return "✓";
    default:
      return "○";
  }
}

export function App() {
  const socketRef = useRef<WebSocket | null>(null);
  const [connection, setConnection] = useState<
    "connecting" | "open" | "closed"
  >("connecting");
  const [snapshot, setSnapshot] = useState<FleetSnapshot | null>(null);
  const [routed, setRouted] = useState<{
    command: FleetCommand;
    latencyMs: number;
  } | null>(null);
  const [outcomes, setOutcomes] = useState<CommandOutcome[]>([]);
  const [pending, setPending] = useState<CommandOutcome | null>(null);
  const [lastUtterance, setLastUtterance] = useState("");
  const [text, setText] = useState("");
  const [serverError, setServerError] = useState<string | null>(null);
  const [spinnerTick, setSpinnerTick] = useState(0);
  const [chats, setChats] = useState<ChatEntry[]>([]);

  const send = useCallback((message: unknown) => {
    if (socketRef.current?.readyState === WebSocket.OPEN) {
      socketRef.current.send(JSON.stringify(message));
    }
  }, []);

  const submitUtterance = useCallback(
    (utterance: string) => {
      const trimmed = utterance.trim();
      if (!trimmed) return;
      setLastUtterance(trimmed);
      setServerError(null);
      send({ type: "utterance", text: trimmed, sttMs: 0 });
    },
    [send],
  );

  const speech = useSpeechRecognition(submitUtterance);

  const anyWorking =
    (snapshot?.agents.some((agent) => agent.status === "working") ?? false) ||
    chats.some((chat) => chat.generating);

  useEffect(() => {
    if (!anyWorking) return;
    const timer = window.setInterval(
      () => setSpinnerTick((tick) => tick + 1),
      125,
    );
    return () => window.clearInterval(timer);
  }, [anyWorking]);

  useEffect(() => {
    let disposed = false;
    let reconnectTimer: number | undefined;

    const connect = () => {
      setConnection("connecting");
      const protocol = location.protocol === "https:" ? "wss" : "ws";
      const socket = new WebSocket(`${protocol}://${location.host}/ws`);
      socketRef.current = socket;
      socket.onopen = () => {
        setConnection("open");
        socket.send(JSON.stringify({ type: "snapshot.request" }));
      };
      socket.onmessage = (message) => {
        const event = JSON.parse(message.data as string) as ServerEvent;
        if (event.type === "fleet.snapshot") {
          setSnapshot(event.snapshot);
        } else if (event.type === "command.routed") {
          setRouted({
            command: event.command,
            latencyMs: event.latencyMs,
          });
        } else if (event.type === "command.outcome") {
          setOutcomes((current) => [
            event.outcome,
            ...current.filter(({ id }) => id !== event.outcome.id),
          ].slice(0, 30));
          if (event.outcome.state === "AWAITING_CONFIRMATION") {
            setPending(event.outcome);
          } else {
            setPending((current) =>
              current?.id === event.outcome.id ? null : current,
            );
          }
        } else if (event.type === "cursor.chats") {
          setChats(event.chats);
        } else if (event.type === "server.error") {
          setServerError(event.message);
        }
      };
      socket.onclose = () => {
        setConnection("closed");
        if (!disposed) reconnectTimer = window.setTimeout(connect, 1_000);
      };
      socket.onerror = () => setConnection("closed");
    };

    connect();
    return () => {
      disposed = true;
      if (reconnectTimer) window.clearTimeout(reconnectTimer);
      socketRef.current?.close();
    };
  }, []);

  function onSubmit(event: FormEvent) {
    event.preventDefault();
    submitUtterance(text);
    setText("");
  }

  return (
    <div className="term">
      <aside className="sidebar">
        <div className="panel-header">
          <span>agents</span>
          <span className="panel-toggle">all</span>
        </div>

        <div className="agent-list">
          {snapshot?.agents.map((agent) => {
            const focused = agent.id === snapshot.focusedAgentId;
            return (
              <button
                type="button"
                className={focused ? "agent-entry focused" : "agent-entry"}
                key={agent.id}
                onClick={() => submitUtterance(`focus ${agent.name}`)}
                title={`${agent.harness} · ${agent.cwd}`}
              >
                <span className="entry-row">
                  <span className={`state-icon ${agent.status}`}>
                    {stateIcon(agent.status, spinnerTick)}
                  </span>
                  <span className="entry-name">{agent.name}</span>
                </span>
                <span className="entry-row sub">
                  <span className={`state-label ${agent.status}`}>
                    {agent.status}
                  </span>
                  <span className="dot-sep">·</span>
                  <span className="entry-agent">{agent.harness}</span>
                </span>
              </button>
            );
          })}
          {(!snapshot || snapshot.agents.length === 0) && (
            <div className="agent-empty">no agents</div>
          )}
        </div>

        {chats.length > 0 && (
          <>
            <div className="panel-divider" />
            <div className="panel-header">
              <span>chats</span>
              <span className="panel-toggle">24h</span>
            </div>
            <div className="chat-list">
              {chats.map((chat) => {
                const state = chatState(chat);
                return (
                  <div className="agent-entry" key={chat.id} title={chat.id}>
                    <span className="entry-row">
                      <span className={`state-icon ${state.status}`}>
                        {stateIcon(state.status, spinnerTick)}
                      </span>
                      <span className="entry-name">{chat.name}</span>
                    </span>
                    <span className="entry-row sub">
                      <span className={`state-label ${state.status}`}>
                        {state.label}
                      </span>
                      <span className="dot-sep">·</span>
                      <span className="entry-agent">{chat.source}</span>
                      <span className="dot-sep">·</span>
                      <span className="entry-agent">
                        {relativeTime(chat.lastUpdatedAt)}
                      </span>
                    </span>
                  </div>
                );
              })}
            </div>
          </>
        )}

        <button
          type="button"
          className={speech.listening ? "voice-toggle on" : "voice-toggle"}
          onClick={speech.listening ? speech.stop : speech.start}
          disabled={!speech.supported}
        >
          <span className="vt-icon">{speech.listening ? "●" : "○"}</span>
          <span className="vt-label">
            {speech.supported
              ? `voice ${speech.listening ? "on" : "off"}`
              : "voice unavailable"}
          </span>
        </button>
      </aside>

      <main className="pane">
        <div className="pane-tabbar">
          <span className="tab active">1 command-center</span>
          <span className="pane-status">
            <span className={`conn-dot ${connection}`}>●</span>
            <span>{connection === "open" ? "server live" : connection}</span>
            <span className="dot-sep">·</span>
            <span>{snapshot?.agents.length ?? 0} agents</span>
          </span>
        </div>

        <div className="heard-row">
          <span className="heard-label">heard</span>
          <span className="heard-text">
            {speech.interim ||
              lastUtterance ||
              "say a fleet command or type below"}
          </span>
        </div>

        <form className="prompt" onSubmit={onSubmit}>
          <span className="prompt-mark">❯</span>
          <input
            value={text}
            onChange={(event) => setText(event.target.value)}
            placeholder="tell the blocked one to use staging"
            spellCheck={false}
          />
          <button type="submit" disabled={connection !== "open"}>
            route
          </button>
        </form>

        {(speech.error || serverError) && (
          <div className="error-row">{speech.error ?? serverError}</div>
        )}

        {routed && (
          <div className="route-row">
            <span>
              <span className="k">resolved</span>{" "}
              <strong>{routed.command.verb}</strong>
            </span>
            <span className="dot-sep">·</span>
            <span>
              <span className="k">target</span>{" "}
              <strong>
                {targetName(routed.command.resolvedTargetId, snapshot)}
              </strong>
            </span>
            <span className="dot-sep">·</span>
            <span>
              <span className="k">confidence</span>{" "}
              <strong>{Math.round(routed.command.confidence * 100)}%</strong>
            </span>
            <span className="dot-sep">·</span>
            <span>
              <span className="k">route</span>{" "}
              <strong>{formatMs(routed.latencyMs)}</strong>
            </span>
          </div>
        )}

        {pending && (
          <div className="confirmation">
            <span>
              <span className="confirm-dot">●</span>{" "}
              <strong>
                confirm {pending.command.verb}{" "}
                {targetName(pending.command.resolvedTargetId, snapshot)}
              </strong>{" "}
              <span className="k">
                destructive and low-confidence commands stop before acting
              </span>
            </span>
            <button
              type="button"
              onClick={() => send({ type: "confirm", outcomeId: pending.id })}
            >
              confirm
            </button>
          </div>
        )}

        <div className="log" aria-live="polite">
          {outcomes.length === 0 ? (
            <div className="log-empty">
              no commands yet. try “what needs me right now”.
            </div>
          ) : (
            outcomes.map((outcome) => (
              <OutcomeRow
                key={outcome.id}
                outcome={outcome}
                snapshot={snapshot}
              />
            ))
          )}
        </div>
      </main>
    </div>
  );
}

function OutcomeRow({
  outcome,
  snapshot,
}: {
  outcome: CommandOutcome;
  snapshot: FleetSnapshot | null;
}) {
  const verification = outcome.verification[0];
  return (
    <article className="outcome-row">
      <span className={`outcome-state ${stateClass(outcome.state)}`}>
        {outcome.state.toLowerCase()}
      </span>
      <div className="outcome-body">
        <span className="outcome-title">
          {outcome.command.verb}
          {outcome.command.resolvedTargetId && (
            <>
              <span className="dot-sep">·</span>
              {targetName(outcome.command.resolvedTargetId, snapshot)}
            </>
          )}
        </span>
        <span className="outcome-utterance">
          {outcome.command.rawUtterance}
        </span>
        {verification && (
          <span className="outcome-verify">
            {verification.passed ? "verified" : "predicate failed"}:{" "}
            {verification.evidence}
          </span>
        )}
      </div>
      <span className="outcome-latency">
        stt {formatMs(outcome.latencyMs.stt)} · route{" "}
        {formatMs(outcome.latencyMs.route)} · act{" "}
        {formatMs(outcome.latencyMs.act)} · verify{" "}
        {formatMs(outcome.latencyMs.verify)}
      </span>
    </article>
  );
}

function stateClass(state: CommandOutcome["state"]): string {
  if (state === "SUCCEEDED") return "green";
  if (state === "AWAITING_CONFIRMATION" || state === "UNVERIFIED") {
    return "yellow";
  }
  if (state === "FAILED") return "red";
  return "neutral";
}

function formatMs(value: number): string {
  return `${Math.round(value)}ms`;
}

function targetName(
  id: string | null,
  snapshot: FleetSnapshot | null,
): string {
  if (!id) return "fleet";
  return snapshot?.agents.find((agent) => agent.id === id)?.name ?? id;
}
