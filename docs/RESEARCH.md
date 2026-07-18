# VoiceOps Research Notes and Sources

## Key findings

1. Clicky’s product advantage is interface simplicity: a hotkey, voice, screen context, pointing, and a separate agent mode. Its public materials state that screenshots are invoked by the user and not stored, while text-only accessibility context may be retained. The open-source repository shows a native Mac implementation requiring ScreenCaptureKit and external speech/model services. This supports VoiceOps’ native shell, task-scoped capture, and explicit Talk/Act states.

2. Anthropic’s computer-use work frames the core mechanism as screenshot observation plus mouse/keyboard action, while acknowledging imperfect reliability and recommending low-risk initial tasks. This supports a narrow app scope and bounded recovery.

3. OpenAI’s current computer-use guidance recommends an isolated environment where practical, allowlists, treating page content as untrusted, and keeping humans in the loop for purchases, authenticated, destructive, or hard-to-reverse actions. This directly informs VoiceOps policy boundaries.

4. Apple provides native frameworks for high-performance screen capture and structured Calendar/Reminders access. Using ScreenCaptureKit and EventKit gives VoiceOps reliable input and action channels while still performing observable actions on a real Mac.

5. Recent computer-use evaluation research emphasizes outcome verification, false-positive reduction, process/outcome separation, and full-trajectory evidence. This supports a separate verifier and a zero false-success target.

6. Recent semantic action research argues for fusing Accessibility, OCR, and visual evidence into action targets with provenance and verification cues. This supports VoiceOps’ semantic-first Action Router.

## Sources

[1] Farza Majeed, “Here’s the new Clicky,” X post, April 26, 2026. https://x.com/FarzaTV/status/2048203459976188261

[2] HeyClicky product site and FAQ. https://www.heyclicky.com/

[3] farzaa/clicky open-source repository, README and setup notes. https://github.com/farzaa/clicky

[4] Anthropic, “Introducing computer use,” October 22, 2024. https://www.anthropic.com/news/3-5-models-and-computer-use

[5] OpenAI API documentation, “Computer use.” https://developers.openai.com/api/docs/guides/tools-computer-use

[6] Rosset et al., “The Art of Building Verifiers for Computer Use Agents,” 2026. https://arxiv.org/abs/2604.06240

[7] Liu et al., “Tactile: Giving Computer-Using Agents Hands and Feet,” 2026. https://arxiv.org/abs/2607.14443

[8] Apple Developer Documentation, ScreenCaptureKit. https://developer.apple.com/documentation/screencapturekit/

[9] Apple Developer Documentation, EventKit. https://developer.apple.com/documentation/eventkit

[10] Screenpipe, local-first desktop context and computer-use agent context. https://screenpipe.com/computer-use-agent

[11] OpenAI, “Computer-Using Agent,” January 23, 2025. https://openai.com/index/computer-using-agent/
