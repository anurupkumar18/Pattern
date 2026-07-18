import { spawn } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

import {
  extractSessionCwd,
  SendAdapter,
} from "../src/control/send-adapter.js";

const PROMPT = "Reply with the single word: pong";
const CLAUDE_ROOT = join(homedir(), ".claude/projects");
const CODEX_ROOT = join(homedir(), ".codex/sessions");
const PREFERRED_PROJECT = join(CLAUDE_ROOT, "-Users-cole-segura-brain");
const BRAIN_CWD = join(homedir(), "brain");
const IDLE_MS = 60_000;
const TIMEOUT_MS = 90_000;
const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

interface Candidate {
  id: string;
  path: string;
  mtimeMs: number;
}

async function main(): Promise<void> {
  if (process.argv.includes("--codex")) {
    await runCodexSmoke();
    return;
  }
  let candidate = await mostRecentIdleClaudeSession();
  if (!candidate) {
    console.log("No Claude session idle for 60s; creating a fresh session.");
    const startedAt = Date.now();
    await runFreshClaude();
    candidate = await newestClaudeSessionSince(startedAt);
    if (!candidate) throw new Error("Fresh Claude session file was not found.");
    await sleepUntilIdle(candidate.path, 10_500);
  }

  const before = await readFile(candidate.path, "utf8");
  const cwd = extractSessionCwd("claude", before);
  if (!cwd) throw new Error("Selected Claude session has no cwd metadata.");

  console.log(
    `Selected idle Claude session ${candidate.id} (cwd metadata present).`,
  );
  const adapter = new SendAdapter();
  const result = await adapter.send(
    { source: "claude", id: candidate.id },
    PROMPT,
  );
  if (!result.ok) throw new Error(result.error ?? "Adapter rejected the send.");
  console.log("Resume process started; waiting for same-file append.");

  const proof = await waitForAppend(candidate.path, before, TIMEOUT_MS);
  if (!proof.userAppended || !proof.assistantAppended) {
    throw new Error(
      `SMOKE FAILED userAppended=${proof.userAppended} assistantAppended=${proof.assistantAppended}`,
    );
  }
  console.log(
    "SMOKE OK sameSession=true userAppended=true assistantAppended=true reply=pong",
  );
}

async function runCodexSmoke(): Promise<void> {
  const candidates = await codexCandidates();
  const candidate = candidates
    .filter(({ mtimeMs }) => Date.now() - mtimeMs >= IDLE_MS)
    .sort((left, right) => right.mtimeMs - left.mtimeMs)[0];
  if (!candidate) throw new Error("No Codex session is idle for 60 seconds.");

  const before = await readFile(candidate.path, "utf8");
  const cwd = extractSessionCwd("codex", before);
  if (!cwd) throw new Error("Selected Codex session has no cwd metadata.");
  console.log(
    `Selected idle Codex session ${candidate.id} (cwd metadata present).`,
  );

  const result = await new SendAdapter().send(
    { source: "codex", id: candidate.id },
    PROMPT,
  );
  if (!result.ok) throw new Error(result.error ?? "Adapter rejected the send.");
  console.log("Resume process started; waiting for same-file append.");

  const proof = await waitForCodexAppend(candidate.path, before, TIMEOUT_MS);
  if (!proof.userAppended || !proof.assistantAppended) {
    throw new Error(
      `SMOKE FAILED userAppended=${proof.userAppended} assistantAppended=${proof.assistantAppended}`,
    );
  }
  console.log(
    "SMOKE OK source=codex sameSession=true userAppended=true assistantAppended=true reply=pong",
  );
}

async function mostRecentIdleClaudeSession(): Promise<Candidate | null> {
  const now = Date.now();
  const preferred = await candidatesInProject(PREFERRED_PROJECT);
  const candidates =
    preferred.length > 0 ? preferred : await candidatesAcrossProjects();
  return (
    candidates
      .filter(({ mtimeMs }) => now - mtimeMs >= IDLE_MS)
      .sort((left, right) => right.mtimeMs - left.mtimeMs)[0] ?? null
  );
}

async function newestClaudeSessionSince(
  startedAt: number,
): Promise<Candidate | null> {
  const candidates = await candidatesAcrossProjects();
  return (
    candidates
      .filter(({ mtimeMs }) => mtimeMs >= startedAt - 1_000)
      .sort((left, right) => right.mtimeMs - left.mtimeMs)[0] ?? null
  );
}

async function candidatesAcrossProjects(): Promise<Candidate[]> {
  const projects = await readdir(CLAUDE_ROOT, { withFileTypes: true }).catch(
    () => [],
  );
  const nested = await Promise.all(
    projects
      .filter((entry) => entry.isDirectory())
      .map((entry) => candidatesInProject(join(CLAUDE_ROOT, entry.name))),
  );
  return nested.flat();
}

async function candidatesInProject(project: string): Promise<Candidate[]> {
  const entries = await readdir(project, { withFileTypes: true }).catch(
    () => [],
  );
  const candidates = await Promise.all(
    entries
      .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
      .map(async (entry): Promise<Candidate | null> => {
        const id = basename(entry.name, ".jsonl");
        if (!UUID_RE.test(id)) return null;
        const path = join(project, entry.name);
        const fileStat = await stat(path).catch(() => null);
        return fileStat ? { id, path, mtimeMs: fileStat.mtimeMs } : null;
      }),
  );
  return candidates.filter(
    (candidate): candidate is Candidate => candidate !== null,
  );
}

