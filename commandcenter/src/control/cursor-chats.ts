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
SELECT
  substr(key, 14) AS id,
  json_extract(value, '$.name') AS name,
  json_extract(value, '$.status') AS status,
  json_extract(value, '$.lastUpdatedAt') AS lastUpdatedAt,
  CASE
    WHEN json_array_length(json_extract(value, '$.generatingBubbleIds')) > 0
    THEN 1 ELSE 0
  END AS generating
FROM cursorDiskKV
WHERE key LIKE 'composerData:%'
  AND json_extract(value, '$.lastUpdatedAt') >= (strftime('%s','now') - :window) * 1000
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
          }>;
          resolvePromise(
            rows.map((row) => ({
              id: row.id,
              name: row.name?.trim() || "(untitled)",
              status: row.status ?? "none",
              generating: row.generating === 1,
              lastUpdatedAt: row.lastUpdatedAt ?? 0,
            })),
          );
        },
      );
    });
  }
}
