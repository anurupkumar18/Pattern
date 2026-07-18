import { readFile } from "node:fs/promises";

import { z } from "zod";

import { FleetSnapshotSchema } from "../contracts.js";

export const FixtureCategorySchema = z.enum([
  "clear",
  "fuzzy",
  "noise",
  "destructive",
]);

export const ExpectedCommandSchema = z.object({
  verb: z.enum([
    "status",
    "focus",
    "send",
    "spawn",
    "interrupt",
    "listen_ctl",
    "dictate",
    "noise",
  ]),
  resolvedTargetId: z.string().nullable(),
  payload: z.record(z.string(), z.unknown()),
});

export const UtteranceFixtureSchema = z.object({
  id: z.string().min(1),
  category: FixtureCategorySchema,
  utterance: z.string().min(1),
  snapshot: FleetSnapshotSchema,
  expected: ExpectedCommandSchema,
});

export const UtteranceFixturesSchema = z.array(UtteranceFixtureSchema);

export type FixtureCategory = z.infer<typeof FixtureCategorySchema>;
export type ExpectedCommand = z.infer<typeof ExpectedCommandSchema>;
export type UtteranceFixture = z.infer<typeof UtteranceFixtureSchema>;

export async function loadUtteranceFixtures(
  path: string,
): Promise<UtteranceFixture[]> {
  const content = await readFile(path, "utf8");
  return UtteranceFixturesSchema.parse(JSON.parse(content));
}
