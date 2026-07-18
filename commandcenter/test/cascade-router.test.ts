import { describe, expect, it, vi } from "vitest";

import {
  FleetCommandSchema,
  type FleetCommand,
  type FleetSnapshot,
} from "../src/contracts.js";
import {
  CascadeRouter,
  classifyEscalation,
} from "../src/router/cascade-router.js";
import type { Router } from "../src/router/router.js";

const snapshot: FleetSnapshot = {
  capturedAt: "2026-07-18T05:00:00.000Z",
  focusedAgentId: null,
  listening: true,
  agents: [],
};

describe("CascadeRouter", () => {
  it("returns an actionable deterministic answer immediately", async () => {
    const gemmaRoute = vi.fn<Router["route"]>();
    const router = new CascadeRouter({
      deterministic: stubRouter(focusCommand()),
      gemma: { route: gemmaRoute },
    });

    const command = await router.route("focus migration", snapshot);

    expect(command.routedBy).toBe("deterministic");
    expect(command.verb).toBe("focus");
    expect(gemmaRoute).not.toHaveBeenCalled();
  });

  it("escalates command-shaped noise with an unresolved target", async () => {
    const unresolved = noiseCommand("focus target was not resolved");
    const gemmaRoute = vi.fn<Router["route"]>().mockResolvedValue(focusCommand());
    const router = new CascadeRouter({
      deterministic: stubRouter(unresolved),
      gemma: { route: gemmaRoute },
    });

    const command = await router.route("show me the one waiting on auth", snapshot);

    expect(classifyEscalation(unresolved)).toBe("unresolved-command");
    expect(gemmaRoute).toHaveBeenCalledOnce();
    expect(command).toMatchObject({ verb: "focus", routedBy: "gemma" });
  });

  it("falls back to deterministic noise when the Gemma tier fails", async () => {
    const deterministic = noiseCommand("no fleet command grammar matched");
    const gemmaRoute = vi
      .fn<Router["route"]>()
      .mockRejectedValue(new Error("offline"));
    const router = new CascadeRouter({
      deterministic: stubRouter(deterministic),
      gemma: { route: gemmaRoute },
    });

    const command = await router.route("the one that's waiting on auth", snapshot);

    expect(command).toMatchObject({
      verb: "noise",
      payload: { reason: "no fleet command grammar matched" },
      routedBy: "cascade-fallback-failed",
    });
    expect(gemmaRoute).toHaveBeenCalledOnce();
  });

  it("overrides stub provenance with the tier that answered", async () => {
    const router = new CascadeRouter({
      deterministic: stubRouter(noiseCommand("ambient", "gemma")),
      gemma: stubRouter(focusCommand("deterministic")),
    });

    const command = await router.route("show me migration", snapshot);

    expect(command.routedBy).toBe("gemma");
  });
});

function stubRouter(command: FleetCommand): Router {
  return { route: vi.fn<Router["route"]>().mockResolvedValue(command) };
}

function focusCommand(routedBy?: FleetCommand["routedBy"]): FleetCommand {
  return FleetCommandSchema.parse({
    verb: "focus",
    payload: { agentId: "migration" },
    confidence: 0.9,
    rawUtterance: "focus migration",
    resolvedTargetId: "migration",
    ...(routedBy ? { routedBy } : {}),
  });
}

function noiseCommand(
  reason: string,
  routedBy?: FleetCommand["routedBy"],
): Extract<FleetCommand, { verb: "noise" }> {
  return FleetCommandSchema.parse({
    verb: "noise",
    payload: { reason },
    confidence: 1,
    rawUtterance: "noise",
    resolvedTargetId: null,
    ...(routedBy ? { routedBy } : {}),
  }) as Extract<FleetCommand, { verb: "noise" }>;
}
