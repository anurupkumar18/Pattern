import { execFile } from "node:child_process";
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import type { ChatSource } from "./chat-sources.js";

export interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt?: string;
  extras?: ChatMessageExtra[];
}

export type ChatMessageExtra =
  | { kind: "thinking"; text: string }
  | { kind: "activity"; label: string };

export interface ChatMessagesResult {
  source: ChatSource;
  chatId: string;
  messages: ChatMessage[];
  updatedAt: string;
  /** Internal response-dedupe token. Never sent to clients. */
  fingerprint: string;
}

export interface ChatMessagesRequest {
  type: "chat.messages.request";
  source: ChatSource;
  chatId: string;
}

export type ChatMessagesErrorCode = "not_found" | "parse_error" | "invalid_id";

export class ChatMessagesError extends Error {
  constructor(
    public readonly code: ChatMessagesErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "ChatMessagesError";
  }
}

export interface CursorBubbleRow {
  ordinal: number;
  bubbleId: string;
  type: number;
  createdAt?: string | null;
  text?: string | null;
  richText?: string | null;
  thinking?: unknown;
  toolFormerData?: unknown;
  hidden?: number;
}

interface CachedMessages {
  version: string;
  result: ChatMessagesResult;
}

interface ChatMessagesOptions {
  cursorDatabasePath?: string;
  claudeRoot?: string;
  codexRoot?: string;
  sqliteBin?: string;
}

interface JsonLine {
  event: Record<string, unknown>;
  lineIndex: number;
}

interface MessageCandidate extends ChatMessage {
  lineIndex: number;
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CURSOR_MESSAGES_QUERY = `
WITH composer AS (
  SELECT value
  FROM cursorDiskKV
  WHERE key = 'composerData:' || @composer_id
),
headers AS (
  SELECT
    CAST(header.key AS INTEGER) AS ordinal,
    json_extract(header.value, '$.bubbleId') AS bubbleId,
    json_extract(header.value, '$.type') AS type,
    json_extract(header.value, '$.createdAt') AS headerCreatedAt,
    json_extract(header.value, '$.grouping.isRenderable') AS renderable,
    json_extract(header.value, '$.grouping.isSimulatedMsg') AS simulated
  FROM composer,
       json_each(json_extract(composer.value, '$.fullConversationHeadersOnly')) AS header
)
SELECT
  headers.ordinal,
  headers.bubbleId,
  headers.type,
  coalesce(json_extract(bubble.value, '$.createdAt'), headers.headerCreatedAt) AS createdAt,
  json_extract(bubble.value, '$.text') AS text,
  json_extract(bubble.value, '$.richText') AS richText,
  json_extract(bubble.value, '$.thinking') AS thinking,
  json_extract(bubble.value, '$.toolFormerData') AS toolFormerData,
  CASE
    WHEN json_type(bubble.value, '$.thinking') IS NOT NULL
      OR json_type(bubble.value, '$.toolFormerData') IS NOT NULL
    THEN 1 ELSE 0
  END AS hidden
FROM headers
JOIN cursorDiskKV AS bubble
  ON bubble.key = 'bubbleId:' || @composer_id || ':' || headers.bubbleId
WHERE headers.type IN (1, 2)
  AND coalesce(headers.renderable, 1) != 0
  AND coalesce(headers.simulated, 0) = 0
  AND (
    trim(coalesce(
      json_extract(bubble.value, '$.text'),
      json_extract(bubble.value, '$.richText'),
      ''
    )) != ''
    OR json_type(bubble.value, '$.thinking') IS NOT NULL
    OR json_type(bubble.value, '$.toolFormerData') IS NOT NULL
  )
ORDER BY headers.ordinal
`;

/**
 * Reads one selected local conversation. File readers cache by mtime/size;
 * Cursor caches by both the database and WAL state. No source is ever opened
 * for writing.
 */
export class ChatMessagesService {
  private readonly cursorDatabasePath: string;
  private readonly claudeRoot: string;
  private readonly codexRoot: string;
  private readonly sqliteBin: string;
  private readonly cache = new Map<string, CachedMessages>();
  private readonly resolvedPaths = new Map<string, string>();
  private readonly inflight = new Map<string, Promise<ChatMessagesResult>>();

