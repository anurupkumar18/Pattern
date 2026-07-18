# VoiceOps Product Requirements Document (PRD)

**Version:** 1.0  
**Status:** Hackathon build specification  
**Primary platform:** macOS 14.2+ on Apple Silicon  
**Primary user:** Busy knowledge worker who wants to complete cross-application work by speaking naturally  
**Product promise:** Speak the outcome. VoiceOps sees the current screen, completes the work on the real Mac, and proves the requested result occurred.

## 1. Executive Summary

VoiceOps is a voice-first macOS action agent. A user presses a hotkey, speaks a goal in ordinary language, and continues working while VoiceOps interprets the live screen, plans a safe sequence of actions, operates native Mac applications and websites, handles recoverable failures, and verifies the resulting state.

VoiceOps is intentionally not a general voice chatbot and not a brittle click macro. Its core product loop is:

**Speak -> Ground -> Plan -> Preview risk -> Act -> Observe -> Verify -> Report evidence**

The hackathon submission will demonstrate three unusually strong voice capabilities and three unusually strong action capabilities:

### Voice capabilities

1. **Ambiguity-aware natural requests.** The user states a goal rather than a sequence of commands. VoiceOps resolves dates, references, and constraints from the visible screen and asks only a high-value clarification when required.
2. **Screen-deictic language.** The user can say “this,” “that deadline,” “the second company,” or “using what is open.” VoiceOps binds those words to visible UI elements and active content.
3. **Goal-oriented delegation.** The user can say “prepare me for my next meeting” or “make sure I follow up with these people.” VoiceOps decomposes the outcome into a task graph and executes it.

### Action capabilities

1. **Cross-application workflows.** VoiceOps can move information among Calendar, Notes, Reminders, Mail, Finder, and a browser.
2. **Self-healing execution.** When an element moves, an app is closed, a page loads slowly, or a first path fails, VoiceOps re-observes, chooses an alternate grounded path, and continues within a bounded retry policy.
3. **Outcome-level verification.** VoiceOps verifies the requested state, not merely that a click occurred. It checks that the note exists with expected content, the reminder appears with the correct due date, the calendar event is present, or a draft appears in the expected location.

## 2. Inspiration and Product Research

Clicky demonstrates that consumer agents become approachable when the interaction is reduced to a hotkey, natural speech, an on-screen companion, and zero technical setup. Its public product describes two modes: conversational “talk” and agents that perform tasks; it can see the screen when invoked, point at UI, and run agents. Its newer positioning includes building Mac apps, researching Instagram micro-influencers, and interacting with Apple Notes, Calendar, and Reminders. The open-source Clicky implementation uses a native Mac client, ScreenCaptureKit, cloud speech/model services, and a lightweight proxy for API keys. [1][2][3]

VoiceOps adopts Clicky’s strongest product lessons:

- Voice invocation must be immediate and obvious.
- The assistant should live near the work rather than inside a large chat window.
- “Talk” and “do” need distinct visual states.
- The user should not configure integrations before seeing value.
- Screen context makes natural references substantially easier.

VoiceOps deliberately differentiates in four areas:

- **Verified completion:** every task ends with evidence tied to explicit success criteria.
- **Semantic-first control:** native APIs and macOS Accessibility semantics are preferred over anonymous coordinates.
- **Safety boundaries:** consequential actions require approval at the last responsible moment.
- **Evaluation readiness:** the application records repeatable task traces, latency, recovery events, and verifier outputs.

Computer-use systems from Anthropic and OpenAI establish the standard observe-act loop: models inspect screenshots, return mouse/keyboard actions, and re-observe the environment. Both vendors emphasize that the capability remains imperfect and that high-impact actions need isolation, allowlists, and human confirmation. [4][5]

Recent verifier research reinforces the key product bet. Reliable evaluation requires separating process evidence from outcome evidence, reducing false positives, and using the complete trajectory when judging success. Recent macOS-agent research also argues for combining accessibility semantics, OCR, and visual fallback into executable targets with provenance rather than relying on raw screen coordinates. [6][7]

## 3. Problem Statement

Knowledge workers repeatedly transfer information between applications: reading a message, extracting a date, creating a reminder, adding context to a note, checking a calendar, researching a company, and drafting a follow-up. Current alternatives are weak:

