# Dictator UI specification

Status: execution-ready design specification  
Product: **Dictator**  
Tagline: **Your word is their command.**  
Primary job: see every local AI coding chat, notice what needs attention, and direct the right chat by voice without losing context.

## 1. Direction and reference extraction

This is a dense work surface, not a terminal, dashboard, or marketing page. The dominant object is the chat history and focused conversation.

Borrow:
- Cursor: near-black layered chrome, compact 28-32 px history rows, quiet selected fills, right-aligned relative time, subtle rounded composer, tiny working spinner.
- Codex: project-aware task list, blue unread dots, restrained status pills, centered reading column, quiet utility controls.
- Linear: attention separated from general activity, durable unread state, `J/K` and jump navigation, hierarchy through alignment instead of boxes.
- Raycast: one unambiguous command surface, immediate keyboard path, layered dark surfaces rather than heavy shadows.
- ChatGPT: composer-integrated mic, tooltips on icon controls, editable dictation before send.

Do not borrow:
- The retired terminal glyph language, monospace UI copy, red status symbols, visible router latency, server counts, generic cards, gradients, glowing accents, or pill-heavy dashboards.
- Codex's visually weak project/thread distinction. Source and project context must remain subordinate but unmistakable.

Screenshot-derived visual read:
- Cursor content is nearly black, with a slightly lighter blue-charcoal sidebar and hairline separation. Controls are charcoal, not black, with 1 px low-contrast borders.
- Codex uses a warmer charcoal sidebar and a near-black conversation canvas. Selected rows are only one surface step brighter.
- Both products use compact system-like sans typography, 11-14 px chrome, medium weight only for active labels, radii mainly in the 6-14 px range, and almost no visible drop shadow.

## 2. Design tokens

Use these values directly. They are intentionally neutral and low-chroma.

```css
:root {
  color-scheme: dark;
  --bg-canvas: #101214;
  --bg-sidebar: #15181b;
  --bg-header: #131619;
  --bg-elevated: #1a1d21;
  --bg-control: #1e2226;
  --bg-hover: #202429;
  --bg-selected: #262b31;
  --bg-selected-hover: #2a3036;
  --bg-overlay: #181b1f;
  --border-subtle: #24292e;
  --border-default: #30363d;
  --border-strong: #454c55;
  --border-focus: #7ca8e8;
  --text-primary: #f0f2f4;
  --text-secondary: #b7bdc4;
  --text-muted: #858d96;
  --text-faint: #626a73;
  --text-inverse: #111315;
  --accent: #8ab4f8;
  --accent-hover: #a4c5fa;
  --accent-soft: rgba(138, 180, 248, 0.14);
  --status-working: #b8c4d3;
  --status-attention: #e4ad5b;
  --status-unseen: #5aa7ff;
  --status-success: #7fb88f;
  --status-danger: #dc7b7b;
  --font-ui: "SF Pro Text", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
  --font-code: "SFMono-Regular", "JetBrains Mono", ui-monospace, monospace;
  --text-10: 10px;
  --text-11: 11px;
  --text-12: 12px;
  --text-13: 13px;
  --text-14: 14px;
  --text-15: 15px;
  --text-18: 18px;
  --leading-tight: 1.25;
  --leading-ui: 1.4;
  --leading-body: 1.58;
  --weight-regular: 400;
  --weight-medium: 500;
  --weight-semibold: 600;
  --radius-4: 4px;
  --radius-6: 6px;
  --radius-8: 8px;
  --radius-12: 12px;
  --radius-16: 16px;
  --radius-round: 999px;
  --space-2: 2px;
  --space-4: 4px;
  --space-6: 6px;
  --space-8: 8px;
  --space-10: 10px;
  --space-12: 12px;
  --space-16: 16px;
  --space-20: 20px;
  --space-24: 24px;
  --space-32: 32px;
  --shadow-popover: 0 12px 32px rgba(0, 0, 0, 0.38), 0 0 0 1px rgba(255,255,255,.05);
  --shadow-composer: 0 8px 28px rgba(0, 0, 0, 0.24);
  --ease-standard: cubic-bezier(.2, .8, .2, 1);
  --ease-out: cubic-bezier(.16, 1, .3, 1);
  --duration-fast: 100ms;
  --duration-ui: 160ms;
  --duration-enter: 220ms;
  --duration-toast: 260ms;
}
```

