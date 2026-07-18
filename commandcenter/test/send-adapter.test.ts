import { mkdtemp, mkdir, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { afterEach, describe, expect, it } from "vitest";

import {
  extractSessionCwd,
  locateSessionFile,
} from "../src/control/send-adapter.js";

const CLAUDE_ID = "11111111-1111-4111-8111-111111111111";
const CODEX_ID = "22222222-2222-4222-8222-222222222222";
const temporaryRoots: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryRoots.splice(0).map((path) => rm(path, { recursive: true })),
  );
});

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "send-adapter-"));
  temporaryRoots.push(root);
  return root;
}

describe("locateSessionFile", () => {
  it("locates Claude's exact project-scoped session file", async () => {
    const root = await temporaryRoot();
    const project = join(root, "-Users-test-project");
    await mkdir(project);
    const expected = join(project, `${CLAUDE_ID}.jsonl`);
    await writeFile(expected, "{}\n");
    await writeFile(join(project, "unrelated.jsonl"), "{}\n");

    await expect(
      locateSessionFile("claude", `claude:${CLAUDE_ID}`, {
        claudeRoot: root,
      }),
    ).resolves.toBe(expected);
  });

  it("locates Codex's UUID-suffixed rollout file", async () => {
    const root = await temporaryRoot();
    const day = join(root, "2026", "07", "18");
    await mkdir(day, { recursive: true });
    const older = join(day, `rollout-2026-07-18T01-00-00-${CODEX_ID}.jsonl`);
    const expected = join(
      day,
      `rollout-2026-07-18T02-00-00-${CODEX_ID}.jsonl`,
    );
    await writeFile(older, "{}\n");
    await writeFile(expected, "{}\n");
    const oldTime = new Date("2026-07-18T01:00:00Z");
    const newTime = new Date("2026-07-18T02:00:00Z");
    await utimes(older, oldTime, oldTime);
    await utimes(expected, newTime, newTime);

    await expect(
      locateSessionFile("codex", CODEX_ID, { codexRoot: root }),
    ).resolves.toBe(expected);
  });

  it("rejects malformed session ids", async () => {
    await expect(locateSessionFile("claude", "../bad-id")).rejects.toThrow(
      "invalid",
    );
  });
});

describe("extractSessionCwd", () => {
  it("extracts the latest Claude cwd while ignoring partial JSON", () => {
    const content = [
      JSON.stringify({ type: "user", cwd: "/tmp/old" }),
      JSON.stringify({ type: "assistant", cwd: "/tmp/current" }),
      '{"type":"assistant"',
    ].join("\n");

    expect(extractSessionCwd("claude", content)).toBe("/tmp/current");
  });

  it("extracts Codex cwd from session_meta payload only", () => {
    const content = [
      JSON.stringify({ type: "event_msg", payload: { cwd: "/tmp/wrong" } }),
      JSON.stringify({
        type: "session_meta",
        payload: { id: CODEX_ID, cwd: "/tmp/codex-project" },
      }),
    ].join("\n");

    expect(extractSessionCwd("codex", content)).toBe("/tmp/codex-project");
  });

  it("returns null when cwd metadata is absent", () => {
    expect(extractSessionCwd("claude", '{"type":"summary"}')).toBeNull();
  });
});
