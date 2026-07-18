import {
  FleetCommandSchema,
  type FleetAgent,
  type FleetCommand,
  type FleetSnapshot,
  type SpawnSpec,
} from "../contracts.js";
import type { Router } from "./router.js";

export class DeterministicRouter implements Router {
  async route(
    rawUtterance: string,
    snapshot: FleetSnapshot,
  ): Promise<FleetCommand> {
    const utterance = rawUtterance.trim();
    const normalized = normalize(utterance);

    if (isListenStop(normalized)) {
      return command("listen_ctl", utterance, null, { action: "stop" });
    }
    if (isListenStart(normalized)) {
      return command("listen_ctl", utterance, null, { action: "start" });
    }
    if (isSpawn(normalized)) {
      return command("spawn", utterance, null, parseSpawn(utterance));
    }
    if (isInterrupt(normalized)) {
      const target = resolveTarget(normalized, snapshot);
      return target
        ? command("interrupt", utterance, target.id, { agentId: target.id })
        : noise(utterance, "interrupt target was not resolved");
    }
    if (isDictate(normalized)) {
      const target =
        resolveTarget(normalized, snapshot, true) ??
        snapshot.agents.find(
          (agent) => agent.id === snapshot.focusedAgentId,
        ) ??
        null;
      const text = parseDictation(utterance);
      return target && text
        ? command("dictate", utterance, target.id, {
            agentId: target.id,
            text,
          })
        : noise(utterance, "dictation target or text was not resolved");
    }
    if (isSend(normalized)) {
      const target = resolveTarget(normalized, snapshot, true);
      const text = target ? parseMessage(utterance, target) : null;
      return target && text
        ? command("send", utterance, target.id, {
            agentId: target.id,
            text,
          })
        : noise(utterance, "send target or message was not resolved");
    }
    if (isFocus(normalized)) {
      const target = resolveTarget(normalized, snapshot, true);
      return target
        ? command("focus", utterance, target.id, { agentId: target.id })
        : noise(utterance, "focus target was not resolved");
    }
    if (isStatus(normalized)) {
      const blocked = snapshot.agents.filter(
        (agent) => agent.status === "blocked",
      );
      const resolvedTargetId =
        normalized.includes("needs me") && blocked.length === 1
          ? blocked[0]?.id ?? null
          : null;
      return command("status", utterance, resolvedTargetId, {});
    }

    return noise(utterance, "no fleet command grammar matched");
  }
}

function command(
  verb: FleetCommand["verb"],
  rawUtterance: string,
  resolvedTargetId: string | null,
  payload: Record<string, unknown>,
): FleetCommand {
  return FleetCommandSchema.parse({
    verb,
    payload,
    confidence: 1,
    rawUtterance,
    resolvedTargetId,
    routedBy: "deterministic",
  });
}

function noise(rawUtterance: string, reason: string): FleetCommand {
  return command("noise", rawUtterance, null, { reason });
}

