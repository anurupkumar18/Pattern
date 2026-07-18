import { execFile } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";

/** A Cursor IDE chat (composer) read from Cursor's local state database. */
export interface CursorChat {
  id: string;
  name: string;
  /** Raw Cursor status: "completed" | "aborted" | "none". */
  status: string;
  /** True while the chat has an in-flight generation. */
  generating: boolean;
  /** Generic user-visible progress derived without exposing hidden reasoning. */
  activity?: string;
  /** First visible user turn, used for title fallback and classification. */
  firstUserMessage?: string;
  /** Cursor marks subcomposers separately when they run without direct UI input. */
  headless: boolean;
  lastUpdatedAt: number;
}

export interface CursorChatsOptions {
  /** Path to Cursor's global state.vscdb. Defaults to the macOS location. */
  databasePath?: string;
  /** Poll interval in milliseconds. Defaults to 30s (the query scans a ~2GB db). */
  pollMs?: number;
  /** Lookback window in seconds. Defaults to 24h. */
  windowSeconds?: number;
  /** sqlite3 binary. Defaults to the system sqlite3. */
  sqliteBin?: string;
}

const QUERY = `
WITH composers AS (
  SELECT
    substr(key, 14) AS id,
    value
  FROM cursorDiskKV
  WHERE key >= 'composerData:'
    AND key < 'composerData;'
    AND json_extract(value, '$.lastUpdatedAt') >= (strftime('%s','now') - :window) * 1000
)
SELECT
  composer.id,
  json_extract(composer.value, '$.name') AS name,
  json_extract(composer.value, '$.status') AS status,
  json_extract(composer.value, '$.lastUpdatedAt') AS lastUpdatedAt,
  CASE
    WHEN json_array_length(json_extract(composer.value, '$.generatingBubbleIds')) > 0
    THEN 1 ELSE 0
  END AS generating,
  (
    SELECT json_group_array(candidate.message)
    FROM (
      SELECT trim(coalesce(
        json_extract(bubble.value, '$.text'),
        json_extract(bubble.value, '$.richText'),
        ''
      )) AS message
      FROM json_each(
        json_extract(composer.value, '$.fullConversationHeadersOnly')
      ) AS header
      JOIN cursorDiskKV AS bubble
        ON bubble.key =
          'bubbleId:' || composer.id || ':' ||
          json_extract(header.value, '$.bubbleId')
      WHERE json_extract(header.value, '$.type') = 1
        AND coalesce(
          json_extract(header.value, '$.grouping.isRenderable'),
          1
        ) != 0
        AND coalesce(
          json_extract(header.value, '$.grouping.isSimulatedMsg'),
          0
        ) = 0
        AND trim(coalesce(
          json_extract(bubble.value, '$.text'),
          json_extract(bubble.value, '$.richText'),
          ''
        )) != ''
      ORDER BY CAST(header.key AS INTEGER)
      LIMIT 8
    ) AS candidate
  ) AS userMessages,
  CASE
    WHEN json_type(composer.value, '$.subagentInfo') IS NOT NULL
      OR coalesce(json_extract(composer.value, '$.isBestOfNSubcomposer'), 0) != 0
      OR coalesce(json_extract(composer.value, '$.isSpecSubagentDone'), 0) != 0
    THEN 1 ELSE 0
  END AS headless,
  CASE
    WHEN json_array_length(
      json_extract(composer.value, '$.generatingBubbleIds')
    ) = 0
    THEN NULL
    WHEN EXISTS (
      SELECT 1
      FROM json_each(
        json_extract(composer.value, '$.generatingBubbleIds')
      ) AS generated
      JOIN cursorDiskKV AS bubble
        ON bubble.key =
          'bubbleId:' || composer.id || ':' || generated.value
      WHERE json_type(bubble.value, '$.toolFormerData') IS NOT NULL
    )
    THEN 'Running tools'
    WHEN EXISTS (
      SELECT 1
      FROM json_each(
        json_extract(composer.value, '$.generatingBubbleIds')
      ) AS generated
      JOIN cursorDiskKV AS bubble
        ON bubble.key =
          'bubbleId:' || composer.id || ':' || generated.value
      WHERE json_type(bubble.value, '$.thinking') IS NOT NULL
    )
    THEN 'Thinking'
    WHEN EXISTS (
      SELECT 1
      FROM json_each(
        json_extract(composer.value, '$.generatingBubbleIds')
      ) AS generated
      JOIN cursorDiskKV AS bubble
        ON bubble.key =
          'bubbleId:' || composer.id || ':' || generated.value
      WHERE trim(coalesce(
        json_extract(bubble.value, '$.text'),
        json_extract(bubble.value, '$.richText'),
        ''
      )) != ''
    )
    THEN 'Responding'
    ELSE 'Working…'
  END AS activity
FROM composers AS composer
ORDER BY lastUpdatedAt DESC
`;

