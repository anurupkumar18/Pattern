/**
 * End-to-end smoke test against a real running Herdr server.
 *
 * Usage:
 *   HERDR_SOCKET_PATH=~/.config/herdr/herdr.sock npx tsx scripts/smoke-herdr.ts
 *
 * Exercises the real command path: snapshot -> spawn -> send -> focus,
 * verifying each step with an independent snapshot re-read, mirroring the
 * Verifier's outcome-predicate approach. Exits nonzero on any failure.
 */
import { HerdrAdapter } from "../src/control/herdr-adapter.js";
import { UnixSocketHerdrTransport } from "../src/control/herdr-transport.js";

const socketPath = process.env.HERDR_SOCKET_PATH?.replace(
  /^~/,
  process.env.HOME ?? "~",
);
if (!socketPath) {
  console.error("HERDR_SOCKET_PATH is required");
  process.exit(1);
}

const adapter = new HerdrAdapter({
  transport: new UnixSocketHerdrTransport({ socketPath }),
});

let failures = 0;

function check(label: string, ok: boolean, detail?: string) {
  const mark = ok ? "PASS" : "FAIL";
  console.log(`${mark}  ${label}${detail ? ` — ${detail}` : ""}`);
  if (!ok) failures += 1;
}

const before = await adapter.snapshot();
check(
  "session.snapshot returns a fleet snapshot",
  Array.isArray(before.agents),
  `${before.agents.length} agent(s) visible`,
);

const spawnReceipt = await adapter.spawn({
  harness: "shell",
  cwd: process.env.HOME ?? "/tmp",
  name: "smoke-shell",
  initialMessage: undefined,
});
check("spawn creates a workspace/agent", spawnReceipt.ok, spawnReceipt.evidence);

const afterSpawn = await adapter.snapshot();
const spawned = afterSpawn.agents.find((a) => a.id === spawnReceipt.agentId);
check(
  "verifier re-read sees the spawned agent",
  Boolean(spawned),
  spawned ? `${spawned.name} (${spawned.status})` : `id ${spawnReceipt.agentId} missing`,
);

if (spawned) {
  const sendReceipt = await adapter.send(spawned.id, "echo herdr-smoke-ok");
  check("send delivers text to the pane", sendReceipt.ok, sendReceipt.evidence);

  const focusReceipt = await adapter.focus(spawned.id);
  check("focus targets the pane", focusReceipt.ok, focusReceipt.evidence);

  const afterFocus = await adapter.snapshot();
  check(
    "verifier re-read confirms focus",
    afterFocus.focusedAgentId === spawned.id,
    `focusedAgentId=${afterFocus.focusedAgentId}`,
  );
}

console.log(failures === 0 ? "\nSMOKE OK" : `\nSMOKE FAILED (${failures})`);
process.exit(failures === 0 ? 0 : 1);