function normalize(value: string): string {
  return value
    .toLowerCase()
    .replace(/[^\w\s/.-]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function isStatus(value: string): boolean {
  return (
    /\bstatus\b/.test(value) ||
    /\bfleet update\b/.test(value) ||
    /\bwhat needs me\b/.test(value)
  );
}

function isFocus(value: string): boolean {
  return /\b(focus|switch to|show me)\b/.test(value);
}

function isSend(value: string): boolean {
  return /^(tell|send)\b/.test(value);
}

function isSpawn(value: string): boolean {
  return (
    /\b(spawn|open a new|start a)\b/.test(value) &&
    /\b(claude|codex|gemini)\b/.test(value)
  );
}

function isInterrupt(value: string): boolean {
  return /\b(interrupt|pause)\b/.test(value);
}

function isListenStop(value: string): boolean {
  return /\b(stop|pause) listening\b/.test(value);
}

function isListenStart(value: string): boolean {
  return /\b(listen up|start listening|resume listening)\b/.test(value);
}

function isDictate(value: string): boolean {
  return /^(dictate|type into the focused agent)\b/.test(value);
}

function resolveTarget(
  utterance: string,
  snapshot: FleetSnapshot,
  allowFocused = false,
): FleetAgent | null {
  if (/\b(the )?(blocked one|one that is blocked)\b/.test(utterance)) {
    const blocked = snapshot.agents.filter(
      (agent) => agent.status === "blocked",
    );
    if (blocked.length === 1) return blocked[0] ?? null;
  }

  const ordinal = utterance.match(/\b(first|second|third)\s+(\w+)\b/);
  if (ordinal) {
    const index = { first: 0, second: 1, third: 2 }[
      ordinal[1] as "first" | "second" | "third"
    ];
    const harness = ordinal[2];
    const matches = snapshot.agents.filter(
      (agent) => agent.harness === harness,
    );
    if (matches[index]) return matches[index] ?? null;
  }

  const namedMatches = snapshot.agents
    .map((agent) => ({
      agent,
      // Spoken language never contains hyphens/underscores, so an agent
      // named "smoke-shell" must match the utterance "smoke shell".
      aliases: dedupe(
        [
          normalize(agent.name),
          normalize(agent.name).replace(/\s+agent$/, ""),
          normalize(agent.id),
        ].flatMap((alias) => [alias, alias.replace(/[-_]+/g, " ")]),
      ),
    }))
    .filter(({ aliases }) =>
      aliases.some(
        (alias) =>
          alias.length > 0 &&
          new RegExp(`\\b${escapeRegExp(alias)}(?: agent)?\\b`).test(utterance),
      ),
    );
  if (namedMatches.length === 1) return namedMatches[0]?.agent ?? null;

  if (
    allowFocused &&
    snapshot.focusedAgentId &&
    /\b(it|focused agent)\b/.test(utterance)
  ) {
    return (
      snapshot.agents.find(
        (agent) => agent.id === snapshot.focusedAgentId,
      ) ?? null
    );
  }

  return null;
}

function parseMessage(utterance: string, target: FleetAgent): string | null {
  const normalized = normalize(utterance);
  const toMatch = normalized.match(/\bto\s+(.+)$/);
  if (toMatch?.[1]) return toMatch[1].trim();

  const aliases = [
    normalize(target.name),
    normalize(target.name).replace(/\s+agent$/, ""),
  ].sort((left, right) => right.length - left.length);
  for (const alias of aliases) {
    const match = normalized.match(
      new RegExp(`^send\\s+(?:the\\s+)?${escapeRegExp(alias)}(?:\\s+agent)?\\s+(.+)$`),
    );
    if (match?.[1]) return match[1].trim();
  }

  return null;
}

function parseDictation(utterance: string): string | null {
  const normalized = normalize(utterance);
  const match = normalized.match(
    /^(?:dictate|type into the focused agent)\s+(.+)$/,
  );
  return match?.[1]?.trim() || null;
}

function parseSpawn(utterance: string): SpawnSpec {
  const normalized = normalize(utterance);
  const harness = normalized.includes("codex")
    ? "codex"
    : normalized.includes("gemini")
      ? "gemini"
      : "claude";
  const cwd = utterance.match(/\/[^\s]+/)?.[0] ?? process.cwd();
  const nameMatch = normalized.match(/\bnamed\s+(.+?)\s+in\s+\//);
  const initialMessage = normalized.match(/\band have it\s+(.+)$/)?.[1];

  return {
    harness,
    cwd,
    ...(nameMatch?.[1] ? { name: titleCase(nameMatch[1]) } : {}),
    ...(initialMessage ? { initialMessage } : {}),
  };
}

function titleCase(value: string): string {
  return value.replace(/\b\w/g, (character) => character.toUpperCase());
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function dedupe(values: string[]): string[] {
  return [...new Set(values)];
}