  constructor(options: ChatMessagesOptions = {}) {
    this.cursorDatabasePath =
      options.cursorDatabasePath ??
      process.env.CURSOR_STATE_DB ??
      join(
        homedir(),
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
      );
    this.claudeRoot = options.claudeRoot ?? join(homedir(), ".claude/projects");
    this.codexRoot = options.codexRoot ?? join(homedir(), ".codex/sessions");
    this.sqliteBin = options.sqliteBin ?? "sqlite3";
  }

  async read(source: ChatSource, chatId: string): Promise<ChatMessagesResult> {
    const sessionId = validatedSessionId(source, chatId);
    const cacheKey = `${source}:${sessionId}`;
    const existing = this.inflight.get(cacheKey);
    if (existing) return existing;
    const request =
      source === "cursor"
        ? this.readCursor(chatId, sessionId)
        : this.readFileSession(source, chatId, sessionId);
    this.inflight.set(cacheKey, request);
    void request.then(
      () => this.inflight.delete(cacheKey),
      () => this.inflight.delete(cacheKey),
    );
    return request;
  }

  private async readCursor(
    chatId: string,
    composerId: string,
  ): Promise<ChatMessagesResult> {
    const version = await queryCursorComposerVersion(
      this.sqliteBin,
      this.cursorDatabasePath,
      composerId,
    );
    const cacheKey = `cursor:${composerId}`;
    const cached = this.cache.get(cacheKey);
    if (cached?.version === version) return cached.result;

    const rows = await queryCursorRows(
      this.sqliteBin,
      this.cursorDatabasePath,
      composerId,
    );
    const messages = parseCursorBubbleRows(rows);
    const result = makeResult(
      "cursor",
      chatId,
      messages,
      new Date(Number(version)).toISOString(),
    );
    this.cache.set(cacheKey, { version, result });
    return result;
  }

