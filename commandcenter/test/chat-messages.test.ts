import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  ChatMessagesError,
  ChatMessagesService,
  parseChatMessagesRequest,
  parseClaudeMessages,
  parseCodexMessages,
  parseCursorBubbleRows,
} from "../src/control/chat-messages.js";

const SESSION_ID = "019f7028-8aa8-79c0-837a-aabc985422b7";
const temporaryRoots: string[] = [];

function jsonl(...records: unknown[]): string {
  return records.map((record) => JSON.stringify(record)).join("\n");
}

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((root) => rm(root, { recursive: true })),
  );
});

describe("parseCursorBubbleRows", () => {
  it("keeps ordered visible user and assistant text only", () => {
    const messages = parseCursorBubbleRows([
      {
        ordinal: 4,
        bubbleId: "assistant-duplicate",
        type: 2,
        createdAt: "2026-07-18T12:00:02Z",
        text: "Visible answer",
      },
      {
        ordinal: 1,
        bubbleId: "hidden-thinking",
        type: 2,
        text: "private reasoning",
        hidden: 1,
      },
      {
        ordinal: 0,
        bubbleId: "user-1",
        type: 1,
        createdAt: "2026-07-18T12:00:00Z",
        text: "Visible question",
      },
      {
        ordinal: 3,
        bubbleId: "assistant-1",
        type: 2,
        createdAt: "2026-07-18T12:00:02Z",
        text: "Visible answer",
      },
      {
        ordinal: 2,
        bubbleId: "hidden-tool",
        type: 2,
        text: "tool payload",
        hidden: 1,
      },
    ]);

    expect(messages).toEqual([
      {
        id: "user-1",
        role: "user",
        text: "Visible question",
        createdAt: "2026-07-18T12:00:00.000Z",
      },
      {
        id: "assistant-1",
        role: "assistant",
        text: "Visible answer",
        createdAt: "2026-07-18T12:00:02.000Z",
      },
    ]);
  });

  it("flattens only visible rich-text nodes", () => {
    const messages = parseCursorBubbleRows([
      {
        ordinal: 0,
        bubbleId: "rich-user",
        type: 1,
        richText: JSON.stringify({
          children: [
            { type: "text", text: "First" },
            { type: "thinking", text: "hidden" },
            { type: "text", text: "Second" },
          ],
        }),
      },
    ]);
    expect(messages[0]?.text).toBe("First\nSecond");
  });
});

describe("parseClaudeMessages", () => {
  it("supports string and array content while excluding hidden blocks", () => {
    const messages = parseClaudeMessages(
      jsonl(
        {
          type: "user",
          uuid: "u1",
          timestamp: "2026-07-18T12:00:00Z",
          message: { role: "user", content: "Visible question" },
        },
        {
          type: "assistant",
          uuid: "a1",
          timestamp: "2026-07-18T12:00:01Z",
          message: {
            role: "assistant",
            content: [
              { type: "thinking", thinking: "private" },
              { type: "text", text: "Visible answer" },
              { type: "tool_use", name: "Read", input: { path: "/secret" } },
            ],
          },
        },
        {
          type: "user",
          uuid: "tool-result",
          sourceToolAssistantUUID: "a1",
          toolUseResult: { result: "private" },
          message: {
            role: "user",
            content: [{ type: "text", text: "tool result text" }],
          },
        },
        {
          type: "system",
          content: "system prompt",
        },
      ),
    );

    expect(messages.map(({ role, text }) => ({ role, text }))).toEqual([
      { role: "user", text: "Visible question" },
      { role: "assistant", text: "Visible answer" },
    ]);
  });

  it("ignores a partial trailing line but rejects middle corruption", () => {
    const partial =
      jsonl({
        type: "user",
        message: { role: "user", content: "Visible" },
      }) + '\n{"type":"assistant"';
    expect(parseClaudeMessages(partial)).toHaveLength(1);
    expect(() =>
      parseClaudeMessages(
        '{"type":"user"\n' +
          jsonl({
            type: "assistant",
            message: {
              role: "assistant",
              content: [{ type: "text", text: "answer" }],
            },
          }),
      ),
    ).toThrow(ChatMessagesError);
  });
});

