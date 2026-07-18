import { writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { evaluateRouter, type RouterEvalReport } from "../src/eval/evaluator.js";
import {
  loadUtteranceFixtures,
  type UtteranceFixture,
} from "../src/eval/fixtures.js";
import { DeterministicRouter } from "../src/router/deterministic-router.js";
import { GemmaRouter } from "../src/router/gemma-router.js";
import {
  ExecGemmaTransport,
  HttpGemmaTransport,
  OllamaHttpGemmaTransport,
  type GemmaTransport,
} from "../src/router/gemma-transport.js";
import type { Router } from "../src/router/router.js";

class StaticGemmaTransport implements GemmaTransport {
  constructor(private readonly output: string) {}

  async complete(): Promise<string> {
    return this.output;
  }
}

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const fixtures = await loadUtteranceFixtures(
  resolve(root, "fixtures/utterances.json"),
);
const generatedAt = new Date().toISOString();

const deterministic = await evaluateRouter(
  fixtures,
  () => new DeterministicRouter(),
  { backend: "deterministic-grammar", modelEvidence: false },
);

const gemmaMode = createGemmaMode();
await gemmaMode.warmUp?.();
const gemma = await evaluateRouter(fixtures, gemmaMode.routerFor, {
  backend: gemmaMode.backend,
  modelEvidence: gemmaMode.modelEvidence,
});

const report = {
  generatedAt,
  fixtureCount: fixtures.length,
  caveat: gemmaMode.modelEvidence
    ? "Gemma results came from the configured local runtime."
    : "Gemma results use a fixture-oracle mock to validate the prompt, parser, retry seam, command loop, and verifier. They are not model-quality evidence.",
  routers: { deterministic, gemma },
};

await writeFile(
  resolve(root, "eval-report.json"),
  `${JSON.stringify(report, null, 2)}\n`,
);
await writeFile(
  resolve(root, "eval-report.md"),
  renderMarkdown(generatedAt, fixtures.length, deterministic, gemma, report.caveat),
);

console.log(
  [
    `Evaluated ${fixtures.length} fixtures`,
    `Deterministic: ${percent(deterministic.summary.accuracy)} accuracy, ${percent(deterministic.falseFireRate)} noise false-fire`,
    `Gemma (${gemma.backend}): ${percent(gemma.summary.accuracy)} accuracy, ${percent(gemma.falseFireRate)} noise false-fire`,
    `Wrote ${resolve(root, "eval-report.json")} and eval-report.md`,
  ].join("\n"),
);

function createGemmaMode(): {
  backend: string;
  modelEvidence: boolean;
  routerFor: (fixture: UtteranceFixture) => Router;
  warmUp?: () => Promise<void>;
} {
  let transport: GemmaTransport | null = null;
  let backend = "fixture-oracle-mock";
  let modelEvidence = false;

  if (process.env.GEMMA_OLLAMA_MODEL) {
    transport = new OllamaHttpGemmaTransport({
      model: process.env.GEMMA_OLLAMA_MODEL,
      endpoint: process.env.GEMMA_OLLAMA_ENDPOINT,
      temperature: optionalNumber("GEMMA_OLLAMA_TEMPERATURE"),
      numPredict: optionalNumber("GEMMA_OLLAMA_NUM_PREDICT"),
      think: optionalBoolean("GEMMA_OLLAMA_THINK"),
    });
    backend = `ollama-http:${process.env.GEMMA_OLLAMA_MODEL}`;
    modelEvidence = true;
  } else if (process.env.GEMMA_HTTP_ENDPOINT) {
    transport = new HttpGemmaTransport({
      endpoint: process.env.GEMMA_HTTP_ENDPOINT,
    });
    backend = `local-http:${process.env.GEMMA_HTTP_ENDPOINT}`;
    modelEvidence = true;
  } else if (process.env.GEMMA_COMMAND) {
    transport = new ExecGemmaTransport({
      command: process.env.GEMMA_COMMAND,
      args: process.env.GEMMA_ARGS
        ? (JSON.parse(process.env.GEMMA_ARGS) as string[])
        : [],
    });
    backend = `local-exec:${process.env.GEMMA_COMMAND}`;
    modelEvidence = true;
  }

  return {
    backend,
    modelEvidence,
    warmUp: transport
      ? async () => {
          await transport.complete('Return exactly this JSON: {"warm":true}');
        }
      : undefined,
    routerFor: transport
      ? () => new GemmaRouter(transport)
      : (fixture) =>
          new GemmaRouter(
            new StaticGemmaTransport(
              JSON.stringify({
                ...fixture.expected,
                confidence: 0.99,
                rawUtterance: fixture.utterance,
              }),
            ),
          ),
  };
}

function optionalNumber(name: string): number | undefined {
  const value = process.env[name];
  if (value === undefined) return undefined;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) {
    throw new Error(`${name} must be a finite number`);
  }
  return parsed;
}