  private async readFileSession(
    source: Exclude<ChatSource, "cursor">,
    chatId: string,
    sessionId: string,
  ): Promise<ChatMessagesResult> {
    const cacheKey = `${source}:${sessionId}`;
    let filePath: string | null | undefined = this.resolvedPaths.get(cacheKey);
    if (!filePath) {
      filePath = await resolveSessionPath(
        source === "claude" ? this.claudeRoot : this.codexRoot,
        source === "claude" ? 2 : 4,
        sessionId,
        source === "codex",
      );
      if (!filePath) {
        throw new ChatMessagesError(
          "not_found",
          `This ${sourceLabel(source)} session is no longer available locally.`,
        );
      }
      this.resolvedPaths.set(cacheKey, filePath);
    }

    let fileStat;
    try {
      fileStat = await stat(filePath);
    } catch {
      throw new ChatMessagesError(
        "not_found",
        `This ${sourceLabel(source)} session is no longer available locally.`,
      );
    }
    const version = `${fileStat.mtimeMs}:${fileStat.size}`;
    const cached = this.cache.get(cacheKey);
    if (cached?.version === version) return cached.result;

    let content: string;
    try {
      content = await readFile(filePath, "utf8");
    } catch {
      throw new ChatMessagesError(
        "not_found",
        `This ${sourceLabel(source)} session could not be read locally.`,
      );
    }

    let messages: ChatMessage[];
    try {
      messages =
        source === "claude"
          ? parseClaudeMessages(content)
          : parseCodexMessages(content);
    } catch (error) {
      if (error instanceof ChatMessagesError) throw error;
      throw new ChatMessagesError(
        "parse_error",
        `This ${sourceLabel(source)} session could not be parsed locally.`,
      );
    }
    const result = makeResult(
      source,
      chatId,
      messages,
      new Date(fileStat.mtimeMs).toISOString(),
    );
    this.cache.set(cacheKey, { version, result });
    return result;
  }
}

export function parseChatMessagesRequest(
  value: unknown,
): ChatMessagesRequest | null {
  const record = recordValue(value);
  if (record?.type !== "chat.messages.request") return null;
  if (
    record.source !== "cursor" &&
    record.source !== "claude" &&
    record.source !== "codex"
  ) {
    return null;
  }
  if (typeof record.chatId !== "string") return null;
  validatedSessionId(record.source, record.chatId);
  return {
    type: "chat.messages.request",
    source: record.source,
    chatId: record.chatId,
  };
}

export function parseCursorBubbleRows(rows: CursorBubbleRow[]): ChatMessage[] {
  const candidates: MessageCandidate[] = [];
  let pendingExtras: ChatMessageExtra[] = [];
  for (const row of [...rows].sort(
    (left, right) => left.ordinal - right.ordinal,
  )) {
    if (row.type !== 1 && row.type !== 2) continue;
    const extras = cursorExtras(row);
    if (row.hidden === 1 && extras.length === 0) continue;
    const text =
      visibleText(row.text) ?? flattenCursorRichText(row.richText) ?? null;
    if (!text) {
      if (row.type === 2) pendingExtras = mergeExtras(pendingExtras, extras);
      continue;
    }
    const messageExtras =
      row.type === 2 ? mergeExtras(pendingExtras, extras) : extras;
    if (row.type === 2) pendingExtras = [];
    candidates.push({
      id: row.bubbleId,
      role: row.type === 1 ? "user" : "assistant",
      text,
      createdAt: isoTimestamp(row.createdAt),
      extras: messageExtras.length > 0 ? messageExtras : undefined,
      lineIndex: row.ordinal,
    });
  }
  attachTrailingExtras(candidates, pendingExtras);
  return dedupeMessages(candidates);
}

export function parseClaudeMessages(content: string): ChatMessage[] {
  const candidates: MessageCandidate[] = [];
  let pendingExtras: ChatMessageExtra[] = [];
  for (const { event, lineIndex } of parseJsonLinesStrict(content)) {
    if (
      (event.type !== "user" && event.type !== "assistant") ||
      event.isSidechain === true ||
      event.isMeta === true
    ) {
      continue;
    }
    if (
      event.type === "user" &&
      (event.sourceToolAssistantUUID !== undefined ||
        event.toolUseResult !== undefined)
    ) {
      continue;
    }
    const message = recordValue(event.message);
    if (!message || message.role !== event.type) continue;
    const extras =
      event.type === "assistant" ? claudeExtras(message.content) : [];
    const text = visibleContent(message.content, "claude");
    if (!text) {
      if (event.type === "assistant") {
        pendingExtras = mergeExtras(pendingExtras, extras);
      }
      continue;
    }
    const messageExtras =
      event.type === "assistant"
        ? mergeExtras(pendingExtras, extras)
        : undefined;
    if (event.type === "assistant") pendingExtras = [];
    candidates.push({
      id: stringValue(event.uuid) ?? `claude-line-${lineIndex}`,
      role: event.type,
      text,
      createdAt: isoTimestamp(event.timestamp),
      extras: messageExtras?.length ? messageExtras : undefined,
      lineIndex,
    });
  }
  attachTrailingExtras(candidates, pendingExtras);
  return dedupeMessages(candidates);
}

export function parseCodexMessages(content: string): ChatMessage[] {
  const eventCandidates: MessageCandidate[] = [];
  const responseCandidates: MessageCandidate[] = [];
  let pendingExtras: ChatMessageExtra[] = [];

  for (const { event, lineIndex } of parseJsonLinesStrict(content)) {
    const payload = recordValue(event.payload);
    if (!payload) continue;
    if (event.type === "event_msg") {
      if (payload.type === "agent_reasoning") {
        const text =
          visibleText(payload.text) ?? visibleText(payload.message) ?? null;
        if (text) {
          pendingExtras = mergeExtras(pendingExtras, [
            { kind: "thinking", text },
          ]);
        }
        continue;
      }
      const eventActivity = codexActivity(payload);
      if (eventActivity) {
        pendingExtras = mergeExtras(pendingExtras, [eventActivity]);
        continue;
      }
      const role =
        payload.type === "user_message"
          ? "user"
          : payload.type === "agent_message"
            ? "assistant"
            : null;
      if (!role) continue;
      const text = visibleText(payload.message);
      if (!text) continue;
      eventCandidates.push({
        id: `codex-event-${lineIndex}`,
        role,
        text,
        createdAt: isoTimestamp(event.timestamp),
        extras:
          role === "assistant" && pendingExtras.length > 0
            ? pendingExtras
            : undefined,
        lineIndex,
      });
      if (role === "assistant") pendingExtras = [];
      continue;
    }
    if (event.type === "response_item" && payload.type === "reasoning") {
      const text = codexReasoningText(payload);
      if (text) {
        pendingExtras = mergeExtras(pendingExtras, [
          { kind: "thinking", text },
        ]);
      }
      continue;
    }
    if (event.type === "response_item") {
      const activity = codexActivity(payload);
      if (activity) {
        pendingExtras = mergeExtras(pendingExtras, [activity]);
        continue;
      }
    }
    if (
      event.type !== "response_item" ||
      payload.type !== "message" ||
      (payload.role !== "user" && payload.role !== "assistant")
    ) {
      continue;
    }
    const text = visibleContent(payload.content, "codex");
    if (!text) continue;
    responseCandidates.push({
      id: stringValue(payload.id) ?? `codex-response-${lineIndex}`,
      role: payload.role,
      text,
      createdAt: isoTimestamp(event.timestamp),
      extras:
        payload.role === "assistant" && pendingExtras.length > 0
          ? pendingExtras
          : undefined,
      lineIndex,
    });
    if (payload.role === "assistant") pendingExtras = [];
  }

  // Modern Codex emits a visible event_msg and a lower-level response_item for
  // the same content. Prefer the UI event lane per role, with response_item as
  // a compatibility fallback for older or partial session schemas.
  const selected = (["user", "assistant"] as const).flatMap((role) => {
    const visibleEvents = eventCandidates.filter(
      (candidate) => candidate.role === role,
    );
    return visibleEvents.length > 0
      ? visibleEvents
      : responseCandidates.filter((candidate) => candidate.role === role);
  });
  selected.sort((left, right) => left.lineIndex - right.lineIndex);
  attachTrailingExtras(selected, pendingExtras);
  return dedupeMessages(selected);
}

function parseJsonLinesStrict(content: string): JsonLine[] {
  const lines = content.split(/\r?\n/);
  let lastNonempty = -1;
  for (let index = lines.length - 1; index >= 0; index -= 1) {
    if (lines[index]?.trim()) {
      lastNonempty = index;
      break;
    }
  }
  const parsed: JsonLine[] = [];
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex += 1) {
    const line = lines[lineIndex];
    if (!line?.trim()) continue;
    try {
      const event = recordValue(JSON.parse(line) as unknown);
      if (event) parsed.push({ event, lineIndex });
    } catch {
      // A live writer can leave only the final line incomplete.
      if (lineIndex === lastNonempty && parsed.length > 0) continue;
      throw new ChatMessagesError(
        "parse_error",
        "The local session file contains invalid JSONL.",
      );
    }
  }
  return parsed;
}