describe("parseCodexMessages", () => {
  it("uses visible event messages and excludes reasoning and tools", () => {
    const messages = parseCodexMessages(
      jsonl(
        {
          timestamp: "2026-07-18T12:00:00Z",
          type: "session_meta",
          payload: { base_instructions: "system prompt" },
        },
        {
          timestamp: "2026-07-18T12:00:01Z",
          type: "event_msg",
          payload: { type: "user_message", message: "Visible question" },
        },
        {
          timestamp: "2026-07-18T12:00:02Z",
          type: "event_msg",
          payload: { type: "agent_reasoning", text: "private reasoning" },
        },
        {
          timestamp: "2026-07-18T12:00:03Z",
          type: "response_item",
          payload: {
            type: "function_call",
            name: "read_file",
            arguments: "/secret",
          },
        },
        {
          timestamp: "2026-07-18T12:00:04Z",
          type: "event_msg",
          payload: {
            type: "agent_message",
            phase: "final_answer",
            message: "Visible answer",
          },
        },
        {
          timestamp: "2026-07-18T12:00:04Z",
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "Visible answer" }],
          },
        },
      ),
    );
    expect(messages.map(({ role, text }) => ({ role, text }))).toEqual([
      { role: "user", text: "Visible question" },
      { role: "assistant", text: "Visible answer" },
    ]);
  });

  it("falls back to response_item messages and rejects developer content", () => {
    const messages = parseCodexMessages(
      jsonl(
        {
          type: "response_item",
          payload: {
            type: "message",
            role: "developer",
            content: [{ type: "input_text", text: "hidden instructions" }],
          },
        },
        {
          type: "response_item",
          payload: {
            type: "message",
            role: "user",
            content: [
              { type: "input_text", text: "Visible question" },
              { type: "input_image", image_url: "private attachment" },
            ],
          },
        },
        {
          type: "response_item",
          payload: {
            type: "reasoning",
            summary: [{ type: "summary_text", text: "private" }],
          },
        },
        {
          type: "response_item",
          payload: {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: "Visible answer" }],
          },
        },
      ),
    );
    expect(messages.map(({ role, text }) => ({ role, text }))).toEqual([
      { role: "user", text: "Visible question" },
      { role: "assistant", text: "Visible answer" },
    ]);
  });
});

describe("ChatMessagesService errors", () => {
  it("returns a local not-found error for a missing session", async () => {
    const root = await mkdtemp(join(tmpdir(), "dictator-missing-"));
    temporaryRoots.push(root);
    const service = new ChatMessagesService({ claudeRoot: root });
    await expect(service.read("claude", `claude:${SESSION_ID}`)).rejects.toMatchObject({
      code: "not_found",
    });
  });

  it("returns a local parse error for a corrupt session", async () => {
    const root = await mkdtemp(join(tmpdir(), "dictator-corrupt-"));
    temporaryRoots.push(root);
    const project = join(root, "project");
    await mkdir(project);
    await writeFile(join(project, `${SESSION_ID}.jsonl`), "{not-json", "utf8");
    const service = new ChatMessagesService({ claudeRoot: root });
    await expect(service.read("claude", `claude:${SESSION_ID}`)).rejects.toMatchObject({
      code: "parse_error",
    });
  });
});

describe("chat.messages protocol", () => {
  it("accepts a valid selected-chat request", () => {
    expect(
      parseChatMessagesRequest({
        type: "chat.messages.request",
        source: "codex",
        chatId: `codex:${SESSION_ID}`,
      }),
    ).toEqual({
      type: "chat.messages.request",
      source: "codex",
      chatId: `codex:${SESSION_ID}`,
    });
  });

  it("rejects invalid sources and session ids", () => {
    expect(
      parseChatMessagesRequest({
        type: "chat.messages.request",
        source: "other",
        chatId: SESSION_ID,
      }),
    ).toBeNull();
    expect(() =>
      parseChatMessagesRequest({
        type: "chat.messages.request",
        source: "cursor",
        chatId: "cursor:../../state.vscdb",
      }),
    ).toThrow(ChatMessagesError);
  });
});
