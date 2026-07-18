# Dictator — Vision (captured 2026-07-18)

Working name: **Dictator**. Tagline direction: "Your word is their command."

Source: Cole's voice fragment, 2026-07-18 morning. This file is the durable
capture; treat it as the product north star for the hackathon build.

## The one-sentence product

Every AI coding chat on your machine — Cursor, Claude Code, Codex CLI — in one
place, wrapped in a genuinely polished interface, driven by voice.

## Quality bar

- The UI must look and feel like **Cursor** or **Codex (ChatGPT work UI)** —
  Cole provided reference screenshots (saved in Cursor assets, copied to
  `docs/design/reference/`). Not "inspired by": that level of polish.
- The Herdr-verbatim terminal aesthetic is **retired** as the visual direction.
  Herdr remains the control plane backend; the terminal look does not carry to
  the product UI.
- Attention to micro-detail is the point: e.g. Cursor shows a tiny animated
  spinner next to each working agent in its sidebar. Dictator needs that grade
  of detail everywhere.

## Explicit feedback on the current console (fix all of these)

1. Red ◉ "aborted" dot reads as an alert; aborted is a neutral state. Status
   semantics must be self-evident without a legend.
2. "Route" button is meaningless to a user. No dev-console artifacts.
3. "server live · 1 agents" is plumbing status. Hide or redesign.
4. Chats limited to 24h; needs full history with sensible grouping
   (today / yesterday / earlier, like Cursor's sidebar).
5. Working chats need the live spinner animation detail.

## Voice interaction design (open questions Cole raised)

- Voice on/off control needs real UI design, including a help affordance:
  hovering/clicking should reveal a TLDR of the command set ("this is what you
  need to know to use this").
- **Live dictation must be visible as it streams in.** Open question: does it
  stream into the focused chat's composer, or into a dedicated global command
  bar? Which chat receives it must never be ambiguous.
- Need a spoken command grammar for: switching between chats, sending the
  composed message, interrupting an agent, creating a new chat, and an
  attention query ("what needs me").

## Operating model for the build

- Fable (main chat) architects, plans, judges. All execution and research runs
  on 5.6 Sol subagents (rules ledger R46).
- Deep research first: how the best products (Cursor itself, Codex, Linear,
  etc.) handle this class of UI; extract real design tokens; produce a spec
  with options for taste-sensitive choices before rebuilding.

## What is already true (do not lose)

- Cursor chats feed works: read-only sqlite poll of Cursor's state db,
  broadcast over WS, 15 chats in last 24h rendered live.
- Claude Code + Codex session stores located (~/.claude/projects,
  ~/.codex/sessions); multi-source provider build in flight.
- Router stack: deterministic + Gemma cascade at 28/28 on fixtures; Cactus
  runtime integrated (hackathon requirement satisfied).
- Herdr adapter validated against real Herdr (spawn/send/focus/interrupt).