/**
 * Polls Cursor's local state database for chats updated inside the lookback
 * window. Read-only: opens the db with mode=ro so the running IDE is never
 * blocked. The query is executed in a sqlite3 child process because the db
 * is large and json_extract over it takes seconds.
 */
export class CursorChatsProvider {
  private readonly databasePath: string;
  private readonly pollMs: number;
  private readonly windowSeconds: number;
  private readonly sqliteBin: string;
  private readonly listeners = new Set<(chats: CursorChat[]) => void>();
  private chats: CursorChat[] = [];
  private timer: NodeJS.Timeout | null = null;
  private polling = false;
  private lastSerialized = "";

  constructor(options: CursorChatsOptions = {}) {
    this.databasePath =
      options.databasePath ??
      process.env.CURSOR_STATE_DB ??
      join(
        homedir(),
        "Library/Application Support/Cursor/User/globalStorage/state.vscdb",
      );
    this.pollMs = options.pollMs ?? 30_000;
    this.windowSeconds = options.windowSeconds ?? 24 * 3600;
    this.sqliteBin = options.sqliteBin ?? "sqlite3";
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

  current(): CursorChat[] {
    return this.chats;
  }

  subscribe(listener: (chats: CursorChat[]) => void): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  private async poll(): Promise<void> {
    if (this.polling) return;
    this.polling = true;
    try {
      const chats = await this.query();
      const serialized = JSON.stringify(chats);
      if (serialized !== this.lastSerialized) {
        this.lastSerialized = serialized;
        this.chats = chats;
        for (const listener of this.listeners) listener(chats);
      }
    } catch {
      // Cursor may not be installed or the db may be briefly locked.
      // Keep the last good snapshot; the next poll retries.
    } finally {
      this.polling = false;
    }
  }

  private query(): Promise<CursorChat[]> {
    const sql = QUERY.replace(":window", String(this.windowSeconds));
    const uri = `file:${this.databasePath}?mode=ro`;
    return new Promise((resolvePromise, rejectPromise) => {
      execFile(
        this.sqliteBin,
        ["-json", "-readonly", uri, sql],
        { timeout: 25_000, maxBuffer: 8 * 1024 * 1024 },
        (error, stdout) => {
          if (error) {
            rejectPromise(error);
            return;
          }
          const trimmed = stdout.trim();
          if (!trimmed) {
            resolvePromise([]);
            return;
          }
          const rows = JSON.parse(trimmed) as Array<{
            id: string;
            name: string | null;
            status: string | null;
            lastUpdatedAt: number | null;
            generating: number;
            activity: string | null;
            userMessages: string | null;
            headless: number;
          }>;
          resolvePromise(
            rows.map((row) => {
              const firstUserMessage = firstVisibleUserMessage(row.userMessages);
              const generating = row.generating === 1;
              return {
                id: row.id,
                name: cursorTitle(row.name, firstUserMessage),
                status: row.status ?? "none",
                generating,
                activity: generating ? row.activity ?? "Working…" : undefined,
                firstUserMessage: firstUserMessage ?? undefined,
                headless: row.headless === 1,
                lastUpdatedAt: row.lastUpdatedAt ?? 0,
              };
            }),
          );
        },
      );
    });
  }
}

function firstVisibleUserMessage(value: string | null): string | null {
  if (!value) return null;
  try {
    const messages = JSON.parse(value) as unknown;
    if (!Array.isArray(messages)) return visibleText(value);
    for (const message of messages) {
      if (typeof message !== "string") continue;
      const visible = visibleText(message);
      if (visible) return visible;
    }
    return null;
  } catch {
    return visibleText(value);
  }
}

function cursorTitle(
  storedName: string | null,
  firstUserMessage: string | null,
): string {
  const name = storedName?.replace(/\s+/g, " ").trim();
  if (name && name.toLowerCase() !== "(untitled)") return name;
  if (!firstUserMessage) return "New chat";
  return firstUserMessage.length <= 48
    ? firstUserMessage
    : `${firstUserMessage.slice(0, 45)}...`;
}

function visibleText(value: string | null): string | null {
  if (!value) return null;
  let text = value;
  if (/^[{[]/.test(value.trim())) {
    try {
      text = richTextValue(JSON.parse(value) as unknown);
    } catch {
      // Older records sometimes store plain text that begins with punctuation.
    }
  }
  const cleaned = text.replace(/\s+/g, " ").trim();
  return cleaned && !cleaned.startsWith("<") ? cleaned : null;
}

function richTextValue(value: unknown): string {
  if (typeof value === "string") return value;
  if (Array.isArray(value)) return value.map(richTextValue).filter(Boolean).join(" ");
  if (typeof value !== "object" || value === null) return "";
  const record = value as Record<string, unknown>;
  if (
    record.type === "thinking" ||
    record.type === "tool_use" ||
    record.type === "tool_result"
  ) {
    return "";
  }
  if (typeof record.text === "string") return record.text;
  return richTextValue(record.children);
}
