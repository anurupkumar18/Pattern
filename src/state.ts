import { classifyUtterance } from "./classifier";
import type {
  Classification,
  ProjectState,
  SkillRoute,
  StateEntity,
  StateEvent,
  Utterance
} from "./types";

function id(prefix: string): string {
  const value =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  return `${prefix}_${value}`;
}

export function createProjectState(now = new Date().toISOString()): ProjectState {
  return {
    version: 1,
    sessionId: id("session"),
    createdAt: now,
    updatedAt: now,
    utterances: [],
    entities: [],
    commands: [],
    events: []
  };
}

function createEvent(
  utterance: Utterance,
  classification: Classification,
  now: string,
  links: Pick<StateEvent, "entityId" | "commandId"> = {}
): StateEvent {
  return {
    id: id("event"),
    operation: classification.operation,
    createdAt: now,
    utteranceId: utterance.id,
    confidence: classification.confidence,
    rationale: classification.rationale,
    ...links
  };
}

function createEntity(
  utterance: Utterance,
  classification: Classification,
  now: string
): StateEntity {
  const entityId = id(classification.entityKind ?? "task");
  return {
    id: entityId,
    kind: classification.entityKind ?? "task",
    text: classification.normalizedText,
    status: "active",
    createdAt: now,
    updatedAt: now,
    sourceUtteranceId: utterance.id,
    revisions: [
      {
        text: classification.normalizedText,
        utteranceId: utterance.id,
        createdAt: now
      }
    ]
  };
}

function isBareRetraction(text: string): boolean {
  return /^(wait,?\s*)?(forget that|scratch that|never mind)[.!]?$/i.test(text);
}

export function routeCommandToSkill(text: string): SkillRoute {
  if (/^(draft|write)\b/i.test(text)) return "content.draft";
  if (/^export\b/i.test(text)) return "state.export";
  if (/^(open|find|show|check|compare)\b/i.test(text)) {
    return "developer.inspect";
  }
  if (/^(update|select|use)\b/i.test(text)) return "developer.modify";
  if (/^(run|build|make)\b/i.test(text)) return "developer.execute";
  return "general.action";
}

export function applyUtterance(
  state: ProjectState,
  rawText: string,
  now = new Date().toISOString()
): ProjectState {
  const utterance: Utterance = {
    id: id("utterance"),
    text: rawText.replace(/\s+/g, " ").trim(),
    createdAt: now
  };
  const classification = classifyUtterance(utterance.text, state);
  const next: ProjectState = {
    ...state,
    updatedAt: now,
    utterances: [...state.utterances, utterance],
    entities: [...state.entities],
    commands: [...state.commands],
    events: [...state.events]
  };

  if (classification.operation === "noise") {
    next.events.push(createEvent(utterance, classification, now));
    return next;
  }

  if (classification.operation === "command") {
    const command = {
      id: id("command"),
      text: classification.normalizedText,
      status: "pending" as const,
      createdAt: now,
      sourceUtteranceId: utterance.id,
      contextEntityIds: next.entities
        .filter((entity) => entity.status === "active")
        .map((entity) => entity.id),
      suggestedSkill: routeCommandToSkill(classification.normalizedText),
      requiresApproval: true as const
    };
    next.commands.push(command);
    next.events.push(
      createEvent(utterance, classification, now, { commandId: command.id })
    );
    return next;
  }

  if (classification.operation === "add") {
    const entity = createEntity(utterance, classification, now);
    next.entities.push(entity);
    next.events.push(
      createEvent(utterance, classification, now, { entityId: entity.id })
    );
    return next;
  }

  const targetIndex = next.entities.findIndex(
    (entity) => entity.id === classification.targetId
  );
  if (targetIndex === -1) {
    const entity = createEntity(utterance, classification, now);
    next.entities.push(entity);
    next.events.push(
      createEvent(utterance, classification, now, { entityId: entity.id })
    );
    return next;
  }

  const target = next.entities[targetIndex];

  if (classification.operation === "amend") {
    next.entities[targetIndex] = {
      ...target,
      text: `${target.text} ${classification.normalizedText}`,
      updatedAt: now,
      revisions: [
        ...target.revisions,
        {
          text: classification.normalizedText,
          utteranceId: utterance.id,
          createdAt: now
        }
      ]
    };
  }

  if (classification.operation === "resolve") {
    next.entities[targetIndex] = {
      ...target,
      status: "resolved",
      updatedAt: now,
      revisions: [
        ...target.revisions,
        {
          text: classification.normalizedText,
          utteranceId: utterance.id,
          createdAt: now
        }
      ]
    };
  }

  if (classification.operation === "supersede") {
    if (isBareRetraction(classification.normalizedText)) {
      next.entities[targetIndex] = {
        ...target,
        status: "superseded",
        updatedAt: now,
        revisions: [
          ...target.revisions,
          {
            text: classification.normalizedText,
            utteranceId: utterance.id,
            createdAt: now
          }
        ]
      };
    } else {
      const replacement = createEntity(utterance, classification, now);
      next.entities[targetIndex] = {
        ...target,
        status: "superseded",
        updatedAt: now,
        supersededById: replacement.id
      };
      next.entities.push(replacement);
    }
  }

  next.events.push(
    createEvent(utterance, classification, now, { entityId: target.id })
  );
  return next;
}

export function exportStateMarkdown(state: ProjectState): string {
  const lines = [
    "# Project state",
    "",
    `Session: ${state.sessionId}`,
    `Updated: ${state.updatedAt}`,
    ""
  ];

  const sections = [
    ["Goals", "goal"],
    ["Tasks", "task"],
    ["Decisions", "decision"],
    ["Open questions", "question"]
  ] as const;

  sections.forEach(([heading, kind]) => {
    lines.push(`## ${heading}`, "");
    const entities = state.entities.filter(
      (entity) => entity.kind === kind && entity.status !== "superseded"
    );
    if (entities.length === 0) lines.push("- None captured");
    entities.forEach((entity) => {
      lines.push(`- [${entity.status}] ${entity.text}`);
      lines.push(`  - source: ${entity.sourceUtteranceId}`);
    });
    lines.push("");
  });

  lines.push("## Pending commands", "");
  const pending = state.commands.filter((command) => command.status === "pending");
  if (pending.length === 0) lines.push("- None");
  pending.forEach((command) => {
    lines.push(`- ${command.text}`);
    lines.push(`  - approval required: yes`);
  });

  lines.push("", "## Complete utterance ledger", "");
  state.utterances.forEach((utterance, index) => {
    lines.push(`${index + 1}. ${utterance.text || "[empty fragment]"}`);
  });

  return lines.join("\n");
}
