import { useCallback, useEffect, useRef, useState } from "react";

import type {
  CommandOutcome,
  FleetCommand,
  FleetSnapshot,
} from "../../src/contracts.js";
import type { ChatEntry } from "./model.js";

export interface RoutedEvent {
  command: FleetCommand;
  latencyMs: number;
  at: number;
}

type ServerEvent =
  | { type: "fleet.snapshot"; snapshot: FleetSnapshot }
  | { type: "command.routed"; command: FleetCommand; latencyMs: number }
  | { type: "command.outcome"; outcome: CommandOutcome }
  | { type: "cursor.chats"; chats: ChatEntry[] }
  | { type: "server.error"; message: string };

export interface ProtocolHandlers {
  onRouted?: (event: RoutedEvent) => void;
  onOutcome?: (outcome: CommandOutcome) => void;
}

export function useProtocol(handlers: ProtocolHandlers = {}) {
  const socketRef = useRef<WebSocket | null>(null);
  const handlersRef = useRef(handlers);
  handlersRef.current = handlers;

  const [connection, setConnection] = useState<
    "connecting" | "open" | "closed"
  >("connecting");
  const [snapshot, setSnapshot] = useState<FleetSnapshot | null>(null);
  const [chats, setChats] = useState<ChatEntry[]>([]);
  const [outcomes, setOutcomes] = useState<CommandOutcome[]>([]);
  const [pending, setPending] = useState<CommandOutcome | null>(null);
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
      setServerError(null);
      send({ type: "utterance", text: trimmed, sttMs: 0 });
    },
    [send],
  );

  const confirm = useCallback(
    (outcomeId: string) => send({ type: "confirm", outcomeId }),
    [send],
  );

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
        } else if (event.type === "cursor.chats") {
          setChats(event.chats);
        } else if (event.type === "command.routed") {
          handlersRef.current.onRouted?.({
            command: event.command,
            latencyMs: event.latencyMs,
            at: Date.now(),
          });
        } else if (event.type === "command.outcome") {
          setOutcomes((current) =>
            [
              event.outcome,
              ...current.filter(({ id }) => id !== event.outcome.id),
            ].slice(0, 60),
          );
          if (event.outcome.state === "AWAITING_CONFIRMATION") {
            setPending(event.outcome);
          } else {
            setPending((current) =>
              current?.id === event.outcome.id ? null : current,
            );
          }
          handlersRef.current.onOutcome?.(event.outcome);
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

  return {
    connection,
    snapshot,
    chats,
    outcomes,
    pending,
    serverError,
    submitUtterance,
    confirm,
    dismissPending: () => setPending(null),
  };
}
