import type {
  Classification,
  EntityKind,
  ProjectState,
  StateEntity
} from "./types";

const CORRECTION =
  /\b(actually|instead|scratch that|forget that|never mind|no,?\s|wait,?\s|change that)\b/i;
const RESOLUTION =
  /\b(done|finished|complete(?:d)?|resolved|closed|answered|we decided)\b/i;
const COMMAND =
  /^(please\s+)?(open|run|create|draft|update|build|make|find|show|check|compare|export|prepare|write|select|use)\b/i;
const QUESTION = /\?$|^(what|why|how|when|where|who|which|should|could|can)\b/i;
const DECISION =
  /\b(we(?:'ve| have)? decided|decision is|going with|we(?:'ll| will) use|let'?s use|choose)\b/i;
const GOAL =
  /\b(goal is|want to|need to|trying to|objective is|success means|we should)\b/i;
const AMENDMENT =
  /^(also|and also|plus|one more thing|make sure|additionally)\b/i;

function normalize(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

function tokens(text: string): Set<string> {
  return new Set(
    text
      .toLowerCase()
      .replace(/[^a-z0-9\s]/g, " ")
      .split(/\s+/)
      .filter((token) => token.length > 3)
  );
}

function overlapScore(text: string, entity: StateEntity): number {
  const left = tokens(text);
  const right = tokens(entity.text);
  if (left.size === 0 || right.size === 0) return 0;
  let matches = 0;
  left.forEach((token) => {
    if (right.has(token)) matches += 1;
  });
  return matches / Math.min(left.size, right.size);
}

function latestActive(state: ProjectState): StateEntity | undefined {
  return [...state.entities].reverse().find((entity) => entity.status === "active");
}

function bestTarget(text: string, state: ProjectState): StateEntity | undefined {
  const candidates = state.entities
    .filter((entity) => entity.status === "active")
    .map((entity) => ({ entity, score: overlapScore(text, entity) }))
    .sort((a, b) => b.score - a.score);

  if (candidates[0] && candidates[0].score >= 0.34) {
    return candidates[0].entity;
  }
  return latestActive(state);
}

function inferEntityKind(text: string): EntityKind {
  if (QUESTION.test(text)) return "question";
  if (DECISION.test(text)) return "decision";
  if (GOAL.test(text)) return "goal";
  return "task";
}

export function classifyUtterance(
  rawText: string,
  state: ProjectState
): Classification {
  const text = normalize(rawText);

  if (!text) {
    return {
      operation: "noise",
      normalizedText: "",
      confidence: 1,
      rationale: "Empty input is preserved in the ledger but does not alter state."
    };
  }

  if (CORRECTION.test(text)) {
    const target = bestTarget(text, state);
    return {
      operation: "supersede",
      entityKind: target?.kind ?? inferEntityKind(text),
      targetId: target?.id,
      normalizedText: text,
      confidence: target ? 0.88 : 0.62,
      rationale: target
        ? `Correction language supersedes the closest active ${target.kind}.`
        : "Correction language was detected, but no active target exists yet."
    };
  }

  if (RESOLUTION.test(text) && state.entities.some((item) => item.status === "active")) {
    const target = bestTarget(text, state);
    return {
      operation: "resolve",
      entityKind: target?.kind,
      targetId: target?.id,
      normalizedText: text,
      confidence: target ? 0.84 : 0.58,
      rationale: "Completion language resolves the closest active state item."
    };
  }

  if (COMMAND.test(text)) {
    return {
      operation: "command",
      normalizedText: text,
      confidence: 0.9,
      rationale: "The utterance begins with an executable directive."
    };
  }

  if (AMENDMENT.test(text) && latestActive(state)) {
    const target = latestActive(state);
    return {
      operation: "amend",
      entityKind: target?.kind,
      targetId: target?.id,
      normalizedText: text,
      confidence: 0.76,
      rationale: "Additive language amends the most recent active item."
    };
  }

  return {
    operation: "add",
    entityKind: inferEntityKind(text),
    normalizedText: text,
    confidence: 0.78,
    rationale: `The fragment introduces a new ${inferEntityKind(text)}.`
  };
}
