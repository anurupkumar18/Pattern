import { createServer } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { createServer as createViteServer } from "vite";
import { WebSocket, WebSocketServer } from "ws";

import type { FleetAgent } from "./contracts.js";
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

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const port = Number(process.env.PORT ?? 4173);
const control = createControl();
const router = createRouter();
const loop = new CommandLoop({ router, control });
const httpServer = createServer();
const webSockets = new WebSocketServer({ server: httpServer, path: "/ws" });
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

loop.subscribe((event) => broadcast(event));
control.subscribe((snapshot) =>
  broadcast({ type: "fleet.snapshot", snapshot }),
);

webSockets.on("connection", (socket) => {
  void control.snapshot().then((snapshot) => {
    send(socket, { type: "fleet.snapshot", snapshot });
  });
  socket.on("message", (data) => {
    void handleClientMessage(socket, data.toString("utf8"));
  });
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
    const message = JSON.parse(rawMessage) as {
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

function broadcast(event: CommandLoopEvent): void {
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
