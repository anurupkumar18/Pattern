# Voice Command Center

A local-first voice control plane for a Herdr coding-agent fleet. Spoken or
typed utterances are routed to typed commands, executed through a fleet
adapter, and independently verified before the UI reports success.

## Requirements

- Node.js 20 or newer
- npm

## Setup

```bash
npm install
npm run schema
npm test
npm run build
```

## Contracts

`src/contracts.ts` is the Zod source of truth for fleet snapshots, all eight
command verbs, executor results, verifier verdicts, and command outcomes.
`npm run schema` regenerates the four committed JSON Schemas in `schemas/`.
The utterance matrix in `fixtures/utterances.json` contains clear, fuzzy,
ambient-noise, and destructive cases.

## Fleet control

`MockHerdr` is the default, fully in-memory control plane. `HerdrAdapter` uses
the documented raw Herdr socket methods (`session.snapshot`, `agent.focus`,
`agent.send`, `workspace.create`, `agent.start`, `pane.send_keys`, and
`events.subscribe`) through a newline-delimited Unix socket transport.

Real Herdr smoke tests are opt-in:

```bash
RUN_HERDR_INTEGRATION=1 \
HERDR_SOCKET_PATH=/path/to/herdr.sock \
npm test -- herdr.integration.test.ts
```

## Routing

`DeterministicRouter` is the no-model baseline. It handles every clear,
destructive, and noise fixture and includes bounded target resolution.
`GemmaRouter` builds a compressed fleet prompt, accepts strict schema-validated
JSON, retries malformed output once, and then fails closed.

Two local Gemma transport seams are available:

- `ExecGemmaTransport`: runs a configured command, writes the prompt to stdin,
  and expects one FleetCommand JSON object on stdout.
- `HttpGemmaTransport`: POSTs `{ "prompt": "..." }` to a local endpoint and
  accepts `{ "output": "..." }`, `{ "text": "..." }`, or plain text.

## Verified command loop

`CommandLoop` routes an utterance, gates interrupt and low-confidence commands,
executes through `FleetControl`, and emits typed stage events. `Verifier`
performs a separate snapshot read and owns the only transition to `SUCCEEDED`.
An executor acknowledgement without a passing predicate becomes `UNVERIFIED`.

## Live console

Start the Vite/React console, Node control server, and WebSocket bridge:

```bash
npm run dev
```

Open `http://127.0.0.1:4173`. MockHerdr and the deterministic router are the
zero-setup defaults. The browser can submit Web Speech API transcripts or typed
utterances through the same command loop.

Use real Herdr:

```bash
HERDR_MODE=real HERDR_SOCKET_PATH=/path/to/herdr.sock npm run dev
```

Use a local Gemma bridge:

```bash
GEMMA_HTTP_ENDPOINT=http://127.0.0.1:8080/complete npm run dev
```

or:

```bash
GEMMA_COMMAND=/path/to/cactus-wrapper \
GEMMA_ARGS='["--model","google/gemma-4-E2B-it"]' \
npm run dev
```
