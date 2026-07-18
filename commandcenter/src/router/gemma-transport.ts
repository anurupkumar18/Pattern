import { spawn } from "node:child_process";

export interface GemmaTransport {
  complete(prompt: string): Promise<string>;
}

export interface ExecGemmaTransportOptions {
  command: string;
  args?: string[];
  timeoutMs?: number;
}

export class ExecGemmaTransport implements GemmaTransport {
  private readonly command: string;
  private readonly args: string[];
  private readonly timeoutMs: number;

  constructor(options: ExecGemmaTransportOptions) {
    this.command = options.command;
    this.args = options.args ?? [];
    this.timeoutMs = options.timeoutMs ?? 30_000;
  }

  complete(prompt: string): Promise<string> {
    return new Promise((resolve, reject) => {
      const child = spawn(this.command, this.args, {
        stdio: ["pipe", "pipe", "pipe"],
      });
      let stdout = "";
      let stderr = "";
      const timeout = setTimeout(() => {
        child.kill("SIGTERM");
        reject(new Error(`Gemma command timed out after ${this.timeoutMs}ms`));
      }, this.timeoutMs);

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        stdout += chunk;
      });
      child.stderr.on("data", (chunk: string) => {
        stderr += chunk;
      });
      child.on("error", (error) => {
        clearTimeout(timeout);
        reject(error);
      });
      child.on("close", (code) => {
        clearTimeout(timeout);
        if (code === 0) resolve(stdout.trim());
        else {
          reject(
            new Error(
              `Gemma command exited ${code ?? "unknown"}: ${stderr.trim()}`,
            ),
          );
        }
      });
      child.stdin.end(prompt);
    });
  }
}

export interface HttpGemmaTransportOptions {
  endpoint: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export class HttpGemmaTransport implements GemmaTransport {
  private readonly endpoint: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: HttpGemmaTransportOptions) {
    this.endpoint = options.endpoint;
    this.timeoutMs = options.timeoutMs ?? 30_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async complete(prompt: string): Promise<string> {
    const response = await this.fetchImpl(this.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ prompt }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!response.ok) {
      throw new Error(`Gemma HTTP transport returned ${response.status}`);
    }
    const contentType = response.headers.get("content-type") ?? "";
    if (contentType.includes("application/json")) {
      const body = (await response.json()) as {
        output?: unknown;
        text?: unknown;
      };
      const output = body.output ?? body.text;
      if (typeof output !== "string") {
        throw new Error("Gemma HTTP response must contain output or text");
      }
      return output;
    }
    return (await response.text()).trim();
  }
}

export interface OllamaHttpGemmaTransportOptions {
  model: string;
  endpoint?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
  keepAlive?: string;
  temperature?: number;
  numPredict?: number;
  think?: boolean;
}

export class OllamaHttpGemmaTransport implements GemmaTransport {
  private readonly model: string;
  private readonly endpoint: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;
  private readonly keepAlive: string;
  private readonly temperature: number | undefined;
  private readonly numPredict: number | undefined;
  private readonly think: boolean | undefined;

  constructor(options: OllamaHttpGemmaTransportOptions) {
    this.model = options.model;
    this.endpoint =
      options.endpoint ?? "http://127.0.0.1:11434/api/generate";
    this.timeoutMs = options.timeoutMs ?? 120_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.keepAlive = options.keepAlive ?? "30m";
    this.temperature = options.temperature;
    this.numPredict = options.numPredict;
    this.think = options.think;
  }

  async complete(prompt: string): Promise<string> {
    const options: Record<string, number> = {};
    if (this.temperature !== undefined) {
      options.temperature = this.temperature;
    }
    if (this.numPredict !== undefined) {
      options.num_predict = this.numPredict;
    }
    const response = await this.fetchImpl(this.endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: this.model,
        prompt,
        stream: false,
        ...(this.think === undefined ? {} : { think: this.think }),
        keep_alive: this.keepAlive,
        options,
      }),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    if (!response.ok) {
      throw new Error(`Ollama HTTP transport returned ${response.status}`);
    }
    const body = (await response.json()) as { response?: unknown };
    if (typeof body.response !== "string") {
      throw new Error("Ollama HTTP response must contain response");
    }
    return body.response;
  }
}
