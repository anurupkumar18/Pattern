# Supported write paths for Dictator

Research date: 2026-07-18. Local versions: Claude Code 2.1.181, Codex CLI
0.135.0. `which cursor-agent cursor agent` found none. `CURSOR_API_KEY` is
absent; Claude Code is logged in through the Podium Claude.ai Enterprise
account; Codex is logged in through ChatGPT.

## Capability matrix

| Source / target | Resume in place | Model choice | Live progress | Safe while source app is open | Auth |
| --- | --- | --- | --- | --- | --- |
| Cursor IDE `composerData:<uuid>` chat | **No supported headless path.** IDE composers and SDK/Agent CLI agents use separate stores and IDs. Never write `state.vscdb`. | The IDE record contains `modelConfig`, but there is no supported external setter for that composer. | Existing DB polling can observe IDE writes, not initiate them. | Read-only SQLite/WAL polling is safe, though the large DB can lock or query slowly. | Existing IDE login is not an SDK credential. |
| Cursor SDK-created local agent | **Yes**, `Agent.resume(agentId)` reloads its local checkpoint store, then `agent.send()`. This applies only to SDK/CLI-created agents. | `Cursor.models.list()` returns account-valid IDs and parameters. Pass `model` on resume or per send; a successful per-send override is sticky. | `run.stream()` gives typed messages; `onDelta` gives text/thinking/tool deltas; always finish with `run.wait()`. | Serialize sends per agent. Local `force` is recovery for a stuck persisted run, not normal concurrency. It does not attach to an open IDE composer. | `CURSOR_API_KEY`: user API key or team service-account key. Team Admin keys are unsupported. |
| Claude Code session | **Yes.** `claude -p --resume <id>` reuses the session ID and appends to the same project JSONL. Only `--fork-session` creates a new ID. | `--model <alias-or-full-id>`; optional `--effort`. | `--output-format stream-json --include-partial-messages --verbose` emits structured progress. The same JSONL also grows during the turn. | **Not for the same live session.** Claude documents that two resumes of one session interleave. Use only when dormant and hold a Dictator per-session lock. Other sessions may run concurrently. | Saved Claude.ai Pro/Max/Team/Enterprise login, `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`, or supported cloud-provider auth. |
| Codex CLI session | **Yes.** `codex exec resume <id>` opens the existing rollout in append mode and keeps the thread ID. `codex fork` is the separate-ID operation. | `-m/--model <model>`; a changed model is accepted, with a model-switch warning/instruction. | `--json` emits JSONL events (`thread/turn/item/error`); without it, progress streams on stderr and the final answer on stdout. The rollout file grows too. | **Not for the same live thread.** Distinct sessions are fine, but a second client can append from stale in-memory context. Serialize by thread and reject busy/recently active sessions. | Cached ChatGPT login or OpenAI API-key login. API keys are recommended for unattended automation. |

## Exact weekend commands

Pass prompts on stdin, not the process command line. Spawn argument arrays directly, never
through a shell.
```text
claude -p --resume SESSION_ID --model MODEL \
  --output-format stream-json --include-partial-messages --verbose

codex exec resume --json -m MODEL SESSION_ID -
```

Run Claude from the session's original `cwd`. Direct UUID lookup is scoped to
the originating project and its git worktrees. Dictator must therefore extract
and retain `cwd` from Claude JSONL. Codex UUID lookup is global, but its original
working root and effective sandbox still matter; retain `cwd` from `session_meta`
and launch with the matching root/config.

Do not add `--fork-session`, `--ephemeral`, or Claude
`--no-session-persistence`. Do not silently use dangerous permission-bypass
flags. Codex `exec` defaults to a read-only sandbox; a code-editing composer
needs an explicit, user-visible permission policy later.

## Recommended adapter contract
```ts
interface SendAdapter {
  probe(): Promise<SourceCapability>;
  listModels?(): Promise<ModelOption[]>;
  send(request: SendRequest, emit: (event: SendEvent) => void): Promise<SendResult>;
}

interface SendRequest {
  sessionId: string;
  cwd: string;
  prompt: string;
  model?: string;
  expectedIdleVersion?: string; // mtime/size or DB generation observed before send
}
```

`SourceCapability` should expose `canResume`, `canChooseModel`, `canStream`,
`authState`, `reason`, and allowed actions. `SendEvent` should normalize
`queued`, `started`, `text_delta`, `thinking`, `tool_started`,
`tool_completed`, `needs_input`, `completed`, and `failed`, while retaining the
raw source event for debugging.

Implementation rules:

1. Acquire an in-process lock keyed by `source:sessionId`; refuse if the source
   says generating or `expectedIdleVersion` changed before spawn.
