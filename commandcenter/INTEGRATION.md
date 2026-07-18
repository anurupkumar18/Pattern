# Integrating with the Voice Command Center

This documents the stable surface for external systems (e.g. a personal loop/OS layer) that want to drive the command center or consume its events. Everything below is validated against real Herdr 0.7.4 (protocol 16).

## Run modes

```bash
cd commandcenter && npm install

# Mock fleet (no dependencies):
npm run dev

# Real Herdr fleet:
HERDR_MODE=real HERDR_SOCKET_PATH=~/.config/herdr/herdr.sock npm run dev

# Hackathon-compliant Cactus path. Start the local model server separately:
# cactus serve google/gemma-4-E2B-it --bits 4 --backend metal \
#   --no-cloud-handoff --no-cloud-tele
# Then deterministic answers return immediately and unresolved/noise speech
# escalates to Gemma 4 running in Cactus:
GEMMA_COMMAND=python3 \
GEMMA_ARGS='["scripts/cactus-complete.py"]' \
CACTUS_MODEL=google/gemma-4-E2B-it \
npm run dev

# Development alternative using Ollama:
GEMMA_OLLAMA_MODEL=gemma4 \
GEMMA_OLLAMA_TEMPERATURE=0 \
GEMMA_OLLAMA_NUM_PREDICT=200 \
GEMMA_OLLAMA_THINK=false \
npm run dev

# Generic executable transport for another stdin/stdout runtime:
GEMMA_COMMAND=/path/to/model-wrapper GEMMA_ARGS='["--model","<model>"]' npm run dev
# Generic HTTP inference server accepting {"prompt"} and returning {"output"}:
GEMMA_HTTP_ENDPOINT=http://127.0.0.1:8080/complete npm run dev
```

Gemma configuration enables `CascadeRouter` by default. Omit Gemma
configuration for pure deterministic mode, or add `GEMMA_CASCADE=off` for
pure Gemma mode. `GEMMA_CASCADE_TIMEOUT_MS` controls the cascade deadline
(default 20,000 ms); timeout or model failure returns the deterministic noise
result with `routedBy: "cascade-fallback-failed"` instead of throwing.

The Cactus bridge reads one prompt from stdin, POSTs it to Cactus's
OpenAI-compatible `/v1/chat/completions` endpoint, and writes only the
completion to stdout, so no Cactus-specific TypeScript transport is needed.
Override `CACTUS_ENDPOINT`, `CACTUS_MODEL`, `CACTUS_TEMPERATURE`,
`CACTUS_MAX_TOKENS`, or `CACTUS_TIMEOUT_SECONDS` when needed.

Server listens at `http://127.0.0.1:${PORT:-4173}`; the console UI and the
programmatic WebSocket share the port.

## WebSocket protocol (`/ws`)

Client -> server messages:

| Message | Effect |
| --- | --- |
| `{"type":"utterance","text":"...","sttMs":120}` | Route and execute one utterance. `sttMs` is optional latency attribution from your own speech layer. |
| `{"type":"confirm","outcomeId":"<id>"}` | Approve a command that returned `AWAITING_CONFIRMATION` (destructive verbs and low-confidence routes). |
| `{"type":"snapshot.request"}` | Ask for an immediate fleet snapshot. |

Server -> client events:

| Event | Payload |
| --- | --- |
| `fleet.snapshot` | `snapshot`: agents (id, name, harness, status working/idle/blocked/done, cwd, lastActivity), `focusedAgentId`, `listening` |
| `command.routed` | `command`: the typed FleetCommand (verb, payload, confidence, resolvedTargetId, rawUtterance, optional `routedBy` provenance), `latencyMs` |
| `command.outcome` | `outcome`: id, command, `state` (`AWAITING_CONFIRMATION`, `EXECUTED`, `SUCCEEDED`, `UNVERIFIED`, `FAILED`), executor evidence, verification predicates with pass/fail and observed values, per-stage `latencyMs` (stt/route/act/verify) |
| `server.error` | `message` |

Contract notes:

- `command.outcome` is emitted twice per executed command: once at `EXECUTED`
  (executor returned), once at the final verified state. Wait for a state
  other than `EXECUTED`/`AWAITING_CONFIRMATION` before treating a command as
  done. Only the verifier can produce `SUCCEEDED`.
- All payloads validate against the zod schemas in `src/contracts.ts`
  (JSON Schema exports in `commandcenter/schemas/`). Treat those as the
  source of truth.

## Embedding as a library

`src/index.ts` exports the pieces directly if you would rather host the loop
in-process than over WebSocket:

```ts
import {
  CommandLoop, CascadeRouter, DeterministicRouter, GemmaRouter,
  HerdrAdapter, UnixSocketHerdrTransport, MockHerdr,
} from "voice-command-center";

const control = new HerdrAdapter({
  transport: new UnixSocketHerdrTransport({ socketPath }),
});
const loop = new CommandLoop({ router: new DeterministicRouter(), control });
loop.subscribe(console.log);
await loop.handleUtterance("what needs me right now");
```

`FleetControl` is the seam for non-Herdr fleets: implement `snapshot`,
`focus`, `send`, `spawn`, `interrupt`, `subscribe` against any agent
substrate and the router/verifier/console stack works unchanged.

## Validation status

- Real Herdr: `scripts/smoke-herdr.ts` (snapshot -> spawn -> verify -> send ->
  focus -> verify) passes live; the integration vitest is gated behind
  `RUN_HERDR_INTEGRATION=1`.
- Mock: full suite (`npm test`) and 28-case eval (`npm run eval`) run without
  any installed dependencies.

## Licensing / reuse status

The repo currently has no license file. Reuse outside this repo (including
any personal or public variant) is pending the repo owner adding one (MIT
proposed). Until then, treat this as all-rights-reserved collaborator code.
