# Four-Minute Voice Command Center Demo

## One-time setup

```bash
cd /Users/cole.segura/brain/.worktrees/pattern-hackathon/commandcenter
npm install
npm test
npm run eval
```

## Start the zero-setup demo

```bash
cd /Users/cole.segura/brain/.worktrees/pattern-hackathon/commandcenter
npm run dev
```

Open `http://127.0.0.1:4173`. MockHerdr starts with two Claude agents, two
Codex agents, one blocked migration agent, and one focused test agent.

Browser speech recognition requires Chrome or another browser exposing the Web
Speech API. The text field uses the identical route, act, and verify path and is
the deterministic fallback.

## Four-minute walkthrough

### 0:00 - The fleet as one surface

Point out the four live agents and the local-only trust strip. The command log
is the primary object: an executor claim appears first, but only an independent
snapshot predicate can turn it green.

Say or type:

> What needs me right now?

Expected: `status`, resolved to the blocked migration agent, with a verified
fresh-snapshot row.

### 0:40 - Resolve and unblock

Say or type:

> Switch to the one that is blocked

Expected: focus moves to Migration Agent and the focus predicate passes.

Then:

> Tell it to use staging not production

Expected: the message lands in Migration Agent's activity, its state changes
to working, and the independent text-delivery predicate passes.

### 1:40 - Spawn a new agent

Say or type:

> Open a new codex in /repos/docs and have it draft the readme

Expected: a new Codex row appears in `/repos/docs`, its initial activity
contains the instruction, and the spawn-specification predicate passes.

### 2:25 - Ambient-noise rejection

Say or type:

> I think we should order pizza

Expected: `noise`, no fleet mutation, and a verified no-op row. Open
`eval-report.md` and point to the zero false-fire rate.

### 3:00 - Destructive confirmation

Say or type:

> Pause the deploy agent

Expected: amber confirmation row and no state change. Click
`Confirm command`. The control plane sends the interrupt, the agent transitions
to idle, and only then does the row become verified.

### 3:40 - Evidence close

Point to:

- heard text, resolved verb, target, confidence, and route latency;
- act and verify latency separated in every command row;
- the live fleet snapshot;
- `UNVERIFIED` fail-closed behavior covered by the lying-executor test;
- `eval-report.md` for category accuracy and noise false-fire evidence.

## Real Herdr

Start Herdr, obtain its socket path, then run:

```bash
cd /Users/cole.segura/brain/.worktrees/pattern-hackathon/commandcenter
HERDR_MODE=real \
HERDR_SOCKET_PATH=/path/to/herdr.sock \
npm run dev
```

Before the demo, verify read-only connectivity:

```bash
RUN_HERDR_INTEGRATION=1 \
HERDR_SOCKET_PATH=/path/to/herdr.sock \
npm test -- herdr.integration.test.ts
```

## Recommended cascade via Ollama HTTP

Start `ollama serve`, ensure `gemma4` is installed, then use the persistent
HTTP transport. With Gemma configured, the command center defaults to the
cascade: deterministic commands return in milliseconds, while deterministic
noise (including unresolved command-shaped speech) escalates to Gemma. The
eval runner makes one untimed warm-up request before collecting route latency:

```bash
GEMMA_OLLAMA_MODEL=gemma4 \
GEMMA_OLLAMA_TEMPERATURE=0 \
GEMMA_OLLAMA_NUM_PREDICT=200 \
GEMMA_OLLAMA_THINK=false \
npm run eval
```

Use the same environment for the live console:

```bash
GEMMA_OLLAMA_MODEL=gemma4 \
GEMMA_OLLAMA_TEMPERATURE=0 \
GEMMA_OLLAMA_NUM_PREDICT=200 \
GEMMA_OLLAMA_THINK=false \
npm run dev
```

For ablation runs, omit all `GEMMA_*` variables for pure deterministic mode.
Set `GEMMA_CASCADE=off` alongside the Gemma variables for pure Gemma mode. The
cascade fallback deadline defaults to 20 seconds and can be changed with
`GEMMA_CASCADE_TIMEOUT_MS`.

## Gemma on Cactus

Install and warm the documented model:

```bash
brew install cactus-compute/cactus/cactus
cactus run google/gemma-4-E2B-it
```

Point the app at a non-interactive local wrapper or HTTP bridge:

```bash
GEMMA_COMMAND=/path/to/cactus-wrapper \
GEMMA_ARGS='["--model","google/gemma-4-E2B-it"]' \
npm run dev
```

or:

```bash
GEMMA_HTTP_ENDPOINT=http://127.0.0.1:8080/complete npm run dev
```

Run model-backed evals with the same environment variable:

```bash
GEMMA_HTTP_ENDPOINT=http://127.0.0.1:8080/complete npm run eval
```
