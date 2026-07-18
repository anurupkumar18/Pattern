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

The full runtime and demo commands are added as each build phase lands.
