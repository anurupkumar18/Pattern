# VoiceOps Judge Demo Runbook

## 1. Demo Goal

In under four minutes, prove all eligibility requirements and visibly map the product to every rubric category.

## 2. Pre-Demo Setup

- Use a dedicated macOS user profile.
- Seed Calendar with a meeting 30-60 minutes ahead.
- Seed Mail/browser/Notes with realistic related context.
- Create a visible email containing a deadline for the short workflow.
- Open the evaluation dashboard on a secondary Space or tab.
- Verify microphone, Screen Recording, Accessibility, Calendar, and Reminders permissions.
- Run `scripts/reset_demo_state.sh`, then `scripts/seed_demo_state.sh`, immediately before presenting.
- Keep the network backup hotspot available.

## 3. Opening (20 seconds)

“Knowledge workers know the outcome they want, but they still have to translate it into dozens of clicks across apps. VoiceOps lets them speak the outcome. It sees the current screen, acts on the real Mac, and independently proves the result.”

Show the simple architecture strip: Speak -> Ground -> Act -> Verify.

## 4. Hero Demo (2 minutes)

Keep Calendar visible with a relevant email or research page open nearby.

Speak naturally:

> “Prepare me for my next meeting using what’s already open.”

Pause and point out, without interrupting execution:

- Live transcript proves natural spoken input.
- Grounding chips prove live-screen understanding.
- Plan preview proves goal decomposition.
- Highlighted actions prove control of the actual Mac.
- Progress timeline shows cross-app operations.
- Verification checklist proves resulting state.

At completion, click “Open result.” The created Apple Note must be visible and contain sourced meeting context.

## 5. Recovery Micro-Demo (30 seconds)

Before running, move or close the expected Notes window.

Say:

> “Add the deadline from this email to Reminders two days early.”

VoiceOps should open the needed app or reground after the changed state. Narrate:

“The first expected state changed. VoiceOps re-observed the computer, selected another valid path, and then verified the reminder through EventKit and the visible app.”

For the deterministic short workflow, keep the seeded Mail compose window active and say:

> “Using this email, remind me two days before the deadline and include the important details.”

Point out the July 29, 2026 due date and all five verifier rows. If Reminders or Automation access is denied, use the result card’s Privacy Settings button, grant access, and retry; do not describe the denied run as successful.

## 6. Safety Moment (20 seconds)

Show an approval card for a prepared Mail draft or external calendar invite. Do not actually send unless the demo specifically requires it.

Say:

“Reading and reversible organization can proceed. Sending, publishing, deleting, and external invitations always stop here for explicit approval.”

Cancel the action to demonstrate control.

## 7. Evaluation Proof (30 seconds)

Open the evaluation dashboard.

Show:

- number of repeated trials;
- end-to-end success;
- false-success rate;
- latency;
- recovery rate;
- known limitations.

Key line:

“VoiceOps does not count a click as success. The executor and verifier are separate, and ambiguous evidence fails closed.”

## 8. Rubric Closing (20 seconds)

- **Value:** replaces a real multi-app workflow with one request.
- **Inputs:** voice, screen, accessibility semantics, and trusted application APIs with provenance.
- **Ease:** one hotkey, visible progress, stop, and recovery.
- **Model:** multimodal grounding, planning, synthesis, and replanning.
- **Evidence:** independent predicates, repeated tests, and zero tolerated false-success reports.

## 9. Contingency Paths

### Speech service failure

Switch to the local/system STT adapter. The spoken request must still be captured live.

### Model latency

Use the smaller supported model for intent/grounding while retaining the main model for synthesis.

### Research network failure

VoiceOps labels the affected source as unavailable and ranks from the invoked
visible context with reduced evidence. Do not describe an unavailable source as
successfully fetched. If the comparison would not be useful, cancel at the
approval gate and run Meeting Briefing using already open local sources.

### Notes scripting failure

Use Accessibility fallback to create the note, then verify visually and through the UI tree.

### Full hero failure

Run the Reminder workflow immediately. It still proves all four eligibility requirements. Then show the last successful hero evaluation trace, clearly labeled as prior test evidence rather than live completion.

## 10. Known Limitations to State Proactively

- Optimized for five Mac applications rather than every UI.
- Complex drag-and-drop and canvas applications are not supported.
- Research results depend on network and source availability.
- Visual fallback is less reliable than semantic APIs.
- The agent does not enter passwords, purchase items, or autonomously send external communications.
