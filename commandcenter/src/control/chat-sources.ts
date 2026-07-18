import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";

import {
  CursorChatsProvider,
  type CursorChat,
  type CursorChatsOptions,
} from "./cursor-chats.js";

export type ChatSource = "cursor" | "claude" | "codex";

export interface ChatEntry {
  id: string;
  source: ChatSource;
  name: string;
  status: string;
  generating: boolean;
  lastUpdatedAt: number;
}

export interface ChatSourceProvider {
  start(): void;
  stop(): void;
  current(): ChatEntry[];
  subscribe(listener: (chats: ChatEntry[]) => void): () => void;
}

interface FileChatOptions {
  root?: string;
  pollMs?: number;
  windowMs?: number;
  activeMs?: number;
}

interface CachedFile {
  mtimeMs: number;
  entry: ChatEntry | null;
}

type SessionParser = (
  content: string,
  filePath: string,
  mtimeMs: number,
  nowMs?: number,
) => ChatEntry | null;

const DEFAULT_CURSOR_POLL_MS = 30_000;
const DEFAULT_FILE_POLL_MS = 10_000;
const DEFAULT_WINDOW_MS = 24 * 60 * 60 * 1_000;
/** A session file touched within this window counts as actively generating. */
const DEFAULT_ACTIVE_MS = 45_000;
/** Newest entries kept per source so one busy harness cannot crowd out the rest. */
const MAX_ENTRIES_PER_SOURCE = 10;

/**
 * Adapts the existing Cursor provider to the shared multi-source shape without
 * changing its SQLite query or polling behavior.
 */
export class CursorChatSourceProvider implements ChatSourceProvider {
  private readonly provider: CursorChatsProvider;

  constructor(options: CursorChatsOptions = {}) {
    this.provider = new CursorChatsProvider(options);
  }

  start(): void {
    this.provider.start();
  }

  stop(): void {
    this.provider.stop();
  }

  current(): ChatEntry[] {
    return this.provider.current().map(cursorEntry);
  }

  subscribe(listener: (chats: ChatEntry[]) => void): () => void {
    return this.provider.subscribe((chats) => listener(chats.map(cursorEntry)));
  }
}

/**
 * Polls a directory of JSONL session files (Claude Code / Codex CLI style),
 * parsing each recently-modified file once per mtime and deriving liveness
 * from how recently the file was written. Read-only against the store.
 */
class FileChatsProvider implements ChatSourceProvider {
  private readonly root: string;
  private readonly source: Exclude<ChatSource, "cursor">;
  private readonly maxDepth: number;
  private readonly parser: SessionParser;
  private readonly pollMs: number;
  private readonly windowMs: number;
  private readonly activeMs: number;
  private readonly listeners = new Set<(chats: ChatEntry[]) => void>();
  private readonly cache = new Map<string, CachedFile>();
  private chats: ChatEntry[] = [];
  private timer: NodeJS.Timeout | null = null;
  private polling = false;
  private lastSerialized = "";

  constructor(
    options: FileChatOptions & {
      root: string;
      source: Exclude<ChatSource, "cursor">;
      maxDepth: number;
      parser: SessionParser;
    },
  ) {
    this.root = options.root;
    this.source = options.source;
    this.maxDepth = options.maxDepth;
    this.parser = options.parser;
    this.pollMs = options.pollMs ?? DEFAULT_FILE_POLL_MS;
    this.windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
    this.activeMs = options.activeMs ?? DEFAULT_ACTIVE_MS;
  }

