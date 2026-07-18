import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type { FleetSnapshot } from "../src/contracts.js";
import type { ControlReceipt } from "../src/control/fleet-control.js";
import { MockHerdr } from "../src/control/mock-herdr.js";
import { CommandLoop } from "../src/loop/command-loop.js";
import { DeterministicRouter } from "../src/router/deterministic-router.js";
import type { Router } from "../src/router/router.js";

interface Fixture {
  id: string;
  category: "clear" | "fuzzy" | "noise" | "destructive";
  utterance: string;
  snapshot: FleetSnapshot;
}

describe("CommandLoop", () => {
  it("runs the entire fixture matrix through route, act, and verify", async () => {
    const fixtures = await loadFixtures();
    const failures: string[] = [];

    for (const fixture of fixtures) {
      const control = new MockHerdr({
        agents: fixture.snapshot.agents,
        focusedAgentId: fixture.snapshot.focusedAgentId,
        listening: fixture.snapshot.listening,
        latencyMs: 0,
      });
      const loop = new CommandLoop({
        router: new DeterministicRouter(),
        control,
      });

      let outcome = await loop.handleUtterance(fixture.utterance);
      if (outcome.state === "AWAITING_CONFIRMATION") {
        outcome = await loop.confirm(outcome.id);
      }
      if (outcome.state !== "SUCCEEDED") {
        failures.push(
          `${fixture.id}: ${outcome.state} ${JSON.stringify(outcome.verification)}`,
        );
      }
    }

    expect(failures).toEqual([]);
  });

  it("requires confirmation for interrupt and low confidence", async () => {
    const control = new MockHerdr({
      agents: [
        {
          id: "deploy",
          name: "Deploy Agent",
          harness: "codex",
          status: "working",
          cwd: "/repo",
          lastActivity: {
            summary: "Deploying",
            at: "2026-07-18T05:00:00.000Z",
          },
        },
      ],
      latencyMs: 0,
    });
    const lowConfidenceRouter: Router = {
      async route(utterance) {
        return {
          verb: "focus",
          payload: { agentId: "deploy" },
          confidence: 0.4,
          rawUtterance: utterance,
          resolvedTargetId: "deploy",
        };
      },
    };
    const lowConfidenceLoop = new CommandLoop({
      router: lowConfidenceRouter,
      control,
    });

    const lowConfidence =
      await lowConfidenceLoop.handleUtterance("maybe that one");
    expect(lowConfidence.state).toBe("AWAITING_CONFIRMATION");
    await expect(lowConfidenceLoop.confirm(lowConfidence.id)).resolves.toMatchObject(
      { state: "SUCCEEDED" },
    );

    const interruptLoop = new CommandLoop({
      router: new DeterministicRouter(),
      control,
    });
    const interrupt =
      await interruptLoop.handleUtterance("pause the deploy agent");
    expect(interrupt.state).toBe("AWAITING_CONFIRMATION");
  });

  it("never promotes a lying executor to SUCCEEDED", async () => {
    const control = new LyingFocusMock({
      agents: [
        {
          id: "migration",
          name: "Migration Agent",
          harness: "claude",
          status: "idle",
          cwd: "/repo",
          lastActivity: {
            summary: "Ready",
            at: "2026-07-18T05:00:00.000Z",
          },
        },
      ],
      focusedAgentId: null,
      latencyMs: 0,
    });
    const loop = new CommandLoop({
      router: new DeterministicRouter(),
      control,
    });

    const outcome =
      await loop.handleUtterance("focus the migration agent");

    expect(outcome.executor).toMatchObject({ ok: true });
    expect(outcome.state).toBe("UNVERIFIED");
    expect(outcome.verification).toEqual([
      expect.objectContaining({ passed: false }),
    ]);
  });

  it("emits routed, executed, verified, and snapshot events", async () => {
    const control = new MockHerdr({ latencyMs: 0 });
    const loop = new CommandLoop({
      router: new DeterministicRouter(),
      control,
    });
    const eventTypes: string[] = [];
    loop.subscribe((event) => eventTypes.push(event.type));

    const outcome = await loop.handleUtterance("fleet status");

    expect(outcome.state).toBe("SUCCEEDED");
    expect(eventTypes).toEqual([
      "fleet.snapshot",
      "command.routed",
      "command.outcome",
      "fleet.snapshot",
      "command.outcome",
    ]);
  });
});

class LyingFocusMock extends MockHerdr {
  override async focus(agentId: string): Promise<ControlReceipt> {
    return {
      ok: true,
      evidence: `claimed focus changed to ${agentId}`,
      agentId,
    };
  }
}

async function loadFixtures(): Promise<Fixture[]> {
  const content = await readFile(resolve("fixtures/utterances.json"), "utf8");
  return JSON.parse(content) as Fixture[];
}
