export type LocalSTTStatus = "idle" | "connecting" | "listening" | "error";

export interface LocalSTTEvent {
  type: "interim" | "final";
  text: string;
  tMs: number;
}

export interface LocalSTTSessionOptions {
  url?: string;
  onStatus?: (status: LocalSTTStatus) => void;
  onInterim?: (event: LocalSTTEvent) => void;
  onFinal?: (event: LocalSTTEvent) => void;
  onError?: (error: Error) => void;
}

const SAMPLE_RATE = 16_000;
const MAX_HINTS = 64;
const MAX_HINT_LENGTH = 80;
const MAX_BACKOFF_MS = 4_000;
const STOP_GRACE_MS = 15_000;

function cleanHints(words: string[]): string[] {
  return words
    .map((word) => word.trim().slice(0, MAX_HINT_LENGTH))
    .filter(Boolean)
    .slice(0, MAX_HINTS);
}

function parseEvent(data: unknown): LocalSTTEvent | null {
  if (typeof data !== "string") return null;
  try {
    const value = JSON.parse(data) as Partial<LocalSTTEvent>;
    if (
      (value.type === "interim" || value.type === "final") &&
      typeof value.text === "string" &&
      typeof value.tMs === "number"
    ) {
      return {
        type: value.type,
        text: value.text,
        tMs: value.tMs,
      };
    }
  } catch {
    // Ignore malformed server messages and keep the audio session alive.
  }
  return null;
}

export class LocalSTTSession {
  private readonly url: string;
  private readonly options: LocalSTTSessionOptions;
  private socket: WebSocket | null = null;
  private hints: string[] = [];
  private desired = false;
  private reconnectAttempt = 0;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private stopTimer: ReturnType<typeof setTimeout> | null = null;
  private openWaiters: Array<() => void> = [];

  constructor(options: LocalSTTSessionOptions = {}) {
    this.url = options.url ?? "ws://127.0.0.1:4191";
    this.options = options;
  }

  setHints(words: string[]): void {
    this.hints = cleanHints(words);
  }

  start(): Promise<void> {
    this.desired = true;
    this.clearStopTimer();

    if (this.socket?.readyState === WebSocket.OPEN) {
      this.sendStart();
      this.options.onStatus?.("listening");
      return Promise.resolve();
    }

    const opened = new Promise<void>((resolve) => {
      this.openWaiters.push(resolve);
    });
    this.connect();
    return opened;
  }

  pushPcm(frame: ArrayBuffer): boolean {
    if (this.socket?.readyState !== WebSocket.OPEN || !this.desired) {
      return false;
    }
    this.socket.send(frame);
    return true;
  }

  stop(): void {
    this.desired = false;
    this.clearReconnectTimer();
    this.options.onStatus?.("idle");

    if (this.socket?.readyState === WebSocket.OPEN) {
      this.socket.send(JSON.stringify({ type: "stop" }));
      this.stopTimer = setTimeout(() => this.closeSocket(), STOP_GRACE_MS);
      return;
    }
    this.closeSocket();
  }

  destroy(): void {
    this.desired = false;
    this.clearReconnectTimer();
    this.clearStopTimer();
    this.openWaiters = [];
    this.closeSocket();
  }

  private connect(): void {
    if (
      !this.desired ||
      this.socket?.readyState === WebSocket.CONNECTING ||
      this.socket?.readyState === WebSocket.OPEN
    ) {
      return;
    }

    this.options.onStatus?.("connecting");
    let socket: WebSocket;
    try {
      socket = new WebSocket(this.url);
    } catch (error) {
      this.options.onError?.(
        error instanceof Error ? error : new Error(String(error)),
      );
      this.scheduleReconnect();
      return;
    }
    this.socket = socket;

    socket.addEventListener("open", () => {
      if (socket !== this.socket) return;
      this.reconnectAttempt = 0;
      this.sendStart();
      this.options.onStatus?.("listening");
      for (const resolve of this.openWaiters.splice(0)) resolve();
    });

    socket.addEventListener("message", (message) => {
      if (socket !== this.socket) return;
      const event = parseEvent(message.data);
      if (!event) return;
      if (event.type === "interim") {
        this.options.onInterim?.(event);
        return;
      }
      this.options.onFinal?.(event);
      if (!this.desired) {
        this.clearStopTimer();
        this.closeSocket();
      }
    });

    socket.addEventListener("error", () => {
      if (socket === this.socket) socket.close();
    });

    socket.addEventListener("close", () => {
      if (socket !== this.socket) return;
      this.socket = null;
      if (this.desired) this.scheduleReconnect();
    });
  }

  private sendStart(): void {
    this.socket?.send(
      JSON.stringify({
        type: "start",
        sampleRate: SAMPLE_RATE,
        vocabulary: this.hints,
      }),
    );
  }

  private scheduleReconnect(): void {
    if (!this.desired || this.reconnectTimer) return;
    this.options.onStatus?.("connecting");
    const delay = Math.min(
      MAX_BACKOFF_MS,
      250 * 2 ** this.reconnectAttempt,
    );
    this.reconnectAttempt += 1;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }

  private closeSocket(): void {
    const socket = this.socket;
    this.socket = null;
    if (
      socket &&
      (socket.readyState === WebSocket.OPEN ||
        socket.readyState === WebSocket.CONNECTING)
    ) {
      socket.close();
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
  }

  private clearStopTimer(): void {
    if (this.stopTimer) clearTimeout(this.stopTimer);
    this.stopTimer = null;
  }
}
