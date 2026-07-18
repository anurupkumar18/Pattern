import type { FleetCommand } from "../../src/contracts.js";
import type { HistoryRow } from "./model.js";

export type ChipId =
  | "move"
  | "send"
  | "attention"
  | "interrupt"
  | "new";

/** Maps an authoritative routed verb onto its HUD chip. */
export function chipForVerb(verb: FleetCommand["verb"]): ChipId | null {
  switch (verb) {
    case "focus":
      return "move";
    case "send":
    case "dictate":
      return "send";
    case "status":
      return "attention";
    case "interrupt":
      return "interrupt";
    case "spawn":
      return "new";
    case "listen_ctl":
    case "noise":
      return null;
  }
}

export interface ParsePreview {
  chip: ChipId | null;
  /** Human preview such as `Move → evals`; null when nothing matched. */
  preview: string | null;
  targetRowId: string | null;
  targetName: string | null;
  /** Staged-beat length before dispatch. */
  holdMs: number;
}

const SEND_HOLD_MS = 1_200;
const BEAT_MS = 300;

function normalize(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^\w\s/.-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function findTarget(
  normalized: string,
  rows: HistoryRow[],
): HistoryRow | null {
  let best: HistoryRow | null = null;
  let bestLength = 0;
  for (const row of rows) {
    const aliases = [
      normalize(row.spokenName),
      normalize(row.spokenName).replace(/\s+agent$/, ""),
      normalize(row.id.replace(/^[a-z]+:/, "")),
    ]
      .flatMap((alias) => [alias, alias.replace(/[-_]+/g, " ")])
      .filter((alias) => alias.length > 1);
    for (const alias of aliases) {
      if (normalized.includes(alias) && alias.length > bestLength) {
        best = row;
        bestLength = alias.length;
      }
    }
  }
  return best;
}

/**
 * Lightweight client-side mirror of the deterministic grammar. It powers the
 * parse-before-act preview only; the server router remains authoritative.
 */
export function previewParse(
  utterance: string,
  rows: HistoryRow[],
): ParsePreview {
  const normalized = normalize(utterance);
  const none: ParsePreview = {
    chip: null,
    preview: null,
    targetRowId: null,
    targetName: null,
    holdMs: 0,
  };
  if (!normalized) return none;

  if (
    /\b(spawn|open a new|start a)\b/.test(normalized) &&
    /\b(claude|codex|gemini|cursor)\b/.test(normalized)
  ) {
    return {
      chip: "new",
      preview: "New chat",
      targetRowId: null,
      targetName: null,
      holdMs: BEAT_MS,
    };
  }
  if (/\b(interrupt|pause)\b/.test(normalized)) {
    const target = findTarget(normalized, rows);
    return {
      chip: "interrupt",
      preview: target ? `Interrupt → ${target.title}` : "Interrupt",
      targetRowId: target?.id ?? null,
      targetName: target?.title ?? null,
      holdMs: BEAT_MS,
    };
  }
  if (/^(tell|send|dictate)\b/.test(normalized)) {
    const target = findTarget(normalized, rows);
    return {
      chip: "send",
      preview: target ? `Send → ${target.title}` : "Send",
      targetRowId: target?.id ?? null,
      targetName: target?.title ?? null,
      holdMs: SEND_HOLD_MS,
    };
  }
  if (/\b(focus|switch to|move to|show me)\b/.test(normalized)) {
    const target = findTarget(normalized, rows);
    return {
      chip: "move",
      preview: target ? `Move → ${target.title}` : "Move",
      targetRowId: target?.id ?? null,
      targetName: target?.title ?? null,
      holdMs: BEAT_MS,
    };
  }
  if (/\bwhat needs me\b/.test(normalized) || /\bstatus\b/.test(normalized)) {
    return {
      chip: "attention",
      preview: "What needs me",
      targetRowId: null,
      targetName: null,
      holdMs: 0,
    };
  }
  return none;
}

export function isCancelWord(utterance: string): boolean {
  const normalized = normalize(utterance);
  return normalized === "cancel" || normalized === "never mind";
}

export function isSendWord(utterance: string): boolean {
  return normalize(utterance) === "send";
}

/** Extracts the message portion after the resolved chat name. */
export function messageTextForTarget(
  utterance: string,
  target: HistoryRow,
): string | null {
  const normalized = normalize(utterance);
  const aliases = [
    normalize(target.spokenName),
    normalize(target.title),
    normalize(target.id.replace(/^[a-z]+:/, "")),
  ]
    .flatMap((alias) => [alias, alias.replace(/[-_]+/g, " ")])
    .filter(Boolean)
    .sort((left, right) => right.length - left.length);

  for (const alias of aliases) {
    const direct = normalized.match(
      new RegExp(
        `^(?:tell|send|dictate)\\s+(?:to\\s+)?${escapeRegExp(alias)}\\s+(.+)$`,
      ),
    );
    if (direct?.[1]) return direct[1].trim();

    const trailing = normalized.match(
      new RegExp(
        `^(?:tell|send|dictate)\\s+(.+?)\\s+to\\s+${escapeRegExp(alias)}$`,
      ),
    );
    if (trailing?.[1]) return trailing[1].trim();
  }
  return null;
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
