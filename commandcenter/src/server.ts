import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createServer as createViteServer } from "vite";
import { WebSocket, WebSocketServer } from "ws";

import type { FleetAgent } from "./contracts.js";
import {
  ChatSourcesProvider,
  type ChatEntry,
} from "./control/chat-sources.js";
import {
  ChatMessagesError,
  ChatMessagesService,
  parseChatMessagesRequest,
} from "./control/chat-messages.js";
import type { FleetControl } from "./control/fleet-control.js";
import { HerdrAdapter } from "./control/herdr-adapter.js";
import { UnixSocketHerdrTransport } from "./control/herdr-transport.js";
import { MockHerdr } from "./control/mock-herdr.js";
import { CommandLoop, type CommandLoopEvent } from "./loop/command-loop.js";
import { CascadeRouter } from "./router/cascade-router.js";
import { DeterministicRouter } from "./router/deterministic-router.js";
import { GemmaRouter } from "./router/gemma-router.js";
import {
  ExecGemmaTransport,
  HttpGemmaTransport,
  OllamaHttpGemmaTransport,
} from "./router/gemma-transport.js";
import type { Router } from "./router/router.js";

type ServerBroadcast = {
  type: "cursor.chats";
  chats: ChatEntry[];
};

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.env.PORT ?? 4173);
const control = createControl();
const router = createRouter();
const loop = new CommandLoop({ router, control });
const httpServer = createServer();
const webSockets = new WebSocketServer({ server: httpServer, path: "/ws" });
const chatMessages = new ChatMessagesService();
const sentChatMessages = new WeakMap<WebSocket, Map<string, string>>();
const selectedChats = new WeakMap<
  WebSocket,
  { source: ChatEntry["source"]; chatId: string; requestedAt: number }
>();
const vite = await createViteServer({
  root: resolve(root, "console"),
  server: { middlewareMode: true },
  appType: "spa",
});

httpServer.on("request", (request, response) => {
  vite.middlewares(request, response, (error: unknown) => {
    response.statusCode = 500;
    response.end(error instanceof Error ? error.message : "Vite error");
  });
});

const chatSources = new ChatSourcesProvider({
  cursor: { pollMs: optionalNumber("CURSOR_CHATS_POLL_MS") ?? 30_000 },
  windowMs: optionalNumber("CHATS_WINDOW_MS"),
});
if (process.env.CURSOR_CHATS !== "off") chatSources.start();

loop.subscribe((event) => broadcast(event));
control.subscribe((snapshot) =>
  broadcast({ type: "fleet.snapshot", snapshot }),
);
chatSources.subscribe((chats) => broadcast({ type: "cursor.chats", chats }));

webSockets.on("connection", (socket) => {
  const chatPoll = setInterval(() => {
    const selected = selectedChats.get(socket);
    if (!selected || Date.now() - selected.requestedAt > 3_500) return;
    void sendChatMessages(socket, selected.source, selected.chatId);
  }, 1_000);
  void control.snapshot().then((snapshot) => {
    send(socket, { type: "fleet.snapshot", snapshot });
  });
  send(socket, { type: "cursor.chats", chats: chatSources.current() });
  socket.on("message", (data) => {
    void handleClientMessage(socket, data.toString("utf8"));
  });
  socket.on("close", () => clearInterval(chatPoll));
});

httpServer.listen(port, "127.0.0.1", () => {
  console.log(
    `Voice Command Center listening at http://127.0.0.1:${port} (${process.env.HERDR_MODE === "real" ? "real Herdr" : "MockHerdr"})`,
  );
});

async function handleClientMessage(
  socket: WebSocket,
  rawMessage: string,
): Promise<void> {
  try {
    const parsed = JSON.parse(rawMessage) as unknown;
    const chatRequest = parseChatMessagesRequest(parsed);
    if (chatRequest) {
      const previous = selectedChats.get(socket);
      if (
        previous &&
        (previous.source !== chatRequest.source ||
          previous.chatId !== chatRequest.chatId)
      ) {
        sentChatMessages
          .get(socket)
          ?.delete(`${chatRequest.source}:${chatRequest.chatId}`);
      }
      selectedChats.set(socket, {
        source: chatRequest.source,
        chatId: chatRequest.chatId,
        requestedAt: Date.now(),
      });
      await sendChatMessages(socket, chatRequest.source, chatRequest.chatId);
      return;
    }
    const message = parsed as {
      type?: string;
      text?: string;
      sttMs?: number;
      outcomeId?: string;
    };
    if (message.type === "utterance" && message.text?.trim()) {
      await loop.handleUtterance(message.text.trim(), {
        sttMs: message.sttMs,
      });
      return;
    }
    if (message.type === "confirm" && message.outcomeId) {
      await loop.confirm(message.outcomeId);
      return;
    }
    if (message.type === "snapshot.request") {
      send(socket, {
        type: "fleet.snapshot",
        snapshot: await control.snapshot(),
      });
      return;
    }
    throw new Error("unsupported client message");
  } catch (error) {
    send(socket, {
      type: "server.error",
      message: error instanceof Error ? error.message : String(error),
    });
  }
}

