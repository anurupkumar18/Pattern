import { describe, expect, it } from "vitest";

import { HerdrAdapter } from "../src/control/herdr-adapter.js";
import { UnixSocketHerdrTransport } from "../src/control/herdr-transport.js";

const enabled = process.env.RUN_HERDR_INTEGRATION === "1";

describe.skipIf(!enabled)("real Herdr integration", () => {
  it("reads a schema-compatible live snapshot", async () => {
    const socketPath = process.env.HERDR_SOCKET_PATH;
    if (!socketPath) {
      throw new Error(
        "HERDR_SOCKET_PATH is required when RUN_HERDR_INTEGRATION=1",
      );
    }
    const adapter = new HerdrAdapter({
      transport: new UnixSocketHerdrTransport({ socketPath }),
    });

    const snapshot = await adapter.snapshot();
    expect(snapshot.capturedAt).toBeTruthy();
    expect(Array.isArray(snapshot.agents)).toBe(true);
  });
});