  start(): void {
    if (this.timer) return;
    void this.poll();
    this.timer = setInterval(() => void this.poll(), this.pollMs);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  current(): ChatEntry[] {
    return this.chats;
  }

  subscribe(listener: (chats: ChatEntry[]) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private async poll(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const nowMs = Date.now();
      const cutoff = nowMs - this.windowMs;
      const paths = await listSessionFiles(this.root, this.maxDepth);
      const recentPaths = new Set<string>();
      const fileStats = await Promise.all(
        paths.map(async (filePath) => {
          try {
            return { filePath, fileStat: await stat(filePath) };
          } catch {
            return null;
          }
        }),
      );

      for (const file of fileStats) {
        if (!file) continue;
        const { filePath, fileStat } = file;
        if (fileStat.mtimeMs < cutoff) continue;
        recentPaths.add(filePath);
        const cached = this.cache.get(filePath);
        if (cached?.mtimeMs === fileStat.mtimeMs) continue;

        let content: string;
        try {
          content = await readFile(filePath, "utf8");
        } catch {
          continue;
        }
        this.cache.set(filePath, {
          mtimeMs: fileStat.mtimeMs,
          entry: this.parser(content, filePath, fileStat.mtimeMs, nowMs),
        });
      }

      for (const filePath of this.cache.keys()) {
        if (!recentPaths.has(filePath)) this.cache.delete(filePath);
      }

      const chats = mergeChatEntries(
        [...this.cache.values()].flatMap(({ entry, mtimeMs }) => {
          if (!entry) return [];
          const generating = nowMs - mtimeMs <= this.activeMs;
          return [
            {
              ...entry,
              status: generating ? "none" : "completed",
              generating,
            },
          ];
        }),
      );
      const serialized = JSON.stringify(chats);
      if (serialized === this.lastSerialized) return;
      this.lastSerialized = serialized;
      this.chats = chats;
      for (const listener of this.listeners) listener(chats);
    } catch {
      // Session directories can disappear during rotation. Preserve the last
      // good snapshot and retry on the next inexpensive poll.
    } finally {
      this.polling = false;
    }
  }
}

/** ~/.claude/projects/<project-slug>/<session-uuid>.jsonl */
export class ClaudeChatsProvider
  extends FileChatsProvider
  implements ChatSourceProvider
{
  constructor(options: FileChatOptions = {}) {
    super({
      ...options,
      root: options.root ?? join(homedir(), ".claude/projects"),
      source: "claude",
      maxDepth: 2,
      parser: parseClaudeSession,
    });
  }
}

/** ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl */
export class CodexChatsProvider
  extends FileChatsProvider
  implements ChatSourceProvider
{
  constructor(options: FileChatOptions = {}) {
    super({
      ...options,
      root: options.root ?? join(homedir(), ".codex/sessions"),
      source: "codex",
      maxDepth: 4,
      parser: parseCodexSession,
    });
  }
}

export interface ChatSourcesOptions {
  /** Poll interval for the JSONL file scans (cheap). */
  filePollMs?: number;
  windowMs?: number;
  activeMs?: number;
  cursor?: CursorChatsOptions;
  claudeRoot?: string;
  codexRoot?: string;
  sources?: ChatSourceProvider[];
}

/** Polls all local chat stores and publishes one newest-first snapshot. */
export class ChatSourcesProvider {
  private readonly sources: ChatSourceProvider[];
  private readonly listeners = new Set<(chats: ChatEntry[]) => void>();
  private readonly unsubscribers: Array<() => void> = [];
  private chats: ChatEntry[] = [];
  private lastSerialized = "";
  private started = false;

  constructor(options: ChatSourcesOptions = {}) {
    const windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
    const activeMs = options.activeMs ?? DEFAULT_ACTIVE_MS;
    const filePollMs = options.filePollMs ?? DEFAULT_FILE_POLL_MS;
    this.sources =
      options.sources ??
      [
        new CursorChatSourceProvider({
          pollMs: DEFAULT_CURSOR_POLL_MS,
          ...options.cursor,
          windowSeconds: Math.floor(windowMs / 1_000),
        }),
        new ClaudeChatsProvider({
          root: options.claudeRoot,
          pollMs: filePollMs,
          windowMs,
          activeMs,
        }),
        new CodexChatsProvider({
          root: options.codexRoot,
          pollMs: filePollMs,
          windowMs,
          activeMs,
        }),
      ];
  }

  start(): void {
    if (this.started) return;
    this.started = true;
    for (const source of this.sources) {
      this.unsubscribers.push(source.subscribe(() => this.refresh()));
      source.start();
    }
    this.refresh();
  }

  stop(): void {
    for (const unsubscribe of this.unsubscribers.splice(0)) unsubscribe();
    for (const source of this.sources) source.stop();
    this.started = false;
  }

  current(): ChatEntry[] {
    return this.chats;
  }