function visibleContent(
  value: unknown,
  source: "claude" | "codex",
): string | null {
  if (typeof value === "string") return visibleText(value);
  if (!Array.isArray(value)) return null;
  const allowedType = source === "claude" ? "text" : undefined;
  const parts = value.flatMap((part): string[] => {
    const block = recordValue(part);
    if (!block) return [];
    const visibleBlock =
      source === "claude"
        ? block.type === allowedType
        : block.type === "input_text" || block.type === "output_text";
    if (!visibleBlock) return [];
    const text = visibleText(block.text);
    return text ? [text] : [];
  });
  return parts.length > 0 ? parts.join("\n\n") : null;
}

function visibleText(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const text = value.trim();
  if (!text || text.startsWith("<")) return null;
  return text;
}

function cursorExtras(row: CursorBubbleRow): ChatMessageExtra[] {
  const extras: ChatMessageExtra[] = [];
  const thinking = nestedText(row.thinking, ["text", "thinking", "content"]);
  if (thinking) extras.push({ kind: "thinking", text: thinking });
  if (row.toolFormerData !== null && row.toolFormerData !== undefined) {
    const name = nestedString(row.toolFormerData, [
      "name",
      "toolName",
      "tool_name",
    ]);
    extras.push({
      kind: "activity",
      label: name ? activityLabel(name) : "Used a tool",
    });
  }
  return mergeExtras([], extras);
}