- Manual completion requires many context switches and precise clicks.
- Voice assistants support narrow predefined intents and often lack live screen understanding.
- Automation tools require workflows to be configured before the user knows what they need.
- General computer-use agents may act, but users cannot easily tell what happened or whether it truly succeeded.

The specific problem VoiceOps solves is:

> A Mac user has a clear desired outcome but must manually translate it into a long sequence of cross-application actions and then personally verify every result.

## 4. Target User and Jobs to Be Done

### Primary persona: Independent knowledge worker

Examples include a student, founder, recruiter, salesperson, project manager, or creator who works across native Mac apps and browser tools.

Characteristics:

- Comfortable speaking a goal but not writing automation scripts.
- Frequently uses Calendar, Notes, Reminders, Mail, Finder, and browser tabs.
- Values speed but will not trust an agent that silently performs irreversible actions.
- Needs visible confirmation and the ability to interrupt.

### Core jobs

1. “When I see a deadline or commitment, help me turn it into an organized follow-up without copying details manually.”
2. “Before a meeting, collect the relevant context and put it somewhere I can use immediately.”
3. “When I am researching people or companies, convert the findings into structured notes and next actions.”

## 5. Product Principles

1. **Outcome over commands.** Users express intent; VoiceOps chooses steps.
2. **Visible grounding.** VoiceOps shows what it believes “this” or “that” refers to.
3. **Semantic actions first.** Prefer APIs, app intents, Apple events, and accessibility nodes; use vision-coordinate clicks only when needed.
4. **Least privilege.** Request only the permissions needed for the current capability.
5. **Reversible by default.** Draft before send, create before delete, and preserve an undo log.
6. **Verify independently.** The action executor cannot be the sole authority declaring success.
7. **Fail usefully.** State what was completed, what failed, and the safest next step.
8. **Fast perceived latency.** Acknowledge speech quickly and stream progress, even when full execution takes longer.

## 6. Primary Demonstration Workflows

### Workflow A: Meeting Briefing (hero demo)

**Spoken request:** “Prepare me for my next meeting using what’s already open.”

**Initial state:** Calendar and a relevant email/browser tab are visible or recently active.

**VoiceOps behavior:**

1. Captures the current screen and accessibility tree.
2. Resolves “next meeting” from Calendar or the visible schedule.
3. Identifies meeting title, time, attendees, and link.
4. Searches visible/recent Mail, Notes, and browser context for related material.
5. Creates a structured Apple Note containing purpose, participants, recent context, open questions, and links.
6. Opens the note and positions it beside the meeting link.
7. Verifies the note exists and contains required headings and meeting identifiers.
8. Reports completion with before/after evidence.

**Why it wins:** natural goal, live context, cross-app actions, model-driven synthesis, and clear verification.

### Workflow B: Screen-to-Reminder

**Spoken request:** “Using this email, remind me two days before the deadline and include the important details.”

**Behavior:**

1. Grounds “this email” to the active window.
2. Extracts the deadline and relevant commitment.
3. If the date is ambiguous, asks one focused question.
4. Creates a reminder with title, due date, source link/context, and notes.
5. Opens the reminder or list.
6. Verifies title, due date, and content.

**Why it wins:** direct deictic language, extraction, safe native action, and objective state verification.

### Workflow C: Research-to-Follow-Up

**Spoken request:** “Research the companies on this page, put the best three in Notes, and schedule follow-ups next week.”

**Behavior:**

1. Grounds “companies on this page” using the visible page.
2. Extracts candidate names and links.
3. Launches bounded research agents in parallel.
4. Scores candidates against visible/user-stated criteria.
5. Creates a comparison note with citations and recommendation rationale.
6. Creates three calendar follow-up blocks or reminders after user approval of times.
7. Verifies the note and scheduled items.

**Why it wins:** agent spawning, live screen input, research, ranking, cross-app action, and human-in-the-loop scheduling.

## 7. Functional Requirements

### FR-1 Voice capture and transcription

- Global hotkey starts and stops capture.
- Push-to-talk is the default; optional wake phrase is out of scope for MVP.
- Partial transcript appears within 500 ms after speech begins under normal network conditions.
- Final transcript includes token timestamps and transcription confidence where available.
- The user can cancel by saying “stop,” pressing Escape, or releasing the hotkey in cancel mode.

### FR-2 Intent and reference resolution

