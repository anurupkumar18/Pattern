import { randomUUID } from "node:crypto";
import { createConnection, type Socket } from "node:net";

export interface HerdrSubscription {
  type: string;
  pane_id?: string;
  agent_status?: string;
}

export interface HerdrTransport {
  request(method: string, params: Record<string, unknown>): Promise<unknown>;
  subscribe(
    subscriptions: HerdrSubscription[],
    handler: (event: unknown) => void,
  ): () => void;
}

export interface UnixSocketHerdrTransportOptions {
  socketPath: string;
  timeoutMs?: number;
}

export class UnixSocketHerdrTransport implements HerdrTransport {
  private readonly socketPath: string;
  private readonly timeoutMs: number;

  constructor(options: UnixSocketHerdrTransportOptions) {
    if (!options.socketPath) {
      throw new Error(
        "Herdr socket path is required. Set HERDR_SOCKET_PATH or pass socketPath.",
      );
    }
    this.socketPath = options.socketPath;
    this.timeoutMs = options.timeoutMs ?? 5_000;
  }

  request(method: string, params: Record<string, unknown>): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      const id = randomUUID();
      let buffer = "";
      let settled = false;

      const finish = (error?: Error, value?: unknown) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        if (error) reject(error);
        else resolve(value);
      };

      socket.setTimeout(this.timeoutMs, () =>
        finish(new Error(`Herdr request timed out: ${method}`)),
      );
      socket.on("error", (error) => finish(error));
      socket.on("connect", () => {
        socket.write(`${JSON.stringify({ id, method, params })}\n`);
      });
      socket.on("data", (chunk: Buffer) => {
        buffer += chunk.toString("utf8");
        const lines = buffer.split("\n");
        buffer = lines.pop() ?? "";
        for (const line of lines) {
          if (!line.trim()) continue;
          const message = JSON.parse(line) as {
            id?: string;
            result?: unknown;
            error?: { code?: string; message?: string };
          };
          if (message.id !== id) continue;
          if (message.error) {
            finish(
              new Error(
                `Herdr ${message.error.code ?? "error"}: ${
                  message.error.message ?? "unknown error"
                }`,
              ),
            );
          } else {
            finish(undefined, message.result);
          }
        }
      });
    });
  }

  subscribe(
    subscriptions: HerdrSubscription[],
    handler: (event: unknown) => void,
  ): () => void {
    const socket = createConnection(this.socketPath);
    const id = randomUUID();
    let buffer = "";

    socket.on("connect", () => {
      socket.write(
        `${JSON.stringify({
          id,
          method: "events.subscribe",
          params: { subscriptions },
        })}\n`,
      );
    });
    socket.on("data", (chunk: Buffer) => {
      buffer += chunk.toString("utf8");
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) {
        if (!line.trim()) continue;
        const message = JSON.parse(line) as { id?: string; event?: unknown };
        if (message.id === id && !message.event) continue;
        handler(message.event ?? message);
      }
    });
    socket.on("error", (error) => {
      handler({ type: "transport.error", error: error.message });
    });

    return () => closeSocket(socket);
  }
}

function closeSocket(socket: Socket): void {
  if (!socket.destroyed) socket.destroy();
}
