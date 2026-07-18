import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

import { describe, expect, it } from "vitest";

import type { FleetCommand, FleetSnapshot } from "../src/contracts.js";
import { DeterministicRouter } from "../src/router/deterministic-router.js";
import {
  buildGemmaPrompt,
  GemmaRouter,
  parseGemmaCommand,
} from "../src/router/gemma-router.js";
import type { GemmaTransport } from "../src/router/gemma-transport.js";

interface Fixture {
  id: string;
  category: "clear" | "fuzzy" | "noise" | "destructive";
  utterance: string;
  snapshot: FleetSnapshot;
  expected: Pick<
    FleetCommand,
    "verb" | "resolvedTargetId" | "payload"
  >;
}

describe("DeterministicRouter", () => {
  it("passes every non-fuzzy fixture", async () => {
    const router = new DeterministicRouter();
    const fixtures = await loadFixtures();
    const failures: string[] = [];

    for (const fixture of fixtures.filter(
      ({ category }) => category !== "fuzzy",
    )) {
      const actual = await router.route(fixture.utterance, fixture.snapshot);
      try {
        expect({
          verb: actual.verb,
          resolvedTargetId: actual.resolvedTargetId,
          payload: actual.payload,
        }).toMatchObject(fixture.expected);
      } catch {
        failures.push(
          `${fixture.id}: expected ${JSON.stringify(fixture.expected)}, got ${JSON.stringify(actual)}`,
        );
      }
    }

    expect(failures).toEqual([]);
  });

  it("rejects every ambient-noise fixture", async () => {
    const router = new DeterministicRouter();
    const fixtures = (await loadFixtures()).filter(
      ({ category }) => category === "noise",
    );

    const commands = await Promise.all(
      fixtures.map((fixture) =>
        router.route(fixture.utterance, fixture.snapshot),
      ),
    );
    expect(commands.every(({ verb }) => verb === "noise")).toBe(true);
  });
});

describe("GemmaRouter", () => {
  it("builds a compact prompt with fleet reference context", () => {
    const prompt = buildGemmaPrompt("switch to the blocked one", {
      capturedAt: "2026-07-18T05:00:00.000Z",
      focusedAgentId: null,
      listening: true,
      agents: [
        {
          id: "w1:p1",
          name: "Migration Agent",
          harness: "claude",
          status: "blocked",
          cwd: "/repo",
          lastActivity: {
            summary: "Waiting for input",
            at: "2026-07-18T05:00:00.000Z",
          },
        },
      ],
    });

    expect(prompt).toContain('"id":"w1:p1"');
    expect(prompt).toContain('"status":"blocked"');
    expect(prompt).toContain("Allowed verbs:");
    expect(prompt).toContain('"switch to the blocked one"');
  });

  it("validates strict JSON and retries once", async () => {
    const transport = new QueueTransport([
      "not json",
      JSON.stringify({
        verb: "focus",
        payload: { agentId: "w1:p1" },
        confidence: 0.91,
        rawUtterance: "ignored by parser",
        resolvedTargetId: "w1:p1",
      }),
    ]);
    const router = new GemmaRouter(transport);
    const snapshot: FleetSnapshot = {
      capturedAt: "2026-07-18T05:00:00.000Z",
      focusedAgentId: null,
      listening: true,
      agents: [],
    };

    const command = await router.route("focus migration", snapshot);

    expect(command).toMatchObject({
      verb: "focus",
      rawUtterance: "focus migration",
      resolvedTargetId: "w1:p1",
    });
    expect(transport.prompts).toHaveLength(2);
    expect(transport.prompts[1]).toContain("failed strict validation");
  });

  it("extracts schema-validated JSON from terminal-formatted output", () => {
    const output = [
      "\u001B[?25lThinking...\u001B[?25h",
      "\u001B[1G",
      '{"ver\u001B[?25lb":"status","payload":{},',
      '"confidence":0.9,"rawUtterance":"ignored",',
      '"resolvedTargetId":null}',
      "\u001B[2K",
    ].join("");

    expect(parseGemmaCommand(output, "fleet status")).toMatchObject({
      verb: "status",
      payload: {},
      confidence: 0.9,
      rawUtterance: "fleet status",
      resolvedTargetId: null,
    });
  });

  it("fails closed after one invalid retry", async () => {
    const router = new GemmaRouter(
      new QueueTransport(["{}", '{"verb":"unsupported"}']),
    );

    await expect(
      router.route("do something", {
        capturedAt: "2026-07-18T05:00:00.000Z",
        focusedAgentId: null,
        listening: true,
        agents: [],
      }),
    ).rejects.toThrow();
  });
});

class QueueTransport implements GemmaTransport {
  readonly prompts: string[] = [];

  constructor(private readonly outputs: string[]) {}

  async complete(prompt: string): Promise<string> {
    this.prompts.push(prompt);
    const output = this.outputs.shift();
    if (output === undefined) throw new Error("No queued Gemma output");
    return output;
  }
}

async function loadFixtures(): Promise<Fixture[]> {
  const content = await readFile(resolve("fixtures/utterances.json"), "utf8");
  return JSON.parse(content) as Fixture[];
}