async function codexCandidates(): Promise<Candidate[]> {
  const candidates: Candidate[] = [];
  async function walk(directory: string, depth: number): Promise<void> {
    const entries = await readdir(directory, { withFileTypes: true }).catch(
      () => [],
    );
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < 4) {
        await walk(path, depth + 1);
      } else if (entry.isFile() && depth === 4 && entry.name.endsWith(".jsonl")) {
        const id = basename(entry.name, ".jsonl").match(
          /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i,
        )?.[1];
        if (!id) continue;
        const fileStat = await stat(path).catch(() => null);
        if (!fileStat) continue;
        const content = await readFile(path, "utf8").catch(() => "");
        const firstLine = content.split(/\r?\n/, 1)[0];
        try {
          if (!firstLine) continue;
          const first = JSON.parse(firstLine) as {
            type?: string;
            payload?: { cli_version?: string };
          };
          if (
            first.type !== "session_meta" ||
            !first.payload?.cli_version?.startsWith("0.135")
          ) {
            continue;
          }
        } catch {
          continue;
        }
        candidates.push({ id, path, mtimeMs: fileStat.mtimeMs });
      }
    }
  }
  await walk(CODEX_ROOT, 1);
  return candidates;
}

async function runFreshClaude(): Promise<void> {
  await new Promise<void>((resolve, reject) => {
    const child = spawn("claude", ["--print"], {
      cwd: BRAIN_CWD,
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk: Buffer) => {
      if (stderr.length < 2_000) stderr += chunk.toString("utf8");
    });
    const timeout = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error("Fresh Claude session timed out."));
    }, TIMEOUT_MS);
    child.once("error", (error) => {
      clearTimeout(timeout);
      reject(error);
    });
    child.once("close", (code) => {
      clearTimeout(timeout);
      if (code === 0) resolve();
      else reject(new Error(`Fresh Claude exited ${code}: ${stderr.trim()}`));
    });
    child.stdin.end("Reply with the single word: ready");
  });
}

async function sleepUntilIdle(path: string, minimumAgeMs: number): Promise<void> {
  const fileStat = await stat(path);
  const remaining = minimumAgeMs - (Date.now() - fileStat.mtimeMs);
  if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining));
}

async function waitForAppend(
  path: string,
  before: string,
  timeoutMs: number,
): Promise<{ userAppended: boolean; assistantAppended: boolean }> {
  const deadline = Date.now() + timeoutMs;
  let last = { userAppended: false, assistantAppended: false };
  while (Date.now() < deadline) {
    const content = await readFile(path, "utf8");
    if (content.length > before.length) {
      last = inspectAppendedRecords(content.slice(before.length));
      if (last.userAppended && last.assistantAppended) return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  return last;
}

async function waitForCodexAppend(
  path: string,
  before: string,
  timeoutMs: number,
): Promise<{ userAppended: boolean; assistantAppended: boolean }> {
  const deadline = Date.now() + timeoutMs;
  let last = { userAppended: false, assistantAppended: false };
  while (Date.now() < deadline) {
    const content = await readFile(path, "utf8");
    if (content.length > before.length) {
      last = inspectCodexRecords(content.slice(before.length));
      if (last.userAppended && last.assistantAppended) return last;
    }
    await new Promise((resolve) => setTimeout(resolve, 1_000));
  }
  return last;
}

function inspectAppendedRecords(content: string): {
  userAppended: boolean;
  assistantAppended: boolean;
} {
  let userAppended = false;
  let assistantAppended = false;
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line) as Record<string, unknown>;
      const serialized = JSON.stringify(event);
      if (event.type === "user" && serialized.includes(PROMPT)) {
        userAppended = true;
      }
      if (
        event.type === "assistant" &&
        /\bpong\b/i.test(collectStrings(event.message).join(" "))
      ) {
        assistantAppended = true;
      }
    } catch {
      // Ignore a partial final line while Claude is still appending.
    }
  }
  return { userAppended, assistantAppended };
}

function inspectCodexRecords(content: string): {
  userAppended: boolean;
  assistantAppended: boolean;
} {
  let userAppended = false;
  let assistantAppended = false;
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line) as Record<string, unknown>;
      const payload =
        typeof event.payload === "object" && event.payload !== null
          ? (event.payload as Record<string, unknown>)
          : {};
      const text = collectStrings(payload).join(" ");
      if (
        event.type === "event_msg" &&
        payload.type === "user_message" &&
        text.includes(PROMPT)
      ) {
        userAppended = true;
      }
      if (
        /\bpong\b/i.test(text) &&
        ((event.type === "event_msg" && payload.type === "agent_message") ||
          (event.type === "response_item" &&
            payload.type === "message" &&
            payload.role === "assistant"))
      ) {
        assistantAppended = true;
      }
    } catch {
      // Ignore a partial final line while Codex is still appending.
    }
  }
  return { userAppended, assistantAppended };
}

function collectStrings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(collectStrings);
  if (typeof value !== "object" || value === null) return [];
  return Object.values(value).flatMap(collectStrings);
}

void main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
