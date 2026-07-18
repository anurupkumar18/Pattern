import { describe, expect, it } from "vitest";

import {
  mergeChatEntries,
  parseClaudeSession,
  parseCodexSession,
  type ChatEntry,
} from "../src/control/chat-sources.js";

const NOW = Date.UTC(2026, 6, 18, 12, 0, 0);

function jsonl(...records: unknown[]): string {
  return records.map((record) => JSON.stringify(record)).join("\n");
}

describe("parseClaudeSession", () => {
  it("prefers the summary title over the first user message", () => {
    const content = jsonl(
      { type: "summary", summary: "Fix librarian dedupe", sessionId: "abc" },
      {
        type: "user",
        sessionId: "abc",
        message: { role: "user", content: "hello there" },
      },
    );
    const entry = parseClaudeSession(
      content,
      "/x/abc.jsonl",
      NOW - 130_000,
      NOW,
    );
    expect(entry).toMatchObject({
      id: "claude:abc",
      source: "claude",
      name: "Fix librarian dedupe",
      generating: false,
      lastUpdatedAt: NOW - 130_000,
    });
  });

  it("falls back to a truncated first user message", () => {
    const longMessage = "a".repeat(80);
    const content = jsonl({
      type: "user",
      message: { role: "user", content: longMessage },
    });
    const entry = parseClaudeSession(content, "/x/def.jsonl", NOW, NOW);
    expect(entry?.name).toHaveLength(60);
    expect(entry?.name.endsWith("...")).toBe(true);
    expect(entry?.id).toBe("claude:def");
  });

  it("reads text out of content-part arrays and skips harness-injected text", () => {
    const content = jsonl(
      {
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "<local-command-caveat>ignore" }],
        },
      },
      {
        type: "user",
        message: {
          role: "user",
          content: [{ type: "text", text: "real question" }],
        },
      },
    );
    const entry = parseClaudeSession(content, "/x/ghi.jsonl", NOW, NOW);
    expect(entry?.name).toBe("real question");
  });

  it("marks recently-touched sessions as generating", () => {
    const content = jsonl({
      type: "user",
      message: { role: "user", content: "still going" },
    });
    const entry = parseClaudeSession(content, "/x/jkl.jsonl", NOW - 10_000, NOW);
    expect(entry?.generating).toBe(true);
    const stale = parseClaudeSession(
      content,
      "/x/jkl.jsonl",
      NOW - 130_000,
      NOW,
    );
    expect(stale?.generating).toBe(false);
    expect(stale?.status).toBe("completed");
  });

  it("returns null when no title can be derived", () => {
    const content = jsonl({ type: "mode", mode: "normal" });
    expect(parseClaudeSession(content, "/x/mno.jsonl", NOW, NOW)).toBeNull();
  });

  it("survives a truncated trailing line", () => {
    const content =
      jsonl({ type: "user", message: { role: "user", content: "ok" } }) +
      '\n{"type":"assistant","mess';
    const entry = parseClaudeSession(content, "/x/pqr.jsonl", NOW, NOW);
    expect(entry?.name).toBe("ok");
  });
});

describe("parseCodexSession", () => {
  const rolloutPath =
    "/x/rollout-2026-07-17T06-58-53-019f7028-8aa8-79c0-837a-aabc985422b7.jsonl";

  it("uses session_meta id and the first user_message event", () => {
    const content = jsonl(
      {
        timestamp: "2026-07-17T12:58:58.760Z",
        type: "session_meta",
        payload: { session_id: "019f7028-aaaa", cwd: "/Users/x" },
      },
      {
        type: "event_msg",
        payload: { type: "user_message", message: "check the eval results" },
      },
    );
    const entry = parseCodexSession(content, rolloutPath, NOW - 3_600_000, NOW);
    expect(entry).toMatchObject({
      id: "codex:019f7028-aaaa",
      source: "codex",
      name: "check the eval results",
      generating: false,
    });
  });

  it("falls back to the rollout uuid when session_meta is missing", () => {
    const content = jsonl({
      type: "event_msg",
      payload: { type: "user_message", message: "hi" },
    });
    const entry = parseCodexSession(content, rolloutPath, NOW, NOW);
    expect(entry?.id).toBe("codex:019f7028-8aa8-79c0-837a-aabc985422b7");
  });

  it("collapses whitespace in multi-line prompts", () => {
    const content = jsonl({
      type: "event_msg",
      payload: {
        type: "user_message",
        message: "Automation: Ambient Brain morning startup\nAutomation ID: x",
      },
    });
    const entry = parseCodexSession(content, rolloutPath, NOW, NOW);
    expect(entry?.name).toBe(
      "Automation: Ambient Brain morning startup Automation ID: x",
    );
  });
});

describe("mergeChatEntries", () => {
  it("sorts newest first across sources", () => {
    const entry = (source: ChatEntry["source"], at: number): ChatEntry => ({
      id: `${source}:${at}`,
      source,
      name: "n",
      status: "completed",
      generating: false,
      lastUpdatedAt: at,
    });
    const merged = mergeChatEntries([
      entry("claude", 10),
      entry("cursor", 30),
      entry("codex", 20),
    ]);
    expect(merged.map((chat) => chat.source)).toEqual([
      "cursor",
      "codex",
      "claude",
    ]);
  });

  it("keeps the newest record when session ids repeat", () => {
    const older: ChatEntry = {
      id: "codex:repeat",
      source: "codex",
      name: "older title",
      status: "completed",
      generating: false,
      lastUpdatedAt: 10,
    };
    const newer: ChatEntry = {
      ...older,
      name: "newer title",
      generating: true,
      lastUpdatedAt: 20,
    };

    expect(mergeChatEntries([older, newer])).toEqual([newer]);
  });
});
