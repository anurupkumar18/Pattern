import {
  FleetCommandSchema,
  type FleetCommand,
  type FleetSnapshot,
} from "../contracts.js";
import { DeterministicRouter } from "./deterministic-router.js";
import type { Router } from "./router.js";

export interface CascadeRouterOptions {
  gemma: Router;
  deterministic?: Router;
  timeoutMs?: number;
}

export type CascadeEscalationClass =
  | "unresolved-command"
  | "no-grammar-match"
  | "other-noise";

export class CascadeRouter implements Router {
  private readonly deterministic: Router;
  private readonly gemma: Router;
  private readonly timeoutMs: number;

  constructor(options: CascadeRouterOptions) {
    this.deterministic = options.deterministic ?? new DeterministicRouter();
    this.gemma = options.gemma;
    this.timeoutMs = options.timeoutMs ?? 20_000;
    if (!Number.isFinite(this.timeoutMs) || this.timeoutMs <= 0) {
      throw new Error("CascadeRouter timeoutMs must be a positive number");
    }
  }

  async route(
    utterance: string,
    snapshot: FleetSnapshot,
  ): Promise<FleetCommand> {
    const deterministic = stamp(
      await this.deterministic.route(utterance, snapshot),
      "deterministic",
    );
    if (deterministic.verb !== "noise") return deterministic;

    // Both command-shaped misses and no-grammar matches escalate. The
    // classification is retained so the policy remains explicit and can be
    // measured later without making ambient speech actionable.
    classifyEscalation(deterministic);

    try {
      const gemma = await withTimeout(
        () => this.gemma.route(utterance, snapshot),
        this.timeoutMs,
      );
      return stamp(gemma, "gemma");
    } catch {
      return stamp(deterministic, "cascade-fallback-failed");
    }
  }
}

export function classifyEscalation(
  command: Extract<FleetCommand, { verb: "noise" }>,
): CascadeEscalationClass {
  const reason = command.payload.reason?.toLowerCase() ?? "";
  if (
    reason.includes("not resolved") ||
    reason.includes("could not resolve")
  ) {
    return "unresolved-command";
  }
  if (reason.includes("no fleet command grammar matched")) {
    return "no-grammar-match";
  }
  return "other-noise";
}

function stamp(
  command: FleetCommand,
  routedBy: NonNullable<FleetCommand["routedBy"]>,
): FleetCommand {
  return FleetCommandSchema.parse({ ...command, routedBy });
}

function withTimeout<T>(operation: () => Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      reject(new Error(`Cascade Gemma tier timed out after ${timeoutMs}ms`));
    }, timeoutMs);
    void Promise.resolve()
      .then(operation)
      .then(
        (value) => {
          clearTimeout(timeout);
          resolve(value);
        },
        (error: unknown) => {
          clearTimeout(timeout);
          reject(error);
        },
      );
  });
}
