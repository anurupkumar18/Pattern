import { describe, expect, it, vi } from "vitest";

import type { FleetAgent } from "../src/contracts.js";
import { HerdrAdapter } from "../src/control/herdr-adapter.js";
import type {
  HerdrSubscription,
  HerdrTransport,
} from "../src/control/herdr-transport.js";
import { MockHerdr } from "../src/control/mock-herdr.js";

const NOW = new Date("2026-07-18T05:00:00.000Z");

const seedAgent: FleetAgent = {
  id: "w1:p1",
  name: "Migration Agent",
  harness: "claude",
  status: "blocked",
  cwd: "/repos/api",
  lastActivity: {
    summary: "Waiting for database choice",
    at: NOW.toISOString(),
  },
};

describe("MockHerdr", () => {
  it("mutates realistic fleet state for every control operation", async () => {
    const herdr = new MockHerdr({
      agents: [seedAgent],
      latencyMs: 0,
      now: () => NOW,
    });

    await herdr.focus("w1:p1");
    await herdr.send("w1:p1", "use staging");
    const spawn = await herdr.spawn({
      harness: "codex",
      cwd: "/repos/docs",
      name: "Docs Agent",
      initialMessage: "draft the readme",
    });
    await herdr.interrupt("w1:p1");

    const snapshot = await herdr.snapshot();
    expect(snapshot.focusedAgentId).toBe(spawn.agentId);
    expect(snapshot.agents).toHaveLength(2);
    expect(snapshot.agents[0]).toMatchObject({
      id: "w1:p1",
      status: "idle",
      lastActivity: { summary: "Interrupted" },
    });
    expect(snapshot.agents[1]).toMatchObject({
      name: "Docs Agent",
      harness: "codex",
      status: "working",
      cwd: "/repos/docs",
      lastActivity: { summary: "Message: draft the readme" },
    });
  });

  it("publishes immutable snapshots to subscribers", async () => {
    const herdr = new MockHerdr({
      agents: [seedAgent],
      latencyMs: 0,
      now: () => NOW,
    });
    const snapshots: string[] = [];
    const unsubscribe = herdr.subscribe((snapshot) => {
      snapshots.push(snapshot.focusedAgentId ?? "none");
    });

    await herdr.focus("w1:p1");
    unsubscribe();
    await herdr.send("w1:p1", "continue");

    expect(snapshots).toContain("w1:p1");
    expect(snapshots.at(-1)).toBe("w1:p1");
  });
});

describe("HerdrAdapter", () => {
  it("maps session.snapshot into the FleetSnapshot contract", async () => {
    const transport = new FakeTransport();
    transport.respond("session.snapshot", {
      type: "session_snapshot",
      snapshot: {
        focused_pane_id: "w1:p1",
        panes: [],
        agents: [
          {
            pane_id: "w1:p1",
            agent: "claude",
            agent_status: "blocked",
            name: "Migration Agent",
            focused: true,
            cwd: "/repos/api",
            terminal_title_stripped: "Needs database choice",
          },
        ],
      },
    });
    const adapter = new HerdrAdapter({
      transport,
      now: () => NOW,
    });

    await expect(adapter.snapshot()).resolves.toEqual({
      capturedAt: NOW.toISOString(),
      focusedAgentId: "w1:p1",
      listening: true,
      agents: [
        {
          id: "w1:p1",
          name: "Migration Agent",
          harness: "claude",
          status: "blocked",
          cwd: "/repos/api",
          lastActivity: {
            summary: "Needs database choice",
            at: NOW.toISOString(),
          },
        },
      ],
    });
  });

  it("uses documented Herdr methods for fleet actions", async () => {
    const transport = new FakeTransport();
    transport.respond("agent.focus", { type: "agent_info", agent: {} });
    transport.respond("agent.send", { type: "agent_info", agent: {} });
    transport.respond("pane.send_keys", { type: "pane_info", pane: {} });
    transport.respond("workspace.create", {
      type: "workspace_info",
      workspace: { workspace_id: "w2" },
    });
    transport.respond("session.snapshot", {
      type: "session_snapshot",
      snapshot: {
        panes: [{ pane_id: "w2:p1", workspace_id: "w2" }],
        agents: [],
      },
    });
    transport.respond("agent.start", {
      type: "agent_info",
      agent: { pane_id: "w2:p1" },
    });
    transport.respond("agent.send", { type: "agent_info", agent: {} });
    const adapter = new HerdrAdapter({ transport, now: () => NOW });

    await adapter.focus("w1:p1");
    await adapter.send("w1:p1", "continue");
    await adapter.interrupt("w1:p1");
    const result = await adapter.spawn({
      harness: "codex",
      cwd: "/repos/docs",
      name: "Docs Agent",
      initialMessage: "draft the readme",
    });

    expect(result.agentId).toBe("w2:p1");
    expect(transport.calls).toEqual([
      ["agent.focus", { target: "w1:p1" }],
      ["agent.send", { target: "w1:p1", text: "continue" }],
      ["pane.send_keys", { pane_id: "w1:p1", keys: ["ctrl+c"] }],
      [
        "workspace.create",
        { cwd: "/repos/docs", label: "Docs Agent", focus: true },
      ],
      ["session.snapshot", {}],
      [
        "agent.start",
        {
          name: "Docs Agent",
          kind: "codex",
          pane_id: "w2:p1",
          args: [],
          timeout_ms: 30_000,
        },
      ],
      ["agent.send", { target: "w2:p1", text: "draft the readme" }],
    ]);
  });
});

class FakeTransport implements HerdrTransport {
  readonly calls: Array<[string, Record<string, unknown>]> = [];
  private readonly responses = new Map<string, unknown[]>();

  respond(method: string, response: unknown): void {
    const queue = this.responses.get(method) ?? [];
    queue.push(response);
    this.responses.set(method, queue);
  }

  async request(
    method: string,
    params: Record<string, unknown>,
  ): Promise<unknown> {
    this.calls.push([method, params]);
    const response = this.responses.get(method)?.shift();
    if (response === undefined) {
      throw new Error(`No fake response for ${method}`);
    }
    return response;
  }

  subscribe(
    _subscriptions: HerdrSubscription[],
    _handler: (event: unknown) => void,
  ): () => void {
    return vi.fn();
  }
}
