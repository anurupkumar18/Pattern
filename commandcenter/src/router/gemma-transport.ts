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
