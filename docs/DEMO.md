# VoiceOps Judge Demo Runbook

## 1. Demo Goal

In under four minutes, prove all eligibility requirements and visibly map the product to every rubric category.

## 2. Pre-Demo Setup

- Use a dedicated macOS user profile.
- Keep the Order #1842 / Maya Chen support surface visible with the delayed-package message, tracking summary, lifetime value, and Friday deadline.
- Keep the exact initial request and correction below available only as presenter backup; speak naturally during the demo.
- Open the evaluation dashboard on a secondary Space or tab.
- Verify microphone, Screen Recording, and Accessibility permissions. Calendar,
  Reminders, and Automation are not required for the fixture-backed hero path.
- Run `scripts/rehearse_order_rescue.sh`; require 20/20 in both deterministic reports before presenting.
- Confirm the companion's voice badge says either `OpenAI Realtime · gpt-realtime-whisper` or clearly labeled `Apple Speech · FALLBACK`.
- Keep the network backup hotspot available.

## 3. Opening (20 seconds)

“Knowledge workers know the outcome they want, but they still have to translate it into dozens of clicks across apps. VoiceOps lets them speak the outcome. It sees the current screen, acts on the real Mac, and independently proves the result.”

Show the simple architecture strip: Speak -> Ground -> Act -> Verify.

## 4. Hero Demo (2 minutes 20 seconds)

Keep Order #1842 visible and press **⌃⌥V**.

Speak naturally:

> “Take care of this delayed order. Check whether it has moved recently. She looks like a valuable customer, so if it has been stuck for more than three days, prepare an expedited replacement, apologize to her, update the order, and remind me tomorrow to verify the new tracking.”

End capture with **⌃⌥V**. Point out:

- Live transcript proves natural spoken input.
- The raw request remains visible beside the compiled objective, evidence, actions, constraints, and completion criteria.
- The version badge reads **v1**; no action has been presented as complete.

Press **⌃⌥V** again and say:

> “Actually, don’t create the replacement yet. Ask whether she would prefer the replacement or a full refund. Give her a twenty-dollar store credit either way, and tag Sarah in Slack because this is the third delayed package from this carrier.”

End capture. Point out, without narrating hidden chain-of-thought:

- The task ID did not change.
- The visible patch says **v1 → v2**, removes replacement creation, adds customer choice, credit, and Slack escalation, and preserves the original constraints.
- The structured execution ledger labels Observed, Interpreted, Decided, Acted, and Verified events with source and confidence.
- The final card says **ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED**.
- The last two checks explicitly prove **no refund issued** and **no replacement created**.

State clearly that the deterministic demo adapters implement semantic Shopify/customer/Slack/reminder state without requiring external credentials; they are not pixel-click simulations or claims about a live merchant store.

## 5. Recovery Micro-Demo (30 seconds)

Run the stop-barrier rehearsal or press Escape before the Slack action.

Say:

> “Stop.”

VoiceOps should terminate the remaining work. Narrate:

“Stop sits below the model and sidecar. No action after the barrier can begin, and the rehearsal asserts zero post-stop side effects.”

Reset and rerun the Order Rescue rehearsal before presenting again. Do not
switch to a different product story after a stopped run.

## 6. Safety Moment (20 seconds)

Expand the Decided ledger entry that binds the exact customer message, $20 credit, and Slack escalation to the operator's correction.

Say:

“The correction itself explicitly authorizes only these three consequential actions. The approval set is preflighted before the first write; missing one blocks every write. Refund and replacement remain prohibited and are verified absent.”

If time permits, show the `approval_denied` rehearsal row rather than performing a second live write.

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

The app automatically switches from OpenAI Realtime to Apple Speech without restarting the task and preserves the transcript prefix. Point to the visible **FALLBACK** badge. If no API key is configured, Apple Speech is the expected primary demo-safe provider.

### Model latency

Deterministic Order Rescue compilation remains available without a model call. Do not change model configuration mid-demo.

### Full hero failure

Run the deterministic Order Rescue rehearsal and show its newly generated trace,
clearly labeled as test evidence rather than a live external-account completion.
The same versioned task, patch, ledger, stop barrier, and verifier contract remain
visible; do not imply that fixture-backed actions touched a merchant account.

## 10. Known Limitations to State Proactively

- The Order Rescue execution adapters are deterministic demo state, not a connected production Shopify/Gmail/Slack account.
- A live OpenAI Realtime audio acceptance run requires a configured API credential; Apple Speech is the tested zero-setup path.
- Optimized for the delayed high-value order exception rather than every ecommerce workflow.
- Complex drag-and-drop and canvas applications are not supported.
- Visual fallback is less reliable than semantic APIs.
- The agent does not enter passwords, purchase items, or autonomously send external communications.
