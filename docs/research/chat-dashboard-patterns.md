# Multi-agent and multi-session console patterns

Research date: 2026-07-18. This is for the existing local console: a Herdr-style terminal sidebar, recent chats, voice control, command prompt, and independently verified command log.

## Pattern inventory

### Small, explicit state taxonomy
The products converge on a short lifecycle: working, waiting for input or approval, completed, failed, cancelled, and idle or unknown. Herdr uses `blocked`, `working`, `done`, `idle`, and `unknown`; Warp adds error and cancelled; Devin distinguishes working, waiting for user, waiting for approval, and finished.

### Attention is separate from activity
The useful question is not “what is running?” but “what needs me?” Herdr rolls blocked and unseen-done state up through pane, tab, and workspace; Conductor offers a next-session-needing-attention action; Linear, Warp, and Codex collect actionable events into inbox-like surfaces.

### Read state is durable
Unseen activity remains marked until the user visits or explicitly clears it. Herdr makes this unusually concrete: `done` means finished and unseen, while `idle` means finished or waiting and seen; Warp uses a separate unread dot; Linear and Codex support unread filtering.

### Stable groups beat one global feed
Herdr and Conductor group work by workspace or repository, while Superhuman uses a small number of focused splits. Source, project, and task context remain visible even when attention state changes.

### Dense list, focused detail
Conductor uses workspace list, active chat, and diff or terminal; Raycast uses list plus optional detail; Devin uses a session shell with unified progress detail. The list carries only enough information to choose a target, while history, output, diffs, and evidence appear after focus.

### One meaningful preview line
Rows become much more useful when they answer why the state exists. Warp shows branch, directory, status, and diff metadata; Conductor exposes branch and approval or input state; Devin's progress view exposes the current step; agent dashboards commonly surface the pending question or last assistant message.

### Keyboard navigation is a complete path
Herdr and tmux use a prefix model and indexed jumps, k9s uses direct commands and contextual hotkeys, Linear uses `G` sequences plus `J/K`, and Raycast gives every primary action a predictable key. Mouse support remains useful, but no common triage action requires it.

### Notifications are filtered, not exhaustive
Herdr delays finish or input notifications and suppresses them for the active tab. Warp sends complete, request, and error notifications for the parent conversation but excludes child-agent churn; Conductor links toasts to the relevant workspace.

### Verification is an artifact, not a status color
Cursor Cloud Agents return PRs, logs, screenshots, and videos; Devin exposes commands, diffs, browser evidence, and recordings; Conductor keeps the diff and runnable workspace beside the chat. “Agent finished” and “outcome verified” are different claims.

### Ordering is hybrid
Pinned or grouped work gives the list stability, while attention and recency provide temporary priority. tmux preserves a “last window” shortcut, Conductor supports pinned workspaces and next unread, and inbox products promote actionable items without turning every list into pure MRU.

## Apply to this console, ranked by demo impact

### 1. Add one “what needs me” summary row
Place a single compact line directly under the `agents` heading: `attention 2  ◉ 1 blocked  ● 1 done`. Selecting it, pressing Enter, or saying “what needs me?” should focus the highest-priority row and read a short answer. Priority is blocked or failed first, then done-unseen, then working, then idle. Keep this as terminal text with a hairline divider, not a card or metric strip.

### 2. Preserve Herdr's unseen distinction and make it the sorting signal
Use Herdr's exact visible semantics: red `◉` for blocked, yellow spinner for working, teal `●` for done-unseen, green `✓` for idle-seen, and gray `○` for unknown. Internally, keep execution state and `seenAt` separate so a new completion can become unseen without inventing another lifecycle state. Visiting the target changes teal `●` to green `✓`; merely hearing a toast does not.

### 3. Show blocked and finished toasts with strict suppression
Use a bottom-right, two-line terminal toast: `[◉] brain / codex needs input` followed by the pending question, or `[●] console / claude finished` followed by its last summary. Wait about one second and only show it if the state is unchanged; suppress it when that target is already focused; coalesce simultaneous events into `3 agents need attention`; allow at most one active toast plus one queued toast. A finish toast must say finished, not verified.

### 4. Put the reason for attention in a sub-row
For blocked agents, replace the generic metadata line with the actual pending question, clipped to one terminal line. For working agents, show the current activity or latest safe terminal-title summary; for done agents, show the last result summary and whether verification is pending or passed. Dim project, source, branch, and relative time into a third line only on the selected row.