function optionalBoolean(name: string): boolean | undefined {
  const value = process.env[name];
  if (value === undefined) return undefined;
  if (value === "true") return true;
  if (value === "false") return false;
  throw new Error(`${name} must be true or false`);
}

function renderMarkdown(
  timestamp: string,
  count: number,
  deterministic: RouterEvalReport,
  gemma: RouterEvalReport,
  caveat: string,
): string {
  return `# Voice Command Center Eval

Generated: ${timestamp}

Fixtures: ${count}

## Summary

- Deterministic router: ${deterministic.summary.correct}/${deterministic.summary.cases} (${percent(deterministic.summary.accuracy)})
- Gemma router (${gemma.backend}): ${gemma.summary.correct}/${gemma.summary.cases} (${percent(gemma.summary.accuracy)})
- Deterministic noise false-fire rate: ${percent(deterministic.falseFireRate)}
- Gemma noise false-fire rate: ${percent(gemma.falseFireRate)}
- Deterministic end-to-end verified: ${percent(deterministic.endToEndSuccessRate)}
- Gemma end-to-end verified: ${percent(gemma.endToEndSuccessRate)}

> ${caveat}

## Accuracy by category

| Router | Clear | Fuzzy | Noise | Destructive |
| --- | ---: | ---: | ---: | ---: |
| Deterministic | ${category(deterministic, "clear")} | ${category(deterministic, "fuzzy")} | ${category(deterministic, "noise")} | ${category(deterministic, "destructive")} |
| Gemma | ${category(gemma, "clear")} | ${category(gemma, "fuzzy")} | ${category(gemma, "noise")} | ${category(gemma, "destructive")} |

## Latency

| Router | Route p50 | Route p95 | Act p50 | Verify p50 | Total p50 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Deterministic | ${milliseconds(deterministic.latencyMs.route.p50)} | ${milliseconds(deterministic.latencyMs.route.p95)} | ${milliseconds(deterministic.latencyMs.act.p50)} | ${milliseconds(deterministic.latencyMs.verify.p50)} | ${milliseconds(deterministic.latencyMs.total.p50)} |
| Gemma | ${milliseconds(gemma.latencyMs.route.p50)} | ${milliseconds(gemma.latencyMs.route.p95)} | ${milliseconds(gemma.latencyMs.act.p50)} | ${milliseconds(gemma.latencyMs.verify.p50)} | ${milliseconds(gemma.latencyMs.total.p50)} |

Per-case expected/actual commands, errors, outcomes, and stage timings are in \`eval-report.json\`.
`;
}

function category(
  report: RouterEvalReport,
  name: "clear" | "fuzzy" | "noise" | "destructive",
): string {
  const value = report.categories[name];
  return `${value.correct}/${value.cases} (${percent(value.accuracy)})`;
}

function percent(value: number): string {
  return `${(value * 100).toFixed(1)}%`;
}

function milliseconds(value: number): string {
  return `${value.toFixed(2)} ms`;
}
