import type { CommandOutcome, FleetCommand } from "../contracts.js";
import { MockHerdr } from "../control/mock-herdr.js";
import { CommandLoop } from "../loop/command-loop.js";
import type { Router } from "../router/router.js";
import type {
  ExpectedCommand,
  FixtureCategory,
  UtteranceFixture,
} from "./fixtures.js";

export interface EvalCaseResult {
  id: string;
  category: FixtureCategory;
  expected: ExpectedCommand;
  actual: Pick<
    FleetCommand,
    "verb" | "resolvedTargetId" | "payload"
  > | null;
  correct: boolean;
  outcome: CommandOutcome["state"] | "ROUTER_ERROR";
  latencyMs: {
    stt: number;
    route: number;
    act: number;
    verify: number;
    total: number;
  } | null;
  error?: string;
}

export interface MetricSummary {
  cases: number;
  correct: number;
  accuracy: number;
}

export interface LatencySummary {
  samples: number;
  mean: number;
  p50: number;
  p95: number;
}

export interface RouterEvalReport {
  backend: string;
  modelEvidence: boolean;
  summary: MetricSummary;
  categories: Record<FixtureCategory, MetricSummary>;
  falseFireRate: number;
  endToEndSuccessRate: number;
  latencyMs: {
    stt: LatencySummary;
    route: LatencySummary;
    act: LatencySummary;
    verify: LatencySummary;
    total: LatencySummary;
  };
  results: EvalCaseResult[];
}

export async function evaluateRouter(
  fixtures: UtteranceFixture[],
  routerFor: (fixture: UtteranceFixture) => Router,
  options: { backend: string; modelEvidence: boolean },
): Promise<RouterEvalReport> {
  const results: EvalCaseResult[] = [];

  for (const fixture of fixtures) {
    const control = new MockHerdr({
      agents: fixture.snapshot.agents,
      focusedAgentId: fixture.snapshot.focusedAgentId,
      listening: fixture.snapshot.listening,
      latencyMs: 0,
    });
    const loop = new CommandLoop({
      router: routerFor(fixture),
      control,
    });
    try {
      let outcome = await loop.handleUtterance(fixture.utterance);
      if (outcome.state === "AWAITING_CONFIRMATION") {
        outcome = await loop.confirm(outcome.id);
      }
      const actual = pickCommand(outcome.command);
      const latencyMs = {
        ...outcome.latencyMs,
        total:
          outcome.latencyMs.stt +
          outcome.latencyMs.route +
          outcome.latencyMs.act +
          outcome.latencyMs.verify,
      };
      results.push({
        id: fixture.id,
        category: fixture.category,
        expected: fixture.expected,
        actual,
        correct: matchesExpected(actual, fixture.expected),
        outcome: outcome.state,
        latencyMs,
      });
    } catch (error) {
      results.push({
        id: fixture.id,
        category: fixture.category,
        expected: fixture.expected,
        actual: null,
        correct: false,
        outcome: "ROUTER_ERROR",
        latencyMs: null,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  const noise = results.filter(({ category }) => category === "noise");
  const falseFires = noise.filter(
    ({ actual }) => actual && actual.verb !== "noise",
  ).length;
  const completed = results.filter(
    ({ outcome }) => outcome === "SUCCEEDED",
  ).length;

  return {
    backend: options.backend,
    modelEvidence: options.modelEvidence,
    summary: metric(results),
    categories: {
      clear: metric(
        results.filter(({ category }) => category === "clear"),
      ),
      fuzzy: metric(
        results.filter(({ category }) => category === "fuzzy"),
      ),
      noise: metric(
        results.filter(({ category }) => category === "noise"),
      ),
      destructive: metric(
        results.filter(({ category }) => category === "destructive"),
      ),
    },
    falseFireRate: noise.length ? falseFires / noise.length : 0,
    endToEndSuccessRate: results.length ? completed / results.length : 0,
    latencyMs: {
      stt: latency(results, "stt"),
      route: latency(results, "route"),
      act: latency(results, "act"),
      verify: latency(results, "verify"),
      total: latency(results, "total"),
    },
    results,
  };
}

function pickCommand(
  command: FleetCommand,
): Pick<FleetCommand, "verb" | "resolvedTargetId" | "payload"> {
  return {
    verb: command.verb,
    resolvedTargetId: command.resolvedTargetId,
    payload: command.payload,
  };
}

export function matchesExpected(
  actual: Pick<FleetCommand, "verb" | "resolvedTargetId" | "payload">,
  expected: ExpectedCommand,
): boolean {
  if (
    actual.verb !== expected.verb ||
    actual.resolvedTargetId !== expected.resolvedTargetId
  ) {
    return false;
  }
  const payload = actual.payload as Record<string, unknown>;
  return Object.entries(expected.payload).every(
    ([key, value]) => JSON.stringify(payload[key]) === JSON.stringify(value),
  );
}

function metric(results: EvalCaseResult[]): MetricSummary {
  const correct = results.filter((result) => result.correct).length;
  return {
    cases: results.length,
    correct,
    accuracy: results.length ? correct / results.length : 0,
  };
}

function latency(
  results: EvalCaseResult[],
  stage: "stt" | "route" | "act" | "verify" | "total",
): LatencySummary {
  const values = results
    .flatMap((result) =>
      result.latencyMs ? [result.latencyMs[stage]] : [],
    )
    .sort((left, right) => left - right);
  return {
    samples: values.length,
    mean: values.length
      ? values.reduce((sum, value) => sum + value, 0) / values.length
      : 0,
    p50: percentile(values, 0.5),
    p95: percentile(values, 0.95),
  };
}

function percentile(values: number[], quantile: number): number {
  if (!values.length) return 0;
  const index = Math.min(
    values.length - 1,
    Math.ceil(values.length * quantile) - 1,
  );
  return values[index] ?? 0;
}
