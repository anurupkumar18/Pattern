export type EntityKind = "goal" | "task" | "decision" | "question";
export type EntityStatus = "active" | "resolved" | "superseded";
export type OperationKind =
  | "add"
  | "amend"
  | "supersede"
  | "resolve"
  | "command"
  | "noise";
export type SkillRoute =
  | "developer.inspect"
  | "developer.modify"
  | "developer.execute"
  | "content.draft"
  | "state.export"
  | "general.action";

export interface Utterance {
  id: string;
  text: string;
  createdAt: string;
}

export interface EntityRevision {
  text: string;
  utteranceId: string;
  createdAt: string;
}

export interface StateEntity {
  id: string;
  kind: EntityKind;
  text: string;
  status: EntityStatus;
  createdAt: string;
  updatedAt: string;
  sourceUtteranceId: string;
  revisions: EntityRevision[];
  supersededById?: string;
}

export interface ActionCommand {
  id: string;
  text: string;
  status: "pending" | "approved" | "running" | "verified" | "cancelled";
  createdAt: string;
  sourceUtteranceId: string;
  contextEntityIds: string[];
  suggestedSkill: SkillRoute;
  requiresApproval: true;
}

export interface StateEvent {
  id: string;
  operation: OperationKind;
  createdAt: string;
  utteranceId: string;
  entityId?: string;
  commandId?: string;
  confidence: number;
  rationale: string;
}

export interface ProjectState {
  version: 1;
  sessionId: string;
  createdAt: string;
  updatedAt: string;
  utterances: Utterance[];
  entities: StateEntity[];
  commands: ActionCommand[];
  events: StateEvent[];
}

export interface Classification {
  operation: OperationKind;
  entityKind?: EntityKind;
  targetId?: string;
  normalizedText: string;
  confidence: number;
  rationale: string;
}