function claudeExtras(value: unknown): ChatMessageExtra[] {
  if (!Array.isArray(value)) return [];
  const extras: ChatMessageExtra[] = [];
  for (const item of value) {
    const block = recordValue(item);
    if (!block) continue;
    if (block.type === "thinking") {
      const text =
        visibleText(block.thinking) ?? visibleText(block.text) ?? null;
      if (text) extras.push({ kind: "thinking", text });
    } else if (block.type === "tool_use") {
      const name = stringValue(block.name);
      extras.push({
        kind: "activity",
        label: name ? activityLabel(name) : "Used a tool",
      });
    }
  }
  return mergeExtras([], extras);
}

function codexReasoningText(payload: Record<string, unknown>): string | null {
  const direct =
    visibleText(payload.text) ?? visibleText(payload.message) ?? null;
  if (direct) return direct;
  if (!Array.isArray(payload.summary)) return null;
  const parts = payload.summary.flatMap((item): string[] => {
    const summary = recordValue(item);
    const text = summary ? visibleText(summary.text) : null;
    return text ? [text] : [];
  });
  return parts.length > 0 ? parts.join("\n\n") : null;
}

function codexActivity(
  payload: Record<string, unknown>,
): Extract<ChatMessageExtra, { kind: "activity" }> | null {
  if (
    payload.type !== "function_call" &&
    payload.type !== "custom_tool_call" &&
    payload.type !== "web_search_call" &&
    payload.type !== "computer_call" &&
    payload.type !== "tool_call"
  ) {
    return null;
  }
  if (payload.type === "web_search_call") {
    return { kind: "activity", label: "Searched the web" };
  }
  const name = stringValue(payload.name);
  return {
    kind: "activity",
    label: name ? activityLabel(name) : "Used a tool",
  };
}

function activityLabel(name: string): string {
  const safeName = name
    .replace(/[_-]+/g, " ")
    .replace(/[^\p{L}\p{N} .:/]/gu, "")
    .trim()
    .slice(0, 80);
  if (!safeName) return "Used a tool";
  return /\b(search|find|query|browse)\b/i.test(safeName)
    ? `Searched with ${safeName}`
    : `Used ${safeName}`;
}

function nestedText(value: unknown, keys: string[]): string | null {
  if (typeof value === "string") {
    const direct = visibleText(value);
    if (!direct) return null;
    try {
      return nestedText(JSON.parse(direct) as unknown, keys) ?? direct;
    } catch {
      return direct;
    }
  }
  if (Array.isArray(value)) {
    const parts = value.flatMap((item): string[] => {
      const text = nestedText(item, keys);
      return text ? [text] : [];
    });
    return parts.length > 0 ? parts.join("\n\n") : null;
  }
  const record = recordValue(value);
  if (!record) return null;
  for (const key of keys) {
    const direct = visibleText(record[key]);
    if (direct) return direct;
  }
  for (const child of Object.values(record)) {
    const text = nestedText(child, keys);
    if (text) return text;
  }
  return null;
}

