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

The full runtime and demo commands are added as each build phase lands.
