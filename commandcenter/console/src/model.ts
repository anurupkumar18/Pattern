import type { FleetAgent, FleetSnapshot } from "../../src/contracts.js";

/** Multi-source chat entry as broadcast in `cursor.chats` (legacy name). */
export interface ChatEntry {
  id: string;
  source: "cursor" | "claude" | "codex";
  name: string;
  status: string;
  generating: boolean;
  activity?: string;
  kind: "human" | "automation" | "system";
  lastUpdatedAt: number;
}

export interface ChatMessage {
  id: string;
  role: "user" | "assistant";
  text: string;
  createdAt?: string;
}

export interface ChatTranscriptState {
  source: ChatEntry["source"] | null;
  chatId: string | null;
  messages: ChatMessage[];
  status: "idle" | "loading" | "ready" | "error";
  error: string | null;
  updatedAt: string | null;
}

export type RowSource = "cursor" | "claude" | "codex" | "gemini" | "shell" | "other";

/** One unified sidebar row: live agents and historical chats share a shape. */
export interface HistoryRow {
  id: string;
  kind: "agent" | "chat";
  source: RowSource;
  title: string;
  /** Project path (agents) or pending question (needs-input rows). */
  subtitle: string | null;
  timestamp: number;
  working: boolean;
  needsInput: boolean;
  doneUnseen: boolean;
  stopped: boolean;
  focused: boolean;
  /** Spoken name used when routing voice/keyboard focus commands. */
  spokenName: string;
  /** Controls whether the row appears in the main library or its archive. */
  libraryKind: ChatEntry["kind"];
}

export interface HistorySection {
  label: string;
  rows: HistoryRow[];
}

const DAY_MS = 24 * 60 * 60 * 1_000;

export function relativeTime(timestamp: number, now = Date.now()): string {
  const delta = Math.max(0, (now - timestamp) / 1000);
  if (delta < 60) return "now";
  if (delta < 3600) return `${Math.floor(delta / 60)}m`;
  if (delta < 86_400) return `${Math.floor(delta / 3600)}h`;
  return `${Math.floor(delta / 86_400)}d`;
}

export function buildRows(
  snapshot: FleetSnapshot | null,
  chats: ChatEntry[],
  seen: Record<string, number>,
  now = Date.now(),
  observedAt = now,
): HistoryRow[] {
  const agentRows = (snapshot?.agents ?? [])
    .filter((agent) => !/smoke|test/i.test(agent.name))
    .map((agent) => agentRow(agent, snapshot?.focusedAgentId ?? null, now));
  const chatRows = chats.map((chat) => chatRow(chat, seen, observedAt));
  return [...agentRows, ...chatRows];
}

function agentRow(
  agent: FleetAgent,
  focusedAgentId: string | null,
  now: number,
): HistoryRow {
  const at = Date.parse(agent.lastActivity.at);
  return {
    id: agent.id,
    kind: "agent",
    source: agentSource(agent.harness),
    title: agent.name,
    subtitle:
      agent.status === "blocked"
        ? agent.lastActivity.summary || null
        : agent.cwd || null,
    timestamp: Number.isFinite(at) ? at : now,
    working: agent.status === "working",
    needsInput: agent.status === "blocked",
    doneUnseen: false,
    stopped: false,
    focused: agent.id === focusedAgentId,
    spokenName: agent.name,
    libraryKind: "human",
  };
}

function chatRow(
  chat: ChatEntry,
  seen: Record<string, number>,
  observedAt: number,
): HistoryRow {
  const finished =
    chat.status === "completed" ||
    chat.status === "finished" ||
    chat.status === "done";
  return {
    id: chat.id,
    kind: "chat",
    source: chat.source,
    title: chat.name,
    subtitle: chat.generating ? chat.activity ?? "Working…" : null,
    timestamp: chat.lastUpdatedAt,
    working: chat.generating,
    needsInput: false,
    doneUnseen:
      finished &&
      !chat.generating &&
      chat.lastUpdatedAt > observedAt &&
      (seen[chat.id] ?? 0) < chat.lastUpdatedAt,
    stopped: chat.status === "aborted",
    focused: false,
    spokenName: chat.name,
    libraryKind: chat.kind,
  };
}

