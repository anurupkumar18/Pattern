# Voice-to-State Prototype

Voice becomes durable state before an agent acts.

This is a hackathon prototype for developers who think out loud. It streams
speech into an append-only utterance ledger, classifies each final fragment as
a state operation, maintains a compact project state, and queues executable
commands with approval and full context.

The core difference from screen-aware assistants such as HeyClicky is the
input contract: the prototype does not treat speech as a disposable prompt. It
keeps the original words, the structured interpretation, every correction, and
the provenance connecting them.

## Run locally

```bash
npm install
npm run dev
```

Open the printed localhost URL in Chrome. Chrome provides the browser speech
recognition API used by the prototype. Other browsers can test the complete
state loop through the typed-fragment field. Browser speech recognition may
process audio remotely; the current local-only guarantee applies to structured
state and classification, not transcription.

```bash
npm test
npm run build
```

## Current vertical slice

- Live interim speech appears as you talk.
- Every final fragment is preserved in an append-only ledger.
- A deterministic local classifier maps fragments to `add`, `amend`,
  `supersede`, `resolve`, `command`, or `noise`.
- Active state is grouped into goals, tasks, decisions, and open questions.
- Corrections never delete their source. They mark old state as superseded and
  retain the full revision chain.
- Commands enter an approval queue with a suggested skill route and links to
  all active context.
- The complete JSON contract and a portable Markdown agent brief can be
  exported from the UI.
- State survives browser refresh through local storage.

The deterministic classifier is deliberate scaffolding for the first working
loop. Its interface is the replacement boundary for a local Gemma model.

## Shared integration contract

The UI and state pipeline own `ProjectState` in
[`src/types.ts`](src/types.ts). The executor can consume:

- `entities[]` for current goals, tasks, decisions, and questions
- `commands[]` for approved or pending actions
- `utterances[]` for lossless source context
- `events[]` for operation telemetry and provenance

Cole's branch writes this contract. The executor branch should read it and
append execution and verification status without rewriting the utterance
ledger.

## Product document

Read [`docs/PRD.md`](docs/PRD.md) for the complete concept, demo sequence,
ownership split, rubric mapping, and scope guards.