- Parse goal, constraints, entities, dates, risk level, and expected outcome.
- Resolve deictic references against active app, focused element, visible text, pointer location, selection, and recent screen history.
- Present a grounding chip such as `this email -> “Hackathon deadline…”` before acting.
- Ask no more than one clarification at a time.
- Do not ask a clarification when a safe, reversible default is available.

### FR-3 Live screen understanding

- Capture an on-demand screenshot only after explicit hotkey invocation.
- Gather active application, window title, focused element, selection, and accessibility nodes.
- Run OCR only on regions not sufficiently described by accessibility metadata.
- Produce normalized `UIElementCandidate` objects with role, label, value, bounds, source, confidence, and supported actions.
- Maintain provenance for every extracted fact.

### FR-4 Planning

- Convert intent into a task graph with preconditions, actions, postconditions, risk, fallback strategy, and verifier.
- Mark actions as read-only, reversible write, consequential write, or destructive.
- Require confirmation for send, purchase, delete, account change, external publish, or any action classified high risk.
- Replan after unexpected state changes.
- Bound the plan by maximum actions, maximum retries, and timeout.

### FR-5 Action execution

Supported MVP action channels, in priority order:

1. Native framework/API action: EventKit for Calendar and Reminders.
2. AppleScript / ScriptingBridge where supported.
3. macOS Accessibility API semantic action.
4. Browser DOM action through Playwright for the dedicated demo browser.
5. OCR/vision-grounded coordinate action as fallback.
6. Keyboard shortcut fallback.

The executor must:

- Confirm the target is still valid immediately before action.
- Highlight the intended target for at least 250 ms in demo mode.
- Record action start, result, duration, and evidence.
- Stop immediately on user interrupt.

### FR-6 Cross-application context

- Track the active application and a short-lived history of user-invoked screenshots and extracted summaries.
- Pass only task-relevant context to models.
- Support handoffs among Calendar, Notes, Reminders, Mail, browser, and Finder.
- For Apple Notes in MVP, create/update notes using AppleScript or Accessibility with content verification.
- For Mail in MVP, read visible content and create drafts; sending requires explicit confirmation.

### FR-7 Self-healing and recovery

- Detect no-op actions by comparing relevant state before and after.
- Retry once using the same semantic target if the failure is transient.
- Re-observe and select an alternate channel if the first method fails.
- Never repeat a consequential action without proving the previous attempt did not succeed.
- Surface a clear recovery choice after the retry budget is exhausted.

### FR-8 Verification

Each task must define outcome predicates before execution. Examples:

- Note with title X exists and includes headings A, B, C.
- Reminder with normalized title X has due date Y.
- Calendar contains an event matching title/time within tolerance.
- Draft appears in Mail with recipient, subject, and body hash.

Verification must use an independent read path when possible. For example, create a reminder with EventKit and verify by fetching it again plus optionally displaying it in Reminders.

A task cannot enter `SUCCEEDED` solely because the executor returned success.

### FR-9 Evidence report

At completion, display:

- User request.
- Interpreted goal.
- Applications touched.
- Actions performed.
- Recovery events.
- Outcome predicates and pass/fail status.
- Total latency and model/action latency breakdown.
- Final confidence.
- Before/after thumbnails with sensitive regions redacted when configured.

### FR-10 Safety and privacy

- Screen capture occurs only during explicit invocation or active task execution.
- Screenshots are ephemeral by default and deleted after the task report is finalized.
- Store structured task traces locally; omit raw secrets and redact password fields.
- Treat screen/page/email content as untrusted data, never as new user instructions.
- Maintain action/domain allowlists for the demo.
- Require user presence and confirmation for consequential actions.
- Provide a panic stop that releases all synthetic input and cancels queued actions.

## 8. Non-Functional Requirements

### Performance

- Voice acknowledgement: < 700 ms p50.
- Final transcription: < 1.5 s after speech end p50.
- First plan preview: < 3 s p50.
- Simple reminder workflow: < 30 s p50.
- UI observation/action cycle: < 4 s p50.

### Reliability

- Hero workflow completion: >= 85% over 20 controlled trials.
- Reminder workflow completion: >= 95% over 20 controlled trials.
- False success rate: 0% in the final demo test suite.
- Consequential duplicate action rate: 0%.

### Usability

- A first-time user can complete a supported workflow without developer instruction.
- All active states are visually distinct: listening, interpreting, awaiting approval, acting, verifying, succeeded, partial, failed.
- Stop and undo controls remain visible during execution.

### Accessibility