2. Validate UUID, `cwd`, and model against the adapter's discovered allowlist.
3. Spawn with an argv array, send the prompt on stdin, redact environment/logs,
   and kill the child on client cancellation or timeout.
4. Relay CLI/SDK events to WebSocket immediately. Treat the existing pollers as
   durable reconciliation, not the primary stream.
5. After process success, wait until the existing file poller sees the expected
   assistant turn in the same session file, then emit `completed`.
6. On nonzero exit, classify auth, invalid session/cwd, model, permission,
   rate-limit, busy, context-limit, MCP/plugin startup, and corrupt-store errors.

## Per-source implementation

- `ClaudeCodeSendAdapter`: **demo-viable now.** Installed, authenticated, richest
  CLI stream, documented same-ID append semantics. Add `cwd` to discovered chat
  metadata and use the existing 2.5-second selected-transcript refresh as the
  persistence check.
- `CodexCliSendAdapter`: **demo-viable now.** Installed and authenticated. Its
  current CLI supports `exec resume`, `-m`, and `--json`; existing rollout
  polling already resolves the same UUID-suffixed file.
- `CursorIdeSendAdapter`: **disabled capability stub.** Return
  `canResume=false` with “Cursor IDE chats cannot currently be resumed through
  the SDK/CLI.” Keep current read-only DB observation.
- `CursorSdkSendAdapter`: optional future lane for **Dictator-created Cursor
  chats only**. Install `@cursor/sdk`, provision `CURSOR_API_KEY`, persist the
  returned `agentId`, and ingest SDK store/events as a fourth session subtype.
  It cannot upgrade existing IDE rows into writable chats.

## Detection with the current sync

- Claude/Codex selected transcripts are requested every 2.5 seconds and cached
  by `mtime:size`, so same-file appends appear without changing the chat ID.
- Claude/Codex sidebar liveness is coarser: the file source scan runs every 10
  seconds and treats an mtime within 45 seconds as generating.
- Cursor chat discovery polls a roughly 2 GB SQLite DB every 30 seconds; message
  reads query `composerData` plus `bubbleId` rows read-only. This is observation
  only and is too slow to serve as a send stream.
- For demo responsiveness, show normalized child-process events instantly, then
  reconcile against these existing stores.

## Risks and failure modes

- **Forking:** Claude forks only with `--fork-session`; Codex forks only via its
  fork operation. Assert the returned session/thread ID equals the requested ID.
- **Concurrent writers:** same-session Claude writes interleave; Codex can append
  a divergent continuation from stale context. “App open” is fine only when
  that exact session is idle. Default to refusal, not force.
- **Wrong root:** Claude may report “No conversation found” outside the original
  project/worktree. Current `ChatEntry` lacks `cwd`, so this metadata is required.
- **Permissions/auth prompts:** non-interactive runs cannot safely answer an
  unexpected login, workspace-trust, tool-approval, or OAuth browser prompt.
  Preflight auth and fail visibly; never auto-bypass.
- **Model drift:** aliases and entitlements change. Claude/Codex may reject a
  model; Cursor requires `models.list()` rather than hard-coded IDs.
- **Store/DB behavior:** never mutate Cursor SQLite. Retry transient read locks.
  JSONL schemas are internal and may change; parse defensively and ignore a
  partial final line.
- **Latency:** CLI process launch, session reconstruction, hooks/MCP startup,
  hosted inference, and tool calls dominate. Expect first progress before the
  final answer, not instant completion. A persistent Codex app-server or Claude
  Agent SDK can remove repeat startup later, but adds integration scope.

## Fastest demo path

Build **Claude Code send first**: one dormant Claude row, original `cwd`,
`claude -p --resume`, selected model, live `stream-json` relayed into the open
chat, then prove the same JSONL and same session ID gained the response. Add
Codex by swapping argv/event normalization after that proof. Ship Cursor rows
read-only with a clear disabled composer action; there is no supported bridge
from the observed IDE composer UUID to `Agent.resume`.

## Primary sources
- Cursor TypeScript SDK: https://cursor.com/docs/sdk/typescript
- Cursor Python SDK: https://cursor.com/docs/sdk/python
- Cursor staff confirmation of separate IDE/CLI stores:
  https://forum.cursor.com/t/local-ide-agent-chats-and-the-agent-cli-still-use-separate-session-stores/165486
- Claude CLI reference: https://code.claude.com/docs/en/cli-reference
- Claude session semantics: https://code.claude.com/docs/en/sessions
- Codex CLI reference: https://developers.openai.com/codex/cli/reference
- Codex non-interactive mode: https://developers.openai.com/codex/noninteractive
- Codex app-server thread semantics: https://developers.openai.com/codex/app-server
- Codex rollout append implementation:
  https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder.rs
