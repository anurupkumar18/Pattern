import { useCallback, useEffect, useRef, useState } from "react";

import type {
  CommandOutcome,
  FleetCommand,
  FleetSnapshot,
} from "../../src/contracts.js";
import type {
  ChatEntry,
  ChatMessage,
  ChatTranscriptState,
} from "./model.js";

export interface RoutedEvent {
  command: FleetCommand;
  latencyMs: number;
  at: number;
}

export type ClientCommand = {
  type: "chat.send";
  chatId: string;
  source: "claude" | "codex";
  text: string;
};

type ServerEvent =
  | { type: "fleet.snapshot"; snapshot: FleetSnapshot }
  | { type: "command.routed"; command: FleetCommand; latencyMs: number }
  | { type: "command.outcome"; outcome: CommandOutcome }
  | { type: "cursor.chats"; chats: ChatEntry[] }
  | {
      type: "chat.send.result";
      chatId: string;
      ok: boolean;
      error?: string;
    }
  | {
      type: "chat.messages";
      source: ChatEntry["source"];
      chatId: string;
      messages: ChatMessage[];
      updatedAt: string;
    }
  | {
      type: "chat.messages.error";
      source: ChatEntry["source"];
      chatId: string;
      code: "not_found" | "parse_error" | "invalid_id";
      message: string;
    }
  | { type: "server.error"; message: string };

export interface ProtocolHandlers {
  onRouted?: (event: RoutedEvent) => void;
  onOutcome?: (outcome: CommandOutcome) => void;
}

export function useProtocol(handlers: ProtocolHandlers = {}) {
  const socketRef = useRef<WebSocket | null>(null);
  const selectedChatRef = useRef<{
    source: ChatEntry["source"];
    chatId: string;
  } | null>(null);
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
  const [transcript, setTranscript] = useState<ChatTranscriptState>({
    source: null,
    chatId: null,
    messages: [],
    status: "idle",
    error: null,
    updatedAt: null,
  });

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

  const refreshChatMessages = useCallback(() => {
    const selected = selectedChatRef.current;
    if (!selected) return;
    send({ type: "chat.messages.request", ...selected });
  }, [send]);

  const selectChatMessages = useCallback(
    (source: ChatEntry["source"], chatId: string) => {
      const changed =
        selectedChatRef.current?.source !== source ||
        selectedChatRef.current?.chatId !== chatId;
      selectedChatRef.current = { source, chatId };
      if (changed) {
        setTranscript({
          source,
          chatId,
          messages: [],
          status: "loading",
          error: null,
          updatedAt: null,
        });
      }
      send({ type: "chat.messages.request", source, chatId });
    },
    [send],
  );

  const clearChatMessages = useCallback(() => {
    selectedChatRef.current = null;
    setTranscript({
      source: null,
      chatId: null,
      messages: [],
      status: "idle",
      error: null,
      updatedAt: null,
    });
  }, []);

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
        if (selectedChatRef.current) {
          socket.send(
            JSON.stringify({
              type: "chat.messages.request",
              ...selectedChatRef.current,
            }),
          );
        }
      };
      socket.onmessage = (message) => {
        const event = JSON.parse(message.data as string) as ServerEvent;
        if (event.type === "fleet.snapshot") {
          setSnapshot(event.snapshot);
        } else if (event.type === "cursor.chats") {
          setChats(event.chats);
        } else if (event.type === "chat.messages") {
          const selected = selectedChatRef.current;
          if (
            selected?.source !== event.source ||
            selected.chatId !== event.chatId
          ) {
            return;
          }
          setTranscript({
            source: event.source,
            chatId: event.chatId,
            messages: event.messages,
            status: "ready",
            error: null,
            updatedAt: event.updatedAt,
          });
        } else if (event.type === "chat.messages.error") {
          const selected = selectedChatRef.current;
          if (
            selected?.source !== event.source ||
            selected.chatId !== event.chatId
          ) {
            return;
          }
          setTranscript((current) => ({
            ...current,
            source: event.source,
            chatId: event.chatId,
            status: "error",
            error: event.message,
          }));
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
    transcript,
    serverError,
    submitUtterance,
    confirm,
    selectChatMessages,
    refreshChatMessages,
    clearChatMessages,
    dismissPending: () => setPending(null),
  };
}