- Full keyboard operation.
- Voice output has captions.
- Status is communicated through text and shape, not color alone.
- Respect Reduce Motion.

## 9. UX Specification

### Compact companion

A small floating element appears near the cursor or menu bar.

States:

- Idle: subtle icon.
- Listening: waveform and live transcript.
- Grounding: screenshot thumbnail and resolved reference chips.
- Planning: concise numbered plan, not private chain-of-thought.
- Acting: current action, target highlight, stop button.
- Approval: exact consequential action and data to be submitted.
- Verifying: checklist animation tied to predicates.
- Completed: evidence card and undo/open-result buttons.

### Interaction rules

- Narrate intent and progress, not hidden reasoning.
- Never cover the target being clicked.
- Keep the main task timeline collapsible.
- Present one question at a time.
- Use “I found X; I’m going to Y” instead of vague “Working…” messages.

## 10. Scope

### MVP must ship

- Native macOS app with hotkey and floating UI.
- Spoken requests and live transcript.
- On-demand screenshot and accessibility-tree capture.
- Three supported workflows described above, with Meeting Briefing as hero.
- Calendar and Reminders actions through EventKit.
- Notes creation and verification.
- Browser research through a controlled browser or allowlisted pages.
- Observe-plan-act-verify loop.
- Risk classification, approval gate, stop, and bounded retries.
- Evidence report and evaluation runner.

### Stretch

- Mail draft creation.
- Parallel research subagents.
- User-defined reusable skills.
- Local speech recognition option.
- Local VLM or small model for routing/classification.
- Undo across all supported actions.

### Explicitly out of scope

- Purchases or financial transactions.
- Unrestricted autonomous web browsing.
- Password entry or authentication handling.
- Sending messages without confirmation.
- Continuous screen recording.
- General support for every Mac application.
- Building arbitrary Mac apps inside the production agent during the hackathon.

## 11. Rubric Mapping

### Value - 25 points

- Identify the user as a knowledge worker overwhelmed by cross-app coordination.
- Demonstrate a useful completed artifact, not a navigation trick.
- Show a before/after comparison: manual clicks/apps/time versus one spoken request.
- Measure time saved on the hero workflow.

**Target evidence:** 1 voice request replaces >= 15 manual interactions and saves >= 60% of completion time.

### Inputs & Data - 15 points

- Display a live data provenance panel: microphone, active screenshot, accessibility tree, selected app content, web sources.
- Explain where each input is processed and what is retained.
- Demonstrate denied-permission handling and prompt-injection resistance.
- Use confidence and provenance on extracted facts.

**Target evidence:** every fact in the final note links to a source item or visible screen region.

### Enablement & Ease of Use - 20 points

- One hotkey, one spoken goal, minimal clarification.
- Visible grounding, progress, stop, approval, recovery, and result.
- Keep latency understandable through streamed progress.
- Demonstrate interruption and one recovery path live.

**Target evidence:** new user completes a workflow in <= 2 minutes without instruction.

### Underlying Model - 20 points

- Use the model for multimodal grounding, semantic plan generation, extraction/synthesis, tool selection, and replanning.
- Show why deterministic automation alone cannot resolve “this,” ambiguous dates, or open-ended research.
- Use a hybrid architecture rather than a superficial LLM-to-macro call.
- Record model inputs/outputs at a safe abstraction level for debugging.

**Target evidence:** an ablation without the model fails the deictic and goal-oriented test cases.

### Evidence & Evaluation - 20 points

- Define pass/fail predicates before actions.
- Verify with independent reads and visible UI confirmation.
- Run a repeatable suite with success rate, false-success rate, latency, clarification count, and recovery rate.
- Show known limitations.

**Target evidence:** 20-task demo suite, >= 85% end-to-end success, 0 false-positive completions.

## 12. Acceptance Criteria

The submission is eligible only if judges can observe all four required elements in one uninterrupted demonstration:

1. A natural spoken request is captured live.
2. VoiceOps visibly interprets the live screen.
3. VoiceOps performs at least one real action on the actual computer.
4. VoiceOps visibly confirms the resulting state using an outcome verifier.

The hero demo passes when:

- A user speaks the request without reading a rigid script.
- At least two live applications are used as inputs.
- At least two real write actions occur across native Mac apps.
- One execution obstacle or changed UI state is recovered from, or a prerecorded test proves recovery if the live path is clean.
- The completion report shows all predicates passing and opens the created artifact.
