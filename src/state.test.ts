import { describe, expect, it } from "vitest";
import {
  applyUtterance,
  createProjectState,
  exportStateMarkdown
} from "./state";

describe("voice-to-state pipeline", () => {
  it("preserves every fragment while keeping active state compact", () => {
    let state = createProjectState("2026-07-17T10:00:00.000Z");
    state = applyUtterance(
      state,
      "I want to build a voice agent that remembers the project",
      "2026-07-17T10:00:01.000Z"
    );
    state = applyUtterance(
      state,
      "Wait, forget that",
      "2026-07-17T10:00:02.000Z"
    );

    expect(state.utterances.map((item) => item.text)).toEqual([
      "I want to build a voice agent that remembers the project",
      "Wait, forget that"
    ]);
    expect(state.entities).toHaveLength(1);
    expect(state.entities[0].status).toBe("superseded");
    expect(state.entities[0].revisions).toHaveLength(2);
  });

  it("links a correction to the state item it replaces", () => {
    let state = createProjectState();
    state = applyUtterance(state, "We should use the light screenshots");
    const originalId = state.entities[0].id;
    state = applyUtterance(
      state,
      "Actually, use the dark screenshots instead"
    );

    const original = state.entities.find((item) => item.id === originalId);
    const replacement = state.entities.find(
      (item) => item.id === original?.supersededById
    );

    expect(original?.status).toBe("superseded");
    expect(replacement?.text).toContain("dark screenshots");
    expect(state.utterances).toHaveLength(2);
  });

  it("dispatches commands with all active state as context", () => {
    let state = createProjectState();
    state = applyUtterance(state, "The goal is to ship a reliable demo");
    state = applyUtterance(state, "How will we prove the result?");
    state = applyUtterance(state, "Draft the final project brief");

    expect(state.commands).toHaveLength(1);
    expect(state.commands[0].status).toBe("pending");
    expect(state.commands[0].requiresApproval).toBe(true);
    expect(state.commands[0].suggestedSkill).toBe("content.draft");
    expect(state.commands[0].contextEntityIds).toHaveLength(2);
  });

  it("exports active state and the complete source ledger", () => {
    let state = createProjectState();
    state = applyUtterance(state, "We decided to keep classification local");
    state = applyUtterance(state, "Export the agent brief");

    const markdown = exportStateMarkdown(state);
    expect(markdown).toContain("## Decisions");
    expect(markdown).toContain("keep classification local");
    expect(markdown).toContain("## Complete utterance ledger");
    expect(markdown).toContain("Export the agent brief");
  });
});