async function sendChatMessages(
  socket: WebSocket,
  source: "cursor" | "claude" | "codex",
  chatId: string,
): Promise<void> {
  const key = `${source}:${chatId}`;
  const sent = sentChatMessages.get(socket) ?? new Map<string, string>();
  sentChatMessages.set(socket, sent);
  try {
    const result = await chatMessages.read(source, chatId);
    if (sent.get(key) === result.fingerprint) return;
    sent.set(key, result.fingerprint);
    send(socket, {
      type: "chat.messages",
      source: result.source,
      chatId: result.chatId,
      messages: result.messages,
      updatedAt: result.updatedAt,
    });
  } catch (error) {
    const code =
      error instanceof ChatMessagesError ? error.code : "parse_error";
    const message =
      error instanceof ChatMessagesError
        ? error.message
        : "The local conversation could not be read.";
    const fingerprint = `error:${code}:${message}`;
    if (sent.get(key) === fingerprint) return;
    sent.set(key, fingerprint);
    send(socket, {
      type: "chat.messages.error",
      source,
      chatId,
      code,
      message,
    });
  }
}

function createControl(): FleetControl {
  if (process.env.HERDR_MODE === "real") {
    const socketPath = process.env.HERDR_SOCKET_PATH;
    if (!socketPath) {
      throw new Error("HERDR_SOCKET_PATH is required with HERDR_MODE=real");
    }
    return new HerdrAdapter({
      transport: new UnixSocketHerdrTransport({ socketPath }),
    });
  }
  return new MockHerdr({
    agents: demoAgents(),
    focusedAgentId: "tests",
    latencyMs: 35,
  });
}

function createRouter(): Router {
  const deterministic = new DeterministicRouter();
  const gemma = createGemmaRouter();
  if (!gemma) return deterministic;
  if (process.env.GEMMA_CASCADE === "off") return gemma;
  return new CascadeRouter({
    deterministic,
    gemma,
    timeoutMs: optionalNumber("GEMMA_CASCADE_TIMEOUT_MS") ?? 20_000,
  });
}

function createGemmaRouter(): GemmaRouter | null {
  if (process.env.GEMMA_OLLAMA_MODEL) {
    return new GemmaRouter(
      new OllamaHttpGemmaTransport({
        model: process.env.GEMMA_OLLAMA_MODEL,
        endpoint: process.env.GEMMA_OLLAMA_ENDPOINT,
        temperature: optionalNumber("GEMMA_OLLAMA_TEMPERATURE"),
        numPredict: optionalNumber("GEMMA_OLLAMA_NUM_PREDICT"),
        think: optionalBoolean("GEMMA_OLLAMA_THINK"),
      }),
    );
  }
  if (process.env.GEMMA_HTTP_ENDPOINT) {
    return new GemmaRouter(
      new HttpGemmaTransport({
        endpoint: process.env.GEMMA_HTTP_ENDPOINT,
      }),
    );
  }
  if (process.env.GEMMA_COMMAND) {
    const args = process.env.GEMMA_ARGS
      ? (JSON.parse(process.env.GEMMA_ARGS) as string[])
      : [];
    return new GemmaRouter(
      new ExecGemmaTransport({
        command: process.env.GEMMA_COMMAND,
        args,
      }),
    );
  }
  return null;
}

function optionalNumber(name: string): number | undefined {
  const value = process.env[name];
  if (value === undefined) return undefined;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be a finite number`);
  }
  return parsed;
}

function optionalBoolean(name: string): boolean | undefined {
  const value = process.env[name];
  if (value === undefined) return undefined;
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`${name} must be true or false`);
}

function broadcast(event: CommandLoopEvent | ServerBroadcast): void {
  for (const client of webSockets.clients) send(client, event);
}

function send(socket: WebSocket, value: unknown): void {
  if (socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify(value));
  }
}

function demoAgents(): FleetAgent[] {
  const at = new Date().toISOString();
  return [
    {
      id: "migration",
      name: "Migration Agent",
      harness: "claude",
      status: "blocked",
      cwd: "/repos/api",
      lastActivity: { summary: "Waiting for database choice", at },
    },
    {
      id: "tests",
      name: "Test Agent",
      harness: "claude",
      status: "idle",
      cwd: "/repos/api",
      lastActivity: { summary: "Auth suite passed", at },
    },
    {
      id: "deploy",
      name: "Deploy Agent",
      harness: "codex",
      status: "working",
      cwd: "/repos/infra",
      lastActivity: { summary: "Writing deployment plan", at },
    },
    {
      id: "docs",
      name: "Docs Agent",
      harness: "codex",
      status: "done",
      cwd: "/repos/docs",
      lastActivity: { summary: "README draft ready", at },
    },
  ];
}