function agentSource(harness: FleetAgent["harness"]): RowSource {
  if (harness === "claude" || harness === "codex" || harness === "gemini") {
    return harness;
  }
  return harness === "shell" ? "shell" : "other";
}

/** Time-grouped sections per spec §4: attention first inside each group. */
export function groupRows(rows: HistoryRow[], now = Date.now()): HistorySection[] {
  const startOfToday = new Date(now).setHours(0, 0, 0, 0);
  const startOfYesterday = startOfToday - DAY_MS;
  const humanRows = rows.filter((row) => row.libraryKind === "human");
  const automationRows = rows.filter(
    (row) => row.libraryKind === "automation",
  );

  const buckets: Record<"Today" | "Yesterday" | "Earlier", HistoryRow[]> = {
    Today: [],
    Yesterday: [],
    Earlier: [],
  };
  for (const row of humanRows) {
    if (row.timestamp >= startOfToday) buckets.Today.push(row);
    else if (row.timestamp >= startOfYesterday) buckets.Yesterday.push(row);
    else buckets.Earlier.push(row);
  }
  const sections = Object.entries(buckets)
    .filter(([, sectionRows]) => sectionRows.length > 0)
    .map(([label, sectionRows]) => ({
      label,
      rows: [...sectionRows].sort(compareRows),
    }));
  if (automationRows.length > 0) {
    sections.push({
      label: "Automations",
      rows: [...automationRows].sort(compareRows),
    });
  }
  return sections;
}

function compareRows(left: HistoryRow, right: HistoryRow): number {
  return rowPriority(left) - rowPriority(right) || right.timestamp - left.timestamp;
}

function rowPriority(row: HistoryRow): number {
  if (row.needsInput) return 0;
  if (row.doneUnseen) return 1;
  if (row.working) return 2;
  return 3;
}

export interface AttentionItem {
  row: HistoryRow;
  reason: "needs-input" | "finished";
}

export function attentionItems(rows: HistoryRow[]): AttentionItem[] {
  const needs = rows
    .filter((row) => row.needsInput)
    .map((row) => ({ row, reason: "needs-input" as const }));
  const finished = rows
    .filter((row) => row.doneUnseen)
    .map((row) => ({ row, reason: "finished" as const }));
  return [...needs, ...finished];
}

export function attentionSummary(items: AttentionItem[]): string {
  const needs = items.filter((item) => item.reason === "needs-input").length;
  const finished = items.length - needs;
  const parts: string[] = [];
  if (needs > 0) parts.push(`${needs} need${needs === 1 ? "s" : ""} input`);
  if (finished > 0) parts.push(`${finished} finished`);
  return parts.length > 0 ? parts.join(" · ") : "All quiet";
}

const SEEN_KEY = "dictator.seen.v1";
const OBSERVED_KEY = "dictator.observed-at.v1";

export function loadSeen(): Record<string, number> {
  try {
    const raw = localStorage.getItem(SEEN_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (typeof parsed !== "object" || parsed === null) return {};
    return parsed as Record<string, number>;
  } catch {
    return {};
  }
}

export function persistSeen(seen: Record<string, number>): void {
  try {
    localStorage.setItem(SEEN_KEY, JSON.stringify(seen));
  } catch {
    // Private-mode storage failures only lose unread dots.
  }
}

export function loadObservedAt(now = Date.now()): number {
  try {
    const value = Number(localStorage.getItem(OBSERVED_KEY));
    return Number.isFinite(value) && value > 0 ? value : now;
  } catch {
    return now;
  }
}

export function persistObservedAt(timestamp: number): void {
  try {
    localStorage.setItem(OBSERVED_KEY, String(timestamp));
  } catch {
    // Private-mode storage failures only lose cross-session unread state.
  }
}