### 5. Add direct numeric jumps and one next-attention key
Render faint `1` through `9` indices on the first nine visible rows. Pressing a number focuses that agent or chat; `j/k` moves; Enter opens; `n` jumps to the next attention item; Esc returns to the command prompt. Keep the same actions clickable, and show the key legend only when the sidebar has focus so the console does not become shortcut documentation.

### 6. Group by workspace or repo, not by agent vendor
Use compact headers such as `pattern-hackathon  3` and `brain  2`, with rolled-up state on the header. Keep Cursor, Claude Code, or Codex as muted row metadata. Project grouping answers where changes are landing and matches Herdr and Conductor; vendor-first grouping makes one task look fragmented across several unrelated sections. Collapse seen-idle groups automatically only when space is tight.

### 7. Make verification a linked second state in the command log
Each routed voice command should visibly progress through `heard → routed → acted → verified` and link to the affected row. Agent state remains Herdr state; command state remains verification state. On success, show a restrained green check plus the observed fact, such as `focused pane = w2:p1`; on failure, keep the row red with expected versus observed state and do not change it to success because the target agent later finishes.

## Ordering rules

Do not use pure MRU sorting because rows moving after every focus action make a voice demo hard to follow. Keep workspace groups stable, sort attention states to the top within each group, preserve manual pins within the same attention tier, and use relative time only as the final tiebreaker. The recently focused row can retain a subtle selection background instead of moving.

## Do not build for the hackathon

- Do not add a Kanban board, backlog stages, drag-and-drop task management, or a team assignment model.
- Do not reproduce Conductor's full diff, PR, merge, branch, or worktree management UI.
- Do not add a graph of parent and child agents. A child count on a selected row is enough if orchestration appears in the demo.
- Do not build custom Split Inbox rules, saved filters, snooze, archive, bulk triage, or a notification mailbox.
- Do not add charts, fleet utilization, token dashboards, or historical analytics. Relative time and the verified log are sufficient.
- Do not add system, email, Slack, or sound notifications. One in-app toast path is enough for a local demo.
- Do not expose every tool call in the sidebar. Keep raw transcript and terminal output behind row focus.
- Do not add a general command palette unless the existing prompt cannot reach an action. Numeric jumps and the voice command grammar cover the demo.

## Sources

- Herdr concepts, agents, configuration, keyboard, and config reference: https://herdr.dev/docs/concepts/ , https://herdr.dev/docs/agents/ , https://herdr.dev/docs/configuration/ , https://herdr.dev/docs/keyboard/ , https://herdr.dev/docs/config-reference/
- Conductor product, workspaces, and sidebar changes: https://conductor.build/ , https://www.conductor.build/docs/concepts/workspaces-and-branches , https://www.conductor.build/changelog/0.39.0-insta-summarize-command-palette-opus-4-6
- Terragon real-time task management and notifications: https://github.com/terragon-labs/terragon-oss , https://docs.terragonlabs.com/docs/resources/release-notes
- Devin session tools and session API: https://docs.devin.ai/work-with-devin/devin-session-tools , https://docs.devin.ai/api-reference/v3/sessions/get-enterprise-session
- Cursor Cloud Agents: https://cursor.com/docs/cloud-agent , https://cursor.com/help/ai-features/background-agents
- Codex and ChatGPT scheduled-task inboxes: https://developers.openai.com/codex/app/automations , https://learn.chatgpt.com/docs/automations
- Warp vertical tabs and agent notifications: https://docs.warp.dev/terminal/windows/vertical-tabs , https://docs.warp.dev/agent-platform/capabilities/agent-notifications/
- Linear Inbox and Triage: https://linear.app/docs/inbox , https://linear.app/docs/triage
- Superhuman Split Inbox: https://help.superhuman.com/hc/en-us/articles/38458483333907-Custom-Split-Inbox
- Raycast list, actions, and keyboard navigation: https://developers.raycast.com/api-reference/user-interface/list.md , https://developers.raycast.com/api-reference/user-interface/action-panel , https://manual.raycast.com/keyboard-shortcuts
- tmux status and window navigation: https://tao-of-tmux.readthedocs.io/en/latest/manuscript/09-status-bar.html
- k9s command and hotkey model: https://k9scli.io/topics/commands/
