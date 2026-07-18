import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import {
  evaluateRouter,
  matchesExpected,
} from "../src/eval/evaluator.js";
import { loadUtteranceFixtures } from "../src/eval/fixtures.js";
import { DeterministicRouter } from "../src/router/deterministic-router.js";

describe("eval runner", () => {
  it("measures category accuracy, false fires, and full-loop outcomes", async () => {
    const fixtures = await loadUtteranceFixtures(
      resolve("fixtures/utterances.json"),
    );
    const report = await evaluateRouter(
      fixtures,
      () => new DeterministicRouter(),
      { backend: "test", modelEvidence: false },
    );

    expect(report.categories.clear.accuracy).toBe(1);
    expect(report.categories.noise.accuracy).toBe(1);
    expect(report.falseFireRate).toBe(0);
    expect(report.endToEndSuccessRate).toBe(1);
    expect(report.latencyMs.route.samples).toBe(fixtures.length);
  });

  it("allows an expected payload subset without hiding verb mismatches", () => {
    expect(
      matchesExpected(
        {
          verb: "noise",
          resolvedTargetId: null,
          payload: { reason: "ambient speech" },
        },
        { verb: "noise", resolvedTargetId: null, payload: {} },
      ),
    ).toBe(true);
    expect(
      matchesExpected(
        {
          verb: "status",
          resolvedTargetId: null,
          payload: {},
        },
        { verb: "noise", resolvedTargetId: null, payload: {} },
      ),
    ).toBe(false);
  });
});
