import { z } from "zod";

export const AgentStatusSchema = z.enum(["working", "idle", "blocked", "done"]);
export const HarnessSchema = z.enum(["claude", "codex", "gemini", "shell", "other"]);

export const FleetAgentSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
  harness: HarnessSchema,
  status: AgentStatusSchema,
  cwd: z.string().min(1),
  lastActivity: z.object({
    summary: z.string(),
    at: z.string().datetime(),
  }),
});

export const FleetSnapshotSchema = z.object({
  capturedAt: z.string().datetime(),
  agents: z.array(FleetAgentSchema),
  focusedAgentId: z.string().nullable(),
  listening: z.boolean(),
});

const CommandMetadataSchema = z.object({
  confidence: z.number().min(0).max(1),
  rawUtterance: z.string(),
  resolvedTargetId: z.string().nullable(),
});

const commandVariant = <
  T extends z.ZodLiteral<string>,
  P extends z.ZodType,
>(verb: T, payload: P) =>
  CommandMetadataSchema.extend({
    verb,
    payload,
  });

export const StatusCommandSchema = commandVariant(
  z.literal("status"),
  z.object({}),
);

export const FocusCommandSchema = commandVariant(
  z.literal("focus"),
  z.object({ agentId: z.string().min(1) }),
);

export const SendCommandSchema = commandVariant(
  z.literal("send"),
  z.object({
    agentId: z.string().min(1),
    text: z.string().min(1),
  }),
);

export const SpawnSpecSchema = z.object({
  harness: HarnessSchema,
  cwd: z.string().min(1),
  name: z.string().min(1).optional(),
  initialMessage: z.string().min(1).optional(),
});

export const SpawnCommandSchema = commandVariant(
  z.literal("spawn"),
  SpawnSpecSchema,
);

export const InterruptCommandSchema = commandVariant(
  z.literal("interrupt"),
  z.object({ agentId: z.string().min(1) }),
);

export const ListenControlCommandSchema = commandVariant(
  z.literal("listen_ctl"),
  z.object({ action: z.enum(["start", "stop"]) }),
);

export const DictateCommandSchema = commandVariant(
  z.literal("dictate"),
  z.object({
    agentId: z.string().min(1),
    text: z.string().min(1),
  }),
);

export const NoiseCommandSchema = commandVariant(
  z.literal("noise"),
  z.object({ reason: z.string().optional() }),
);

export const FleetCommandSchema = z.discriminatedUnion("verb", [
  StatusCommandSchema,
  FocusCommandSchema,
  SendCommandSchema,
  SpawnCommandSchema,
  InterruptCommandSchema,
  ListenControlCommandSchema,
  DictateCommandSchema,
  NoiseCommandSchema,
]);

export const VerificationResultSchema = z.object({
  predicate: z.string().min(1),
  passed: z.boolean(),
  evidence: z.string(),
  observed: z.unknown().optional(),
});

export const ExecutorResultSchema = z.object({
  ok: z.boolean(),
  evidence: z.string(),
  error: z.string().optional(),
});

export const CommandStateSchema = z.enum([
  "AWAITING_CONFIRMATION",
  "EXECUTED",
  "SUCCEEDED",
  "UNVERIFIED",
  "FAILED",
]);

export const CommandOutcomeSchema = z.object({
  id: z.string().min(1),
  command: FleetCommandSchema,
  state: CommandStateSchema,
  executor: ExecutorResultSchema.nullable(),
  verification: z.array(VerificationResultSchema),
  latencyMs: z.object({
    stt: z.number().nonnegative(),
    route: z.number().nonnegative(),
    act: z.number().nonnegative(),
    verify: z.number().nonnegative(),
  }),
  createdAt: z.string().datetime(),
});

export type FleetAgent = z.infer<typeof FleetAgentSchema>;
export type FleetSnapshot = z.infer<typeof FleetSnapshotSchema>;
export type FleetCommand = z.infer<typeof FleetCommandSchema>;
export type SpawnSpec = z.infer<typeof SpawnSpecSchema>;
export type VerificationResult = z.infer<typeof VerificationResultSchema>;
export type ExecutorResult = z.infer<typeof ExecutorResultSchema>;
export type CommandOutcome = z.infer<typeof CommandOutcomeSchema>;
export type CommandState = z.infer<typeof CommandStateSchema>;