Contrast rules:
- Body text uses `--text-primary` or `--text-secondary`; metadata alone may use `--text-muted`.
- Color never carries status alone. Attention includes a short label; working has motion; unseen is an unread dot in a conventional right-edge position.
- Red is reserved for a real failed command or destructive confirmation, never for stopped/aborted.
## 3. App shell and layout

Desktop:
- Full viewport, minimum supported width 900 px.
- Sidebar: 272 px default, resizable 232-360 px, `--bg-sidebar`, 1 px right border.
- Main: remaining width, `--bg-canvas`; top bar 44 px; message column max-width 760 px.
- No global outer cards. Sidebar and main are contiguous application regions.

Narrow window, 640-899 px:
- Sidebar becomes a 248 px overlay opened with `⌘\`; main remains full width.
- Source glyph, title, status, and time remain visible. Optional metadata disappears first.

Sidebar, top to bottom:
1. Header, 44 px: quiet `Dictator` wordmark at 13 px/600; no logo lockup. Tagline appears only in About and first-run empty state.
2. New chat button, 32 px: plus icon + `New chat`, shortcut `⌘N`; no filled primary style.
3. Search field, 30 px: `Search chats`, shortcut `⌘K`.
4. `What needs me` summary row, 34 px.
5. Scrollable history: `Pinned`, `Today`, `Yesterday`, `Earlier`.
6. Footer, 44 px: mic control left; settings icon right. Connection health is absent when healthy.

Main pane:
1. Conversation header, 44 px: source glyph, chat title, project/repo path, optional interrupt control when working, overflow menu.
2. Message scroller.
3. Sticky composer region with 12 px bottom/side inset and safe-area support.
4. Toast viewport fixed bottom-right, above composer.

Branding:
- `Dictator` appears once in the sidebar header. The tagline is not persistent chrome.
- Empty state: wordmark, one line `Your word is their command.`, then `say the word.` in 18 px/500, with the global voice control directly beneath it.

## 4. History organization

Recommended default: one unified list grouped by time, with a source glyph on every row.
- This fulfills the product promise that the vendors are one system.
- Order: `What needs me`, `Pinned`, `Today`, `Yesterday`, `Previous 7 days`, `Previous 30 days`, then month labels.
- Within a section, keep manual pins stable; then needs-input, done-unseen, working, and idle; use recency only as the final tiebreaker. Do not reorder a row merely because it was focused.
- Show project/repo on hover and in the selected conversation header. If two rows have the same title, expose the project as a muted second line.
Alternative: source sections (`Cursor`, `Claude Code`, `Codex`) with the same date subgroups.
- Benefit: source-specific debugging and mental model.
- Cost: fragments one project across three places and weakens the unification story.
- Make this a user setting, `Group history by: Time | Source`; default to **Time**.

Headers are 11 px/500 muted text, 24 px high, sticky only inside the sidebar scroll region. They are labels, not collapsible cards. `Earlier` can collapse as one section; all other sections remain open.

## 5. Chat row

Dimensions and anatomy:
- Base row 32 px; selected duplicate-title row may expand to 46 px.
- Horizontal padding 8 px; 6 px radius; 6 px gap.
- Left: 14 x 14 source glyph, monochrome at 70% opacity. Cursor, Claude, and Codex must use distinct silhouettes, not colored circles or initials.
- Center: title, 13 px/400, one line, ellipsis. Selected title is 13 px/500.
- Right: state affordance, then relative time in a fixed 34 px slot, 11 px muted, right aligned.
- Optional second line: project or pending question, 11 px muted, clipped to one line.

States:
- Default: transparent.
- Hover: `--bg-hover` over 100 ms; title becomes primary; row actions fade in at right while preserving the time slot.
- Selected: `--bg-selected`; no bright accent bar. `aria-current="page"`.
- Working: 12 px spinner immediately before time; title remains normal. Second line may say the current activity.
- Needs attention: 6 px amber dot plus `Needs input` in 11 px/500. The pending question becomes the second line. This is the only state promoted into `What needs me`.
- Done unseen: 6 px blue dot in the right slot; no `done` pill. Dot clears only after the conversation is opened, not when a toast appears.
- Idle/seen: no status adornment.
- Stopped/aborted: no dot. If selected or hovered, show muted `Stopped` text; otherwise it looks idle. Never map it to blocked and never use red.
- Failed: muted danger icon plus `Failed` label only when there is an actual failed command/outcome, not a stopped generation.

Working spinner:
- 12 x 12 px CSS ring, `border: 1.5px solid rgba(184,196,211,.28)`, `border-top-color: --status-working`, `border-right-color: rgba(184,196,211,.72)`, 50% radius.
- Rotate 360 degrees in 760 ms linear, transform-origin center, no glow.
- Align optically at `translateY(.25px)`. Reserve its width in every row so time and titles never shift.
- Under `prefers-reduced-motion`, use a static 6 px outlined working ring plus visually hidden `Working`.
## 6. What needs me

- One 34 px row below Search: sparkle/attention icon, `What needs me`, count at right.
- Default summary is plain language: `2 need input · 1 finished`.
- Selecting it focuses the highest-priority item and opens a 320 px popover list if more than one exists.
- Priority: needs input, failed, done-unseen. Working and idle never count.
- Spoken `what needs me?` reads a short answer and focuses the first item; repeated use advances to the next.
- Shortcut: `N` from anywhere outside an input. `J/K`, arrows, Enter, and `1-9` provide complete sidebar navigation.

## 7. Voice control

Idle control:
- Sidebar footer pill, 96 x 30 px, 8 px radius, transparent background; mic icon 15 px; label `Voice off`.
- Hover uses `--bg-hover`. Tooltip after 500 ms: `Turn on voice  ⌥Space`.

Armed/listening states:
- `Voice on`: mic icon + `Listening` label; `--accent-soft` background and 1 px accent-soft border.
- Active capture: three 2 px vertical waveform bars beside the mic; bars animate independently. Never use a large glowing orb.
- Error/unavailable: neutral icon + `Mic unavailable`; details in popover. Do not use a persistent red badge.

Help popover:
- Opens from click on the adjacent `?` or long hover over the active pill.
- 296 px wide, 12 px padding, 8 px radius, `--bg-overlay`, `--shadow-popover`.
- TLDR copy:
  - `Say a chat name to focus it`
  - `Say “send” to send`
  - `Say “interrupt” to stop the focused chat`
  - `Say “new Cursor chat” to start one`
  - `Ask “what needs me?”`
  - `Say “voice off” to stop listening`
- Show keyboard equivalents at right, not a tutorial paragraph.

Wake behavior:
- Voice on means **wake-armed**, not continuously routing speech.
- Activation is `Dictator, …`, click-to-talk, or hold `⌥Space`. After the wake word, capture remains open for 8 seconds after the last speech frame.
- Ambient conversation before the wake word is discarded locally and never shown, stored, or routed.
- While capture is active, the visible waveform and live transcript make the listening boundary explicit. `Cancel` or Escape discards it.
- Optional follow-up mode keeps capture open for 20 seconds after a successful command, but each new action still requires `Dictator` or push-to-talk. Default it off for the demo.
## 8. Live dictation surface fork

### A. Global command bar, recommended

- A Raycast-style bar appears 12 px above the bottom edge and temporarily replaces the focused composer while capturing.
- Width min(720 px, viewport - 32 px), minimum height 52 px, 14 px radius, `--bg-control`, focus border.
- Left target chip always says `To: <focused chat>` or `Command`. It updates only after the parser has confidently identified a command; a 160 ms crossfade makes the change visible.
- Center streams interim text in 15 px. Stable words are primary; unstable trailing words are muted.
- Right controls: `Esc Cancel`, mic waveform, confirm/send button.
- Messages and commands both begin here. Parsed commands become a compact preview such as `Focus → EVALGAP`; messages remain editable text addressed to the locked target.
- Pros: target is never ambiguous, chat switching works cleanly, and the demo has one visible voice locus.
- Cons: users must understand a brief parse step; it is one layer removed from ordinary chat composition.

### B. Focused chat composer

- Interim speech appears in the focused composer at the insertion point.
- A 2 px accent `voice cursor` precedes unstable text; unstable text has a subtle accent underline. Commands are intercepted and replaced by a command preview before execution.
- The target chat is locked when capture starts. If focus changes, dictation pauses and asks whether to move the draft.
- Pros: familiar, direct, and easy to edit as a normal message.
- Cons: switching commands visually collide with message composition, focus changes can misroute text, and the user may not know whether spoken words are command or content.

Recommendation: **A for the hackathon and default product behavior.** It makes the product's central promise legible and safely handles cross-chat commands. Add B later as an opt-in `Dictate into composer` mode after target locking is proven.

## 9. Chat detail and composer

Conversation header:
- Source glyph, title, and muted project path. No `server live`, agent count, route latency, model plumbing, or provider health when healthy.
- When disconnected, show one 28 px amber-tinted inline banner below the header: `Reconnecting… Commands are paused.` It disappears automatically.
- Working chat gets `Interrupt` as a quiet icon button with tooltip; interruption requires confirmation.

Message stream:
- Max-width 760 px, 24 px side padding, 28 px vertical gap.
- User messages: right-aligned, max-width 78%, `--bg-control`, 14 px radius, 14 px/1.58.
- Assistant messages: left-aligned, no bubble, max-width 100%; code uses `--font-code` at 12 px.
- Tool/progress events collapse to one 28 px row with chevron and plain-language label.
- Hover actions are 28 px icon buttons; they do not reserve vertical space.
- Streaming: assistant text ends with a 2 x 14 px caret. Beneath it, `Working` plus the same 12 px sidebar spinner. Do not animate three large dots.

Composer:
- Sticky, max-width 760 px, min-height 76 px, 14 px radius, 1 px border, `--bg-control`, `--shadow-composer`.
- Text area occupies the first row, 14 px, 20 px line height, 12 px padding; grows to 200 px then scrolls.
- Bottom row, 32 px: left `+` and optional context chip; center model/source selector; right mic and 28 px circular send button.
- Send button is muted when empty, off-white with dark icon when ready, and becomes a stop square while generating.
- Enter sends; Shift+Enter adds a line. There is no `Route` button.

## 10. Toasts

- Bottom-right, 12 px from edges and above composer; 336 px wide, 56-76 px high.
- `--bg-overlay`, 1 px border, 8 px radius, `--shadow-popover`.
- Line 1: source glyph, chat title, relative time. Line 2: `Needs input` + clipped question, or `Finished` + result summary.
- Finish means finished, never verified. If verification evidence exists, show a separate quiet check and `Verified`.
- Delay 900 ms; suppress when that chat is focused; coalesce simultaneous events into `3 chats need attention`.
- At most one visible and one queued. Finish toast dismisses after 5 s; needs-input remains for 10 s and has `Open`.

## 11. Voice command grammar

| Intent | Accepted speech | Visible behavior | Guard |
| --- | --- | --- | --- |
| Focus/switch | `Dictator, open EVALGAP`; `switch to the Codex rollout chat` | target preview, then selected row changes | clarify if two titles match |
| Send message | `Dictator, tell EVALGAP rerun the tests`; `send` | editable target + message preview; send acts on confirmation word | never send unstable transcript |
| Interrupt | `Dictator, interrupt this chat`; `stop EVALGAP` | destructive preview with chat name | explicit confirmation required |
| New chat | `Dictator, new Cursor chat in brain`; `start a Claude Code chat` | preview source, project, optional first message | ask for missing project only when ambiguous |
| Attention | `Dictator, what needs me?`; `next attention item` | short spoken answer and focus change | no mutation |
| Voice off | `Dictator, voice off`; `stop listening` | waveform ends, mic returns to idle | immediate, no confirmation |
| Cancel capture | `cancel`; `never mind` | discard unsent interim text | immediate |

The wake word is not part of the parsed command. Noise or person-to-person speech without the wake word maps to `noise` and causes no UI mutation.

## 12. Microinteraction inventory

- Row hover: background 100 ms `--ease-standard`; row actions opacity 120 ms.
- Selection: background 160 ms `--ease-standard`; no sliding indicator.
- Sidebar working spinner: 760 ms linear infinite.
- Unread dot arrival: opacity 0→1 and scale .75→1 over 180 ms `--ease-out`; clearing fades over 140 ms.
- Attention label arrival: opacity and 4 px x-translation over 180 ms `--ease-out`.
- History section expand: height/opacity 180 ms `--ease-standard`.
- Voice waveform: three bars, 520/640/760 ms ease-in-out alternate infinite.
- Mic active ring: opacity .35→.7 over 1,400 ms ease-in-out infinite; no scale bloom.
- Interim voice words: opacity .55→1 over 120 ms when stabilized.
- Voice target-chip change: 160 ms crossfade.
- Streaming caret: opacity 1→.25 over 720 ms step-end infinite.
- Toast enter: translateY(8 px)→0 and opacity 0→1 over 260 ms `--ease-out`; exit 160 ms.
- Popover: opacity + scale .98→1 over 140 ms `--ease-out`.
- Reduced motion: stop all infinite animations, remove transforms, retain state labels and static rings.

## 13. React rebuild plan and protocol contract

Build in this order:
1. `AppShell`: responsive sidebar/main regions; local UI state for sidebar width and overlay.
2. `ProtocolStore`: one WebSocket reducer keyed by event type; reconnect and stale-snapshot handling.
3. `HistoryModel`: normalize agents and chats into one view model; derive temporal groups and attention order.
4. `SidebarHeader`, `NewChatButton`, `ChatSearch`.
5. `AttentionRow` and popover.
6. `HistorySection` and `ChatRow`, including all state stories and reduced-motion behavior.
7. `ConversationHeader`, `MessageStream`, `Message`, `StreamingIndicator`.
8. `Composer` with source/model selector, mic, send/stop states.
9. `VoiceControl`, `VoiceHelpPopover`, then recommended `GlobalVoiceBar`.
10. `CommandPreview` and confirmation UI.
11. `ToastViewport` with delay, suppression, coalescing, and queue limits.
12. Keyboard/focus layer, accessibility pass, narrow-window pass, visual regression fixtures.

Existing WebSocket inputs:
- `fleet.snapshot`: `{ capturedAt, agents[], focusedAgentId, listening }`. Each agent supplies `{ id, name, harness, status, cwd, lastActivity: { summary, at } }`. Use it for active control targets, focus, working/blocked/done state, project path, and current activity.
- `cursor.chats`: despite the legacy name, entries are multi-source `{ id, source, name, status, generating, lastUpdatedAt }`. Use it for source glyph, title, working state, relative time, and temporal grouping.
- `command.routed`: `{ command, latencyMs }`. Use `command.verb`, `rawUtterance`, `resolvedTargetId`, and confidence for the visible command preview. Never show router name or latency in normal UI.
- `command.outcome`: `{ outcome }`. Use `state`, executor evidence, verification results, and `createdAt` for confirmation, failure, success, and verified evidence. `AWAITING_CONFIRMATION` opens the confirmation surface; only `SUCCEEDED` may say verified.
- Client messages today: `utterance`, `confirm`, and `snapshot.request`.

Required protocol additions before the full spec can work:
- Full history: current providers default to 24 hours and cap at 10 chats per source. Replace the cap/window with paged history, e.g. `chat.history.request { cursor }` → `chat.history.page`.
- Conversation detail: current events contain no messages. Add `chat.open` and `chat.messages` with stable message IDs, role, content blocks, timestamps, streaming state, and cursor.
- Durable read state: add client-owned `seenAt`, persisted by chat ID; execution state and unread state must remain separate.
- Attention detail: add `needsInput`, `pendingQuestion`, and last-result summary instead of inferring them from generic status strings.
- Pin/project data: add `pinnedAt`, normalized repo/project, and source-native path.
- Live speech: expose interim/final transcript segments and capture phase (`armed`, `capturing`, `parsing`, `confirming`) rather than only a boolean.
- Rename `cursor.chats` to `chats.snapshot` after compatibility support; the current name leaks the first provider into a multi-source product.

## 14. Acceptance checks

- At 1440 x 900, a user can identify the focused chat, every working chat, and every needs-input chat in under five seconds without a legend.
- A 40-row realistic history remains calm; no title, timestamp, spinner, or unread dot shifts horizontally between states.
- Aborted/stopped has no red affordance and is not treated as blocked.
- Full history is reachable past 24 hours and clearly grouped.
- Voice capture always shows whether it is active, the live words, and the locked target before any send.
- Person-to-person speech without wake activation causes zero routed commands.
- No healthy-state plumbing text, `Route` button, router latency, agent count, or terminal glyph styling appears.
- Keyboard-only flow can search, move, open, jump to attention, dictate, send, cancel, and interrupt.
- `prefers-reduced-motion`, 200% zoom, and 640 px width retain all status semantics.

## Sources

- Local references: `cursor-ui-1.png`, `codex-ui-1.png`, `cursor-ui-2-working-spinner.png`.
- Local product/research: `docs/VISION-dictator.md`, `docs/research/chat-dashboard-patterns.md`.
- Protocol: `commandcenter/src/server.ts`, `src/contracts.ts`, `src/control/chat-sources.ts`, `src/loop/command-loop.ts`, `console/src/App.tsx`.
- Supporting conventions: Cursor system/SF-style chrome; Linear UI redesign and Inbox docs; Raycast List/Action Panel docs; ChatGPT composer and voice patterns.
