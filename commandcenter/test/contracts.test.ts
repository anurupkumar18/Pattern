import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";
import { z } from "zod";

import {
  CommandOutcomeSchema,
  FleetCommandSchema,
  FleetSnapshotSchema,
  VerificationResultSchema,
} from "../src/contracts.js";

const ExpectedCommandSchema = z.object({
  verb: z.enum([
    "status",
    "focus",
    "send",
    "spawn",
    "interrupt",
    "listen_ctl",
    "dictate",
    "noise",
  ]),
  resolvedTargetId: z.string().nullable(),
  payload: z.record(z.string(), z.unknown()),
});

const FixtureSchema = z.array(
  z.object({
    id: z.string(),
    category: z.enum(["clear", "fuzzy", "noise", "destructive"]),
    utterance: z.string().min(1),
    snapshot: FleetSnapshotSchema,
    expected: ExpectedCommandSchema,
  }),
);

describe("FleetCommand contracts", () => {
  it("accepts every command verb", () => {
    const base = {
      confidence: 0.95,
      rawUtterance: "test",
      resolvedTargetId: null,
    };
    const commands = [
      { ...base, verb: "status", payload: {} },
      {
        ...base,
        verb: "focus",
        resolvedTargetId: "a1",
        payload: { agentId: "a1" },
      },
      {
        ...base,
        verb: "send",
        resolvedTargetId: "a1",
        payload: { agentId: "a1", text: "continue" },
      },
      {
        ...base,
        verb: "spawn",
        payload: { harness: "codex", cwd: "/repo" },
      },
      {
        ...base,
        verb: "interrupt",
        resolvedTargetId: "a1",
        payload: { agentId: "a1" },
      },
      { ...base, verb: "listen_ctl", payload: { action: "stop" } },
      {
        ...base,
        verb: "dictate",
        resolvedTargetId: "a1",
        payload: { agentId: "a1", text: "run tests" },
      },
      { ...base, verb: "noise", payload: {} },
    ];

    for (const command of commands) {
      expect(FleetCommandSchema.parse(command).verb).toBe(command.verb);
    }
  });

  it("keeps executor and verifier results separate", () => {
    const outcome = CommandOutcomeSchema.parse({
      id: "outcome-1",
      command: {
        verb: "status",
        payload: {},
        confidence: 1,
        rawUtterance: "status",
        resolvedTargetId: null,
      },
      state: "UNVERIFIED",
      executor: { ok: true, evidence: "socket acknowledged" },
      verification: [
        {
          predicate: "fresh snapshot was read",
          passed: false,
          evidence: "snapshot unavailable",
        },
      ],
      latencyMs: { stt: 0, route: 2, act: 1, verify: 4 },
      createdAt: "2026-07-18T05:00:00.000Z",
    });

    expect(outcome.executor?.ok).toBe(true);
    expect(outcome.verification[0]?.passed).toBe(false);
    expect(outcome.state).toBe("UNVERIFIED");
  });

  it("validates the fixture matrix", async () => {
    const raw = await readFile(resolve("fixtures/utterances.json"), "utf8");
    const fixtures = FixtureSchema.parse(JSON.parse(raw));
    const categories = new Set(fixtures.map((fixture) => fixture.category));

    expect(fixtures.length).toBeGreaterThanOrEqual(25);
    expect(categories).toEqual(
      new Set(["clear", "fuzzy", "noise", "destructive"]),
    );
    expect(new Set(fixtures.map((fixture) => fixture.id)).size).toBe(
      fixtures.length,
    );
  });
});

describe("schema exports", () => {
  it("keeps all public schemas serializable", () => {
    expect(FleetSnapshotSchema).toBeDefined();
    expect(FleetCommandSchema).toBeDefined();
    expect(CommandOutcomeSchema).toBeDefined();
    expect(VerificationResultSchema).toBeDefined();
  });
});
