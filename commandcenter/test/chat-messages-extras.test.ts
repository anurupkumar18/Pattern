import { describe, expect, it } from "vitest";

import {
  parseClaudeMessages,
  parseCodexMessages,
  parseCursorBubbleRows,
} from "../src/control/chat-messages.js";

function jsonl(...records: unknown[]): string {
  return records.map((record) => JSON.stringify(record)).join("\n");
}

describe("chat message extras", () => {
  it("reads Cursor thinking and tool labels without exposing tool arguments", () => {
    const messages = parseCursorBubbleRows([
      {
        ordinal: 0,
        bubbleId: "assistant-1",
        type: 2,
        text: "Finished.",
        thinking: { text: "Compare the available options." },
        toolFormerData: {
          name: "read_file",
          arguments: { path: "/private/example" },
        },
        hidden: 1,
      },
    ]);

    expect(messages[0]?.extras).toEqual([
      { kind: "thinking", text: "Compare the available options." },
      { kind: "activity", label: "Used read file" },
    ]);
    expect(JSON.stringify(messages[0]?.extras)).not.toContain("/private/example");
  });

  it("carries Claude tool activity into the next visible assistant message", () => {
    const messages = parseClaudeMessages(
      jsonl(
        {
          type: "assistant",
          uuid: "tool",
          message: {
            role: "assistant",
            content: [{ type: "tool_use", name: "WebSearch", input: {} }],
          },
        },
        {
          type: "assistant",
          uuid: "answer",
          message: {
            role: "assistant",
            content: [
              { type: "thinking", thinking: "Review the search result." },
              { type: "text", text: "Here is the answer." },
            ],
          },
        },
      ),
    );

    expect(messages[0]?.extras).toEqual([
      { kind: "activity", label: "Used WebSearch" },
      { kind: "thinking", text: "Review the search result." },
    ]);
  });

  it("attaches Codex reasoning and function activity to its visible answer", () => {
    const messages = parseCodexMessages(
      jsonl(
        {
          type: "event_msg",
          payload: {
            type: "agent_reasoning",
            text: "Choose the smallest safe change.",
          },
        },
        {
          type: "response_item",
          payload: {
            type: "function_call",
            name: "read_file",
            arguments: "{}",
          },
        },
        {
          type: "event_msg",
          payload: { type: "agent_message", message: "Done." },
        },
      ),
    );

    expect(messages[0]?.extras).toEqual([
      { kind: "thinking", text: "Choose the smallest safe change." },
      { kind: "activity", label: "Used read file" },
    ]);
  });
});
