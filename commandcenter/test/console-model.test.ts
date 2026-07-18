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
});
