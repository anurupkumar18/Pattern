import { describe, expect, it } from "vitest";

import { COMMAND_CENTER_VERSION } from "../src/index.js";

describe("command center scaffold", () => {
  it("exports a version", () => {
    expect(COMMAND_CENTER_VERSION).toMatch(/^\d+\.\d+\.\d+$/);
  });
});