  subscribe(listener: (chats: ChatEntry[]) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private refresh(): void {
    const chats = capPerSource(
      mergeChatEntries(this.sources.flatMap((source) => source.current())),
    );
    const serialized = JSON.stringify(chats);
    if (serialized === this.lastSerialized) return;
    this.lastSerialized = serialized;
    this.chats = chats;
    for (const listener of this.listeners) listener(chats);
  }
}

export function mergeChatEntries(entries: ChatEntry[]): ChatEntry[] {
  return [...entries].sort(
    (left, right) =>
      right.lastUpdatedAt - left.lastUpdatedAt ||
      left.source.localeCompare(right.source) ||
      left.id.localeCompare(right.id),
  );
}

export function capPerSource(
  sorted: ChatEntry[],
  limit = MAX_ENTRIES_PER_SOURCE,
): ChatEntry[] {
  const seen = new Map<ChatSource, number>();
  return sorted.filter((entry) => {
    const count = seen.get(entry.source) ?? 0;
    if (count >= limit) return false;
    seen.set(entry.source, count + 1);
    return true;
  });
}

export function parseClaudeSession(
  content: string,
  filePath: string,
  mtimeMs: number,
  nowMs = Date.now(),
): ChatEntry | null {
  let sessionId = basename(filePath, ".jsonl");
  let title: string | null = null;
  let firstUserMessage: string | null = null;

  for (const event of parseJsonLines(content)) {
    sessionId = stringValue(event.sessionId) ?? sessionId;
    if (event.type === "summary") {
      title =
        stringValue(event.summary) ??
        stringValue(event.title) ??
        humanText(event.content) ??
        title;
    } else if (event.type === "ai-title") {
      title = stringValue(event.aiTitle) ?? title;
    }
    if (!firstUserMessage && event.type === "user") {
      const message = recordValue(event.message);
      if (message?.role === "user") {
        firstUserMessage = humanText(message.content);
      }
    }
  }

  const name = cleanTitle(title) ?? fallbackTitle(firstUserMessage);
  if (!name) return null;
  return fileEntry("claude", sessionId, name, mtimeMs, nowMs);
}

export function parseCodexSession(
  content: string,
  filePath: string,
  mtimeMs: number,
  nowMs = Date.now(),
): ChatEntry | null {
  let sessionId = rolloutId(filePath);
  let title: string | null = null;
  let firstUserMessage: string | null = null;

  for (const event of parseJsonLines(content)) {
    const payload = recordValue(event.payload);
    if (event.type === "session_meta" && payload) {
      sessionId =
        stringValue(payload.session_id) ??
        stringValue(payload.id) ??
        sessionId;
      title = stringValue(payload.title) ?? stringValue(payload.name) ?? title;
    }
    if (
      !firstUserMessage &&
      event.type === "event_msg" &&
      payload?.type === "user_message"
    ) {
      firstUserMessage = humanText(payload.message);
    }
  }

  const name = cleanTitle(title) ?? fallbackTitle(firstUserMessage);
  if (!name) return null;
  return fileEntry("codex", sessionId, name, mtimeMs, nowMs);
}

async function listSessionFiles(
  root: string,
  maxDepth: number,
): Promise<string[]> {
  const files: string[] = [];

  async function walk(directory: string, depth: number): Promise<void> {
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch (error) {
      if (isMissing(error)) return;
      throw error;
    }
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < maxDepth) {
        await walk(path, depth + 1);
      } else if (
        entry.isFile() &&
        depth === maxDepth &&
        entry.name.endsWith(".jsonl")
      ) {
        files.push(path);
      }
    }
  }

  await walk(root, 1);
  return files;
}

function cursorEntry(chat: CursorChat): ChatEntry {
  return {
    ...chat,
    id: `cursor:${chat.id}`,
    source: "cursor",
  };
}

function fileEntry(
  source: Exclude<ChatSource, "cursor">,
  sessionId: string,
  name: string,
  mtimeMs: number,
  nowMs: number,
): ChatEntry {
  const generating = nowMs - mtimeMs <= DEFAULT_ACTIVE_MS;
  return {
    id: `${source}:${sessionId}`,
    source,
    name,
    status: generating ? "none" : "completed",
    generating,
    lastUpdatedAt: mtimeMs,
  };
}

function parseJsonLines(content: string): Array<Record<string, unknown>> {
  const events: Array<Record<string, unknown>> = [];
  for (const line of content.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const event = JSON.parse(line) as unknown;
      const record = recordValue(event);
      if (record) events.push(record);
    } catch {
      // A session may be read while its final JSONL line is still being
      // written. Earlier complete events remain usable.
    }
  }
  return events;
}

/**
 * Extracts user-visible text, skipping harness-injected content such as
 * "<local-command-caveat>" or "<recommended_plugins>" blocks.
 */
function humanText(value: unknown): string | null {
  const text = textValue(value);
  if (!text) return null;
  return text.trimStart().startsWith("<") ? null : text;
}

function textValue(value: unknown): string | null {
  if (typeof value === "string") return value;
  if (!Array.isArray(value)) return null;
  const text = value
    .flatMap((part) => {
      const record = recordValue(part);
      return record && typeof record.text === "string" ? [record.text] : [];
    })
    .join(" ");
  return text || null;
}

function cleanTitle(value: string | null): string | null {
  const cleaned = value?.replace(/\s+/g, " ").trim();
  return cleaned || null;
}

function fallbackTitle(value: string | null): string | null {
  const cleaned = cleanTitle(value);
  if (!cleaned) return null;
  return cleaned.length <= 60 ? cleaned : `${cleaned.slice(0, 57)}...`;
}

function rolloutId(filePath: string): string {
  const fileName = basename(filePath, ".jsonl");
  const match = fileName.match(
    /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i,
  );
  return match?.[1] ?? fileName;
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function isMissing(error: unknown): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: string }).code === "ENOENT"
  );
}