function nestedString(value: unknown, keys: string[]): string | null {
  if (typeof value === "string") {
    try {
      return nestedString(JSON.parse(value) as unknown, keys);
    } catch {
      return null;
    }
  }
  if (Array.isArray(value)) {
    for (const child of value) {
      const match = nestedString(child, keys);
      if (match) return match;
    }
    return null;
  }
  const record = recordValue(value);
  if (!record) return null;
  for (const key of keys) {
    const match = stringValue(record[key]);
    if (match) return match;
  }
  for (const child of Object.values(record)) {
    const match = nestedString(child, keys);
    if (match) return match;
  }
  return null;
}

function mergeExtras(
  left: ChatMessageExtra[],
  right: ChatMessageExtra[],
): ChatMessageExtra[] {
  const seen = new Set(left.map(extraKey));
  const merged = [...left];
  for (const extra of right) {
    const key = extraKey(extra);
    if (seen.has(key)) continue;
    seen.add(key);
    merged.push(extra);
  }
  return merged;
}

function extraKey(extra: ChatMessageExtra): string {
  return extra.kind === "thinking"
    ? `thinking:${extra.text}`
    : `activity:${extra.label}`;
}

function attachTrailingExtras(
  candidates: MessageCandidate[],
  extras: ChatMessageExtra[],
): void {
  if (extras.length === 0) return;
  for (let index = candidates.length - 1; index >= 0; index -= 1) {
    const candidate = candidates[index];
    if (candidate?.role !== "assistant") continue;
    candidate.extras = mergeExtras(candidate.extras ?? [], extras);
    return;
  }
}

function flattenCursorRichText(value: string | null | undefined): string | null {
  const text = visibleText(value);
  if (!text) return null;
  try {
    const parsed = JSON.parse(text) as unknown;
    const parts: string[] = [];
    collectVisibleRichText(parsed, parts);
    return parts.length > 0 ? parts.join("\n").trim() || null : null;
  } catch {
    return text;
  }
}

function collectVisibleRichText(value: unknown, parts: string[]): void {
  if (Array.isArray(value)) {
    for (const item of value) collectVisibleRichText(item, parts);
    return;
  }
  const record = recordValue(value);
  if (!record) return;
  if (
    record.type === "thinking" ||
    record.type === "tool_use" ||
    record.type === "tool_result"
  ) {
    return;
  }
  if (record.type === "text" && typeof record.text === "string") {
    const text = visibleText(record.text);
    if (text) parts.push(text);
  }
  for (const [key, child] of Object.entries(record)) {
    if (key !== "text" && key !== "type") collectVisibleRichText(child, parts);
  }
}

function dedupeMessages(candidates: MessageCandidate[]): ChatMessage[] {
  const seenIds = new Set<string>();
  const seenContent = new Set<string>();
  const messages: ChatMessage[] = [];
  for (const candidate of candidates) {
    const contentKey = `${candidate.role}\u0000${candidate.createdAt ?? ""}\u0000${candidate.text}\u0000${JSON.stringify(candidate.extras ?? [])}`;
    if (seenIds.has(candidate.id) || seenContent.has(contentKey)) continue;
    seenIds.add(candidate.id);
    seenContent.add(contentKey);
    const { lineIndex: _lineIndex, ...message } = candidate;
    messages.push(message);
  }
  return messages;
}

function makeResult(
  source: ChatSource,
  chatId: string,
  messages: ChatMessage[],
  updatedAt: string,
): ChatMessagesResult {
  return {
    source,
    chatId,
    messages,
    updatedAt,
    fingerprint: JSON.stringify(messages),
  };
}

