import { FormEvent, useCallback, useEffect, useRef, useState } from "react";

import type {
  CommandOutcome,
  FleetCommand,
  FleetSnapshot,
} from "../../src/contracts.js";
import type { CommandLoopEvent } from "../../src/loop/command-loop.js";
import { useSpeechRecognition } from "./useSpeechRecognition.js";

type ServerEvent =
  | CommandLoopEvent
  | { type: "server.error"; message: string };

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
    <main className="shell">
      <header className="topbar">
        <div>
          <p className="eyebrow">Local agent fleet</p>
          <h1>Voice Command Center</h1>
        </div>
        <div className="trust-strip">
          <StatusDot state={connection} />
          <span>{connection === "open" ? "Server live" : connection}</span>
          <span className="divider" />
          <span>{snapshot?.agents.length ?? 0} agents</span>
          <span className="divider" />
          <span>
            Snapshot{" "}
            {snapshot
              ? new Date(snapshot.capturedAt).toLocaleTimeString()
              : "pending"}
          </span>
        </div>
      </header>

      <section className="voice-strip">
        <button
          className={speech.listening ? "mic active" : "mic"}
          onClick={speech.listening ? speech.stop : speech.start}
          disabled={!speech.supported}
          type="button"
        >
          <span className="mic-indicator" />
          {speech.listening
            ? "Listening"
            : speech.supported
              ? "Start mic"
              : "Speech unavailable"}
        </button>
        <div className="utterance" aria-live="polite">
          <span className="label">Heard</span>
          <strong>
            {speech.interim ||
              lastUtterance ||
              "Say a fleet command or use the input"}
          </strong>
        </div>
        <span className="privacy">Routing stays on this machine</span>
      </section>

      {(speech.error || serverError) && (
        <div className="error-row">{speech.error ?? serverError}</div>
      )}

      <div className="workspace">
        <section className="timeline">
          <div className="section-heading">
            <div>
              <p className="index">01</p>
              <h2>Verified command log</h2>
            </div>
            <span>Executor claims are never final</span>
          </div>

          <form className="command-input" onSubmit={onSubmit}>
            <label htmlFor="command">Simulate an utterance</label>
            <div>
              <input
                id="command"
                value={text}
                onChange={(event) => setText(event.target.value)}
                placeholder="tell the blocked one to use staging"
              />
              <button type="submit" disabled={connection !== "open"}>
                Route
              </button>
            </div>
          </form>

          {routed && (
            <div className="route-row">
              <div>
                <span className="label">Resolved</span>
                <strong>{routed.command.verb}</strong>
              </div>
              <div>
                <span className="label">Target</span>
                <strong>
                  {targetName(routed.command.resolvedTargetId, snapshot)}
                </strong>
              </div>
              <div>
                <span className="label">Confidence</span>
                <strong>
                  {Math.round(routed.command.confidence * 100)}%
                </strong>
              </div>
              <div>
                <span className="label">Route</span>
                <strong>{formatMs(routed.latencyMs)}</strong>
              </div>
            </div>
          )}

          {pending && (
            <div className="confirmation">
              <div>
                <span className="state-mark amber">Confirmation required</span>
                <strong>
                  {pending.command.verb}{" "}
                  {targetName(
                    pending.command.resolvedTargetId,
                    snapshot,
                  )}
                </strong>
                <p>
                  Destructive and low-confidence commands stop before acting.
                </p>
              </div>
              <button
                type="button"
                onClick={() =>
                  send({ type: "confirm", outcomeId: pending.id })
                }
              >
                Confirm command
              </button>
            </div>
          )}

          <div className="log" aria-live="polite">
            {outcomes.length === 0 ? (
              <div className="empty">
                No commands yet. Try “what needs me right now”.
              </div>
            ) : (
              outcomes.map((outcome) => (
                <OutcomeRow key={outcome.id} outcome={outcome} />
              ))
            )}
          </div>
        </section>

        <aside className="fleet">
          <div className="section-heading">
            <div>
              <p className="index">02</p>
              <h2>Fleet snapshot</h2>
            </div>
            <span>Independent state read</span>
          </div>
          <div className="fleet-head">
            <span>Agent</span>
            <span>State</span>
          </div>
          <div className="fleet-list">
            {snapshot?.agents.map((agent) => (
              <div
                className={
                  agent.id === snapshot.focusedAgentId
                    ? "agent-row focused"
                    : "agent-row"
                }
                key={agent.id}
              >
                <div>
                  <strong>{agent.name}</strong>
                  <span>
                    {agent.harness} · {agent.cwd}
                  </span>
                  <p>{agent.lastActivity.summary}</p>
                </div>
                <span className={`agent-state ${agent.status}`}>
                  {agent.status}
                </span>
              </div>
            ))}
          </div>
          <div className="fleet-note">
            <span>Mic gate</span>
            <strong>
              {snapshot?.listening === false ? "Paused" : "Listening"}
            </strong>
          </div>
        </aside>
      </div>
    </main>
  );
}

function OutcomeRow({ outcome }: { outcome: CommandOutcome }) {
  const verification = outcome.verification[0];
  return (
    <article className="outcome-row">
      <div className="outcome-main">
        <span className={`state-mark ${stateClass(outcome.state)}`}>
          {outcome.state}
        </span>
        <div>
          <strong>
            {outcome.command.verb}
            {outcome.command.resolvedTargetId
              ? ` · ${outcome.command.resolvedTargetId}`
              : ""}
          </strong>
          <p>{outcome.command.rawUtterance}</p>
          {verification && (
            <small>
              {verification.passed ? "Verified" : "Predicate failed"}:{" "}
              {verification.evidence}
            </small>
          )}
        </div>
      </div>
      <div className="latencies">
        <span>STT {formatMs(outcome.latencyMs.stt)}</span>
        <span>route {formatMs(outcome.latencyMs.route)}</span>
        <span>act {formatMs(outcome.latencyMs.act)}</span>
        <span>verify {formatMs(outcome.latencyMs.verify)}</span>
      </div>
    </article>
  );
}

function StatusDot({
  state,
}: {
  state: "connecting" | "open" | "closed";
}) {
  return <span className={`status-dot ${state}`} aria-hidden="true" />;
}

function stateClass(state: CommandOutcome["state"]): string {
  if (state === "SUCCEEDED") return "green";
  if (state === "AWAITING_CONFIRMATION" || state === "UNVERIFIED") {
    return "amber";
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
  if (!id) return "Fleet";
  return snapshot?.agents.find((agent) => agent.id === id)?.name ?? id;
}
