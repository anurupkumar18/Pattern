import { describe, expect, it } from "vitest";

import {
  buildRows,
  groupRows,
  type ChatEntry,
} from "../console/src/model.js";

const NOW = new Date(2026, 6, 18, 12, 0, 0).getTime();

function chat(
  id: string,
  lastUpdatedAt: number,
  overrides: Partial<ChatEntry> = {},
): ChatEntry {
  return {
    id,
    source: "cursor",
    name: id,
    status: "completed",
    generating: false,
    kind: "human",
    lastUpdatedAt,
    ...overrides,
  };
}

describe("console history model", () => {
  it("groups the unified history into Today, Yesterday, and Earlier", () => {
    const rows = buildRows(
      null,
      [
        chat("today", NOW - 60_000),
        chat("yesterday", NOW - 25 * 60 * 60 * 1_000),
        chat("earlier", NOW - 3 * 24 * 60 * 60 * 1_000),
      ],
      {},
      NOW,
      NOW,
    );

    expect(groupRows(rows, NOW).map(({ label }) => label)).toEqual([
      "Today",
      "Yesterday",
      "Earlier",
    ]);
  });

  it("only marks completions newer than the previous observation as unseen", () => {
    const observedAt = NOW - 60_000;
    const rows = buildRows(
      null,
      [
        chat("old", observedAt - 1),
        chat("new", observedAt + 1),
        chat("seen", observedAt + 2),
      ],
      { seen: observedAt + 2 },
      NOW,
      observedAt,
    );

    expect(rows.find(({ id }) => id === "old")?.doneUnseen).toBe(false);
    expect(rows.find(({ id }) => id === "new")?.doneUnseen).toBe(true);
    expect(rows.find(({ id }) => id === "seen")?.doneUnseen).toBe(false);
  });

  it("keeps aborted chats neutral and separate from attention", () => {
    const [row] = buildRows(
      null,
      [chat("stopped", NOW, { status: "aborted" })],
      {},
      NOW,
      NOW,
    );

    expect(row).toMatchObject({
      stopped: true,
      needsInput: false,
      doneUnseen: false,
    });
  });

  it("keeps automations collapsed at the bottom and omits system rows", () => {
    const rows = buildRows(
      null,
      [
        chat("human", NOW, { kind: "human" }),
        chat("automation", NOW - 1, { kind: "automation" }),
        chat("system", NOW - 2, { kind: "system" }),
      ],
      {},
      NOW,
      NOW,
    );
    const sections = groupRows(rows, NOW);

    expect(sections.map(({ label }) => label)).toEqual([
      "Today",
      "Automations",
    ]);
    expect(sections[0]?.rows.map(({ id }) => id)).toEqual(["human"]);
    expect(sections[1]?.rows.map(({ id }) => id)).toEqual(["automation"]);
  });

  it("shows activity only while a chat is working", () => {
    const rows = buildRows(
      null,
      [
        chat("working", NOW, {
          generating: true,
          activity: "Running tools",
        }),
        chat("idle", NOW - 1, { activity: "Thinking" }),
      ],
      {},
      NOW,
      NOW,
    );

    expect(rows.find(({ id }) => id === "working")?.subtitle).toBe(
      "Running tools",
    );
    expect(rows.find(({ id }) => id === "idle")?.subtitle).toBeNull();
  });

  it("hides smoke and test Herdr agents from the library", () => {
    const rows = buildRows(
      {
        capturedAt: new Date(NOW).toISOString(),
        focusedAgentId: null,
        listening: false,
        agents: [
          {
            id: "smoke",
            name: "smoke-shell",
            harness: "shell",
            status: "working",
            cwd: "/tmp",
            lastActivity: {
              summary: "Synthetic smoke check",
              at: new Date(NOW).toISOString(),
            },
          },
          {
            id: "real",
            name: "builder",
            harness: "codex",
            status: "working",
            cwd: "/tmp",
            lastActivity: {
              summary: "Synthetic build",
              at: new Date(NOW).toISOString(),
            },
          },
        ],
      },
      [],
      {},
      NOW,
      NOW,
    );

    expect(rows.map(({ id }) => id)).toEqual(["real"]);
  });
});