async function queryCursorRows(
  sqliteBin: string,
  databasePath: string,
  composerId: string,
): Promise<CursorBubbleRow[]> {
  const uri = `file:${databasePath}?mode=ro`;
  const output = await new Promise<string>((resolvePromise, rejectPromise) => {
    execFile(
      sqliteBin,
      [
        "-json",
        "-readonly",
        "-cmd",
        ".parameter init",
        "-cmd",
        `.parameter set @composer_id '${composerId}'`,
        uri,
        CURSOR_MESSAGES_QUERY,
      ],
      { timeout: 15_000, maxBuffer: 32 * 1024 * 1024 },
      (error, stdout) => {
        if (error) {
          rejectPromise(error);
          return;
        }
        resolvePromise(stdout);
      },
    );
  }).catch(() => {
    throw new ChatMessagesError(
      "not_found",
      "The local Cursor conversation store could not be read.",
    );
  });
  const trimmed = output.trim();
  if (!trimmed) return [];
  try {
    return JSON.parse(trimmed) as CursorBubbleRow[];
  } catch {
    throw new ChatMessagesError(
      "parse_error",
      "The local Cursor conversation could not be parsed.",
    );
  }
}

async function queryCursorComposerVersion(
  sqliteBin: string,
  databasePath: string,
  composerId: string,
): Promise<string> {
  const uri = `file:${databasePath}?mode=ro`;
  const output = await new Promise<string>((resolvePromise, rejectPromise) => {
    execFile(
      sqliteBin,
      [
        "-noheader",
        "-readonly",
        "-cmd",
        ".parameter init",
        "-cmd",
        `.parameter set @composer_id '${composerId}'`,
        uri,
        `SELECT json_extract(value, '$.lastUpdatedAt')
         FROM cursorDiskKV
         WHERE key = 'composerData:' || @composer_id`,
      ],
      { timeout: 5_000, maxBuffer: 64 * 1_024 },
      (error, stdout) => {
        if (error) {
          rejectPromise(error);
          return;
        }
        resolvePromise(stdout.trim());
      },
    );
  }).catch(() => {
    throw new ChatMessagesError(
      "not_found",
      "The local Cursor conversation store could not be read.",
    );
  });
  if (!output || !Number.isFinite(Number(output))) {
    throw new ChatMessagesError(
      "not_found",
      "This Cursor conversation is no longer available locally.",
    );
  }
  return output;
}

async function resolveSessionPath(
  root: string,
  maxDepth: number,
  sessionId: string,
  codexRollout: boolean,
): Promise<string | null> {
  const expectedName = codexRollout ? null : `${sessionId}.jsonl`;
  let match: string | null = null;

  async function walk(directory: string, depth: number): Promise<void> {
    if (match) return;
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const path = join(directory, entry.name);
      if (entry.isDirectory() && depth < maxDepth) {
        await walk(path, depth + 1);
      } else if (
        entry.isFile() &&
        depth === maxDepth &&
        (entry.name === expectedName ||
          (codexRollout &&
            entry.name.startsWith("rollout-") &&
            entry.name.endsWith(`${sessionId}.jsonl`)))
      ) {
        match = path;
        return;
      }
    }
  }

  await walk(root, 1);
  return match;
}

function validatedSessionId(source: ChatSource, chatId: string): string {
  const prefix = `${source}:`;
  const sessionId = chatId.startsWith(prefix) ? chatId.slice(prefix.length) : chatId;
  if (!UUID_RE.test(sessionId)) {
    throw new ChatMessagesError(
      "invalid_id",
      "The requested local conversation ID is invalid.",
    );
  }
  return sessionId;
}

function isoTimestamp(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) ? new Date(timestamp).toISOString() : undefined;
}

function recordValue(value: unknown): Record<string, unknown> | null {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function stringValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value : null;
}

function sourceLabel(source: Exclude<ChatSource, "cursor">): string {
  return source === "claude" ? "Claude Code" : "Codex";
}
