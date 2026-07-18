import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { z } from "zod";

import {
  CommandOutcomeSchema,
  FleetCommandSchema,
  FleetSnapshotSchema,
  VerificationResultSchema,
} from "../src/contracts.js";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const outputDirectory = resolve(root, "schemas");

const schemas = {
  FleetSnapshot: FleetSnapshotSchema,
  FleetCommand: FleetCommandSchema,
  CommandOutcome: CommandOutcomeSchema,
  VerificationResult: VerificationResultSchema,
};

await mkdir(outputDirectory, { recursive: true });

for (const [name, schema] of Object.entries(schemas)) {
  const jsonSchema = z.toJSONSchema(schema, {
    target: "draft-7",
    io: "output",
  });
  await writeFile(
    resolve(outputDirectory, `${name}.json`),
    `${JSON.stringify(jsonSchema, null, 2)}\n`,
  );
}

console.log(`Exported ${Object.keys(schemas).length} schemas to ${outputDirectory}`);
