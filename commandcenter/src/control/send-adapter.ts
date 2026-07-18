import { spawn, type ChildProcess } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, isAbsolute, join } from "node:path";

export type SendSource = "claude" | "codex";

export interface SendTarget {
  source: SendSource;
  id: string;
}

export interface SendResult {
  ok: boolean;
  error?: string;
}

export interface SendAdapterOptions {
  claudeRoot?: string;
  codexRoot?: string;
  busyMs?: number;
  now?: () => number;
  spawnProcess?: (
    command: string,
    args: string[],
    options: {
      cwd: string;
      detached: boolean;
      stdio: ["pipe", "ignore", "ignore"];
    },
  ) => ChildProcess;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DEFAULT_BUSY_MS = 10_000;

/**
 * Resumes dormant Claude Code and Codex CLI sessions in place. The child is
 * intentionally detached: existing JSONL pollers reconcile the appended turn.
 */
export class SendAdapter {
  private readonly claudeRoot: string;
  private readonly codexRoot: string;
  private readonly busyMs: number;
  private readonly now: () => number;
  private readonly spawnProcess: NonNullable<SendAdapterOptions["spawnProcess"]>;
  private readonly inFlight = new Set<string>();

  constructor(options: SendAdapterOptions = {}) {
    this.claudeRoot =
      options.claudeRoot ?? join(homedir(), ".claude/projects");
    this.codexRoot = options.codexRoot ?? join(homedir(), ".codex/sessions");
    this.busyMs = options.busyMs ?? DEFAULT_BUSY_MS;
    this.now = options.now ?? Date.now;
    this.spawnProcess = options.spawnProcess ?? spawn;
  }

  async send(target: SendTarget, text: string): Promise<SendResult> {
    const prompt = text.trim();
    if (!prompt) return { ok: false, error: "Message text is required." };

    let sessionId: string;
    try {
      sessionId = normalizeSessionId(target.source, target.id);
    } catch (error) {
      return { ok: false, error: errorMessage(error) };
    }

    const key = `${target.source}:${sessionId}`;
    if (this.inFlight.has(key)) {
      return {
        ok: false,
        error: "This chat is already receiving a message. Wait for it to finish.",
      };
    }

    try {
      const filePath = await locateSessionFile(target.source, sessionId, {
        claudeRoot: this.claudeRoot,
        codexRoot: this.codexRoot,
      });
      if (!filePath) {
        return { ok: false, error: "The local session file was not found." };
      }

      const fileStat = await stat(filePath);
      if (this.now() - fileStat.mtimeMs < this.busyMs) {
        return {
          ok: false,
          error:
            "This chat was modified recently and may still be streaming. Wait a few seconds and try again.",
        };
      }

      const content = await readFile(filePath, "utf8");
      const cwd = extractSessionCwd(target.source, content);
      if (!cwd || !isAbsolute(cwd)) {
        return {
          ok: false,
          error: "The session does not contain a valid original working directory.",
        };
      }
      const cwdStat = await stat(cwd).catch(() => null);
      if (!cwdStat?.isDirectory()) {
        return {
          ok: false,
          error: `The session working directory no longer exists: ${cwd}`,
        };
      }

      const command =
        target.source === "claude"
          ? {
              bin: "claude",
              args: ["--print", "--resume", sessionId],
            }
          : {
              bin: "codex",
              args: ["exec", "resume", "--json", sessionId, "-"],
            };

      this.inFlight.add(key);
      let child: ChildProcess;
      try {
        child = this.spawnProcess(command.bin, command.args, {
          cwd,
          detached: true,
          stdio: ["pipe", "ignore", "ignore"],
        });
      } catch (error) {
        this.inFlight.delete(key);
        return { ok: false, error: `Could not start ${command.bin}: ${errorMessage(error)}` };
      }

      child.once("close", () => this.inFlight.delete(key));
      const started = new Promise<void>((resolve, reject) => {
        child.once("spawn", resolve);
        child.once("error", reject);
      });
      child.stdin?.end(prompt);

      try {
        await started;
      } catch (error) {
        this.inFlight.delete(key);
        return { ok: false, error: `Could not start ${command.bin}: ${errorMessage(error)}` };
      }
      child.unref();
      return { ok: true };
    } catch (error) {
      this.inFlight.delete(key);
      return { ok: false, error: errorMessage(error) };
    }
  }
}

export async function locateSessionFile(
  source: SendSource,
  id: string,
  options: Pick<SendAdapterOptions, "claudeRoot" | "codexRoot"> = {},
): Promise<string | null> {
  const sessionId = normalizeSessionId(source, id);
  const root =
    source === "claude"
      ? options.claudeRoot ?? join(homedir(), ".claude/projects")
      : options.codexRoot ?? join(homedir(), ".codex/sessions");
  const maxDepth = source === "claude" ? 2 : 4;
  const candidates: Array<{ path: string; mtimeMs: number }> = [];

  async function walk(directory: string, depth: number): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true }).catch(
      () => [],
    );
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < maxDepth) {
        await walk(path, depth + 1);
      } else if (
        entry.isFile() &&
        depth === maxDepth &&
        sessionFileMatches(source, entry.name, sessionId)
      ) {
        const fileStat = await stat(path).catch(() => null);
        if (fileStat) candidates.push({ path, mtimeMs: fileStat.mtimeMs });
      }
    }
  }

  await walk(root, 1);
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);
  return candidates[0]?.path ?? null;
}

export function extractSessionCwd(
  source: SendSource,
  content: string,
): string | null {
  let cwd: string | null = null;
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    let event: Record<string, unknown>;
    try {
      const parsed = JSON.parse(line) as unknown;
      if (!isRecord(parsed)) continue;
      event = parsed;
    } catch {
      continue;
    }

    if (source === "claude") {
      cwd = nonEmptyString(event.cwd) ?? cwd;
      continue;
    }
    if (event.type !== "session_meta" || !isRecord(event.payload)) continue;
    cwd = nonEmptyString(event.payload.cwd) ?? cwd;
  }
  return cwd;
}

function normalizeSessionId(source: SendSource, id: string): string {
  const prefix = `${source}:`;
  const sessionId = id.startsWith(prefix) ? id.slice(prefix.length) : id;
  if (!UUID_RE.test(sessionId)) {
    throw new Error("The requested local conversation ID is invalid.");
  }
  return sessionId;
}

function sessionFileMatches(
  source: SendSource,
  fileName: string,
  sessionId: string,
): boolean {
  if (!fileName.endsWith(".jsonl")) return false;
  if (source === "claude") return basename(fileName, ".jsonl") === sessionId;
  return basename(fileName, ".jsonl").endsWith(sessionId);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
