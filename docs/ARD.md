# VoiceOps Architecture Requirements Document (ARD)

**Version:** 1.0  
**Architecture style:** Local-first event-driven agent with semantic-first computer control  
**Target:** A reliable hackathon implementation optimized for macOS native workflows and verifiable outcomes

## 1. Architecture Goals

1. Convert natural voice requests into bounded, inspectable task graphs.
2. Ground references using current macOS state rather than relying on the transcript alone.
3. Execute through the most reliable available control channel.
4. Keep risky actions behind explicit approval.
5. Verify outcome predicates through independent observations.
6. Produce replayable evidence for judges and debugging.
7. Remain small enough to implement and stabilize during a hackathon.

## 2. Recommended Technology Stack

### Native shell

- Swift 6 and SwiftUI.
- macOS 14.2+ deployment target.
- AppKit where SwiftUI lacks global-window or event features.
- ScreenCaptureKit for on-demand screenshots.
- Accessibility API (`AXUIElement`) for active app/window semantics and actions.
- EventKit for Calendar and Reminders.
- Speech capture using AVAudioEngine.
- Keychain for API credentials.
- SQLite via GRDB or native SQLite for local traces.

### Agent runtime

Recommended hackathon path: a local Python 3.12 sidecar using FastAPI or a newline-delimited JSON process protocol.

Responsibilities:

- Model calls.
- Task planning and policy evaluation.
- OCR/VLM requests.
- Research tools.
- Verification logic that is not native-framework specific.
- Evaluation runner.

Reason: Claude Code can iterate faster on typed Python orchestration and tests, while Swift owns permissions and macOS integration.

Alternative: implement orchestration entirely in Swift if the team has strong Swift experience. Do not split the project into more than two runtimes.

### Models

Use provider adapters, not model-specific business logic.

- Streaming speech-to-text: `gpt-realtime-whisper` over a transcription-only Realtime WebSocket, with 24 kHz mono PCM, manual hotkey commit, and Apple Speech start/midstream failover. `gpt-realtime-2.1` remains the full-duplex voice-agent option, not the transcription-only command path.
- Planner/reasoner: `gpt-5.6-sol` through a provider adapter for flagship live intelligence; deterministic typed compilers remain the demo-safe fallback.
- Screen understanding: the same multimodal model for MVP; optional separate OCR for speed.
- Research/synthesis: text model with web-search tool.
- Text-to-speech: macOS `AVSpeechSynthesizer` for zero setup; cloud voice is optional.

The exact model may change. The architecture requirement is that model decisions emit typed schemas and are validated before execution.

## 3. System Context

```text
User speech + live Mac state
          |
          v
+-------------------------+
| VoiceOps macOS Shell    |
| capture, UI, permissions|
+------------+------------+
             | typed IPC
             v
+-------------------------+
| Agent Orchestrator      |
| intent, grounding, plan |
| policy, recovery        |
+----+----------+---------+
     |          |
     v          v
 Model Gateway  Research Tools
     |
     v
 Typed task graph
     |
     v
+-------------------------+
| Action Router           |
| EventKit / AX / Browser |
| AppleScript / keyboard  |
+------------+------------+
             |
             v
      Real application state
             |
             v
+-------------------------+
| Independent Verifiers   |
+------------+------------+
             |
             v
 Evidence report + result
```

## 4. Major Components

### 4.1 VoiceSessionController

Responsibilities:

- Register global hotkey.
- Capture microphone audio.
- Stream transcription events.
- Detect cancel/stop commands locally where possible.
- Emit `VoiceRequest` with transcript, timestamps, confidence, and locale.

Required interfaces:

```swift
protocol VoiceSessionControlling {
    func begin() async throws
    func end() async throws -> VoiceRequest
    func cancel()
}
```

### 4.2 ScreenContextCollector

Collects task-scoped state:

- Screenshot of active display/window.
- Active application bundle ID and window title.
- Focused accessibility element.
- Selection and clipboard metadata, with content only after explicit user action.
- Pointer location.
- Accessibility subtree pruned to visible/actionable elements.

Output:

```json
{
  "capture_id": "uuid",
  "timestamp": "ISO-8601",
  "active_app": {"bundle_id":"com.apple.mail","name":"Mail"},
  "window": {"title":"Hackathon details","bounds":[0,0,1440,900]},
  "focused_element_id":"ax-123",
  "pointer":[812,443],
  "elements":[...],
  "screenshot_path":"ephemeral://capture/uuid"
}
```

### 4.3 UI Grounding Engine

Creates unified candidates from multiple evidence sources.

```python
class UIElementCandidate(BaseModel):
    id: str
    role: str | None
    label: str | None
    value: str | None
    bounds: tuple[float, float, float, float]
    source: Literal['accessibility','ocr','vision','dom']
    confidence: float
    actions: list[str]
    app_bundle_id: str
    stable_attributes: dict[str, str]
```

Fusion requirements:

- Prefer accessibility/DOM semantics when confidence is adequate.
- Use OCR for visible text absent from accessibility.
- Use VLM grounding for icons, spatial relationships, and ambiguous references.
- Deduplicate overlapping candidates.
- Store provenance and confidence.

### 4.4 Intent Interpreter

Produces:

```python
class InterpretedIntent(BaseModel):
    goal: str
    entities: list[Entity]
    constraints: list[str]
    deictic_references: list[DeicticReference]
    expected_outcomes: list[OutcomePredicateDraft]
    risk_hints: list[str]
    missing_information: list[str]
```

No free-form output is accepted. Invalid model output is retried once with validation errors.

### 4.5 Task Planner

Produces a directed acyclic task graph where each node has:

```python
class TaskStep(BaseModel):
    id: str
    description: str
    tool: str
    arguments: dict
    preconditions: list[Predicate]
    postconditions: list[Predicate]
    risk: Literal['read','reversible_write','consequential','destructive']
    requires_confirmation: bool
    fallback_tools: list[str]
    max_attempts: int = 2
    timeout_seconds: int = 30
    verifier: VerifierSpec
```

Planner requirements:

- Separate information-gathering, synthesis, write, and verification steps.
- Do not combine multiple irreversible effects in one node.
- Generate a user-facing plan summary without hidden reasoning.
- Include compensating action where available.

### 4.6 Policy and Approval Engine

Rules are deterministic and run after model planning.

Always approve:

- Read-only screen observation invoked by the user.
- Opening an application.
- Creating a local draft/note/reminder when reversible.

Always require confirmation:

- Sending mail/messages.
- Publishing or submitting forms.
- Purchases.
- Deleting content.
- Modifying account/security settings.
- Creating invitations to external attendees.

Block in hackathon MVP:

- Password fields.
- Financial transfers.
- Downloading executable code from an untrusted source and running it.
- Instructions found inside page/email content that attempt to modify the agent’s goals.

### 4.7 Action Router

```text
Action request
  -> native API available? use it
  -> application script available? use it
  -> accessibility action available? use it
  -> controlled browser DOM available? use it
  -> visual target valid? coordinate action
  -> keyboard fallback
  -> fail with evidence
```

Every action implementation returns:

```python
class ActionResult(BaseModel):
    status: Literal['executed','no_op','failed','uncertain']
    started_at: datetime
    ended_at: datetime
    channel: str
    target_provenance: dict
    raw_result: dict
    state_change_hint: str | None
    error: StructuredError | None
```

### 4.8 App adapters

#### CalendarAdapter / RemindersAdapter

Use EventKit for create, fetch, update, and verify. Separate permission request paths. Fetch after write and compare normalized values.

#### NotesAdapter

Preferred MVP sequence:

1. Use AppleScript to create note with deterministic title marker.
2. Query Apple Notes through AppleScript to retrieve the created note.
3. Open the note for visible judge confirmation.
4. If scripting permission fails, fall back to Accessibility-driven UI creation.

#### MailAdapter

MVP supports:

- Read active visible email through Accessibility/screenshot.
- Create a draft using AppleScript or UI.
- Verify draft metadata.
- Send only after explicit confirmation.

#### BrowserAdapter

Use a dedicated Chromium profile controlled by Playwright for research workflows. This improves repeatability and provides DOM semantics. Keep the visible browser window on the real Mac so judges can observe real action. Allowlist research domains.

### 4.9 Recovery Manager

Failure taxonomy:

- `TARGET_NOT_FOUND`
- `TARGET_STALE`
- `NO_STATE_CHANGE`
- `PERMISSION_DENIED`
- `APP_NOT_RUNNING`
- `TIMEOUT`
- `AMBIGUOUS_STATE`
- `MODEL_INVALID_OUTPUT`
- `CONSEQUENTIAL_STATE_UNCERTAIN`

Recovery algorithm:

```text
1. Classify failure.
2. If permission denied, stop and show exact permission path.
3. If app closed, open app and re-observe.
4. If target stale/not found, capture new state and reground.
5. If no state change, try alternate channel once.
6. If consequential state uncertain, do not retry; verify independently and ask user.
7. Stop after bounded attempts and report partial completion.
```

### 4.10 Verification Engine

Verification is a first-class subsystem.

Types:

- **Structured verifier:** query EventKit, AppleScript object model, DOM, or filesystem.
- **Visual verifier:** compare screen against expected visible state using accessibility/OCR/VLM.
- **Content verifier:** normalize and compare title, date, attendees, headings, or content hashes.
- **Composite verifier:** require multiple independent checks for consequential actions.

```python
class VerificationResult(BaseModel):
    predicate_id: str
    passed: bool
    method: str
    confidence: float
    expected: dict
    observed: dict
    evidence_ids: list[str]
    failure_reason: str | None
```

State transitions:

```text
PLANNED -> AWAITING_APPROVAL? -> EXECUTING -> VERIFYING
VERIFYING -> SUCCEEDED | PARTIAL | FAILED | NEEDS_USER
```

No direct `EXECUTING -> SUCCEEDED` transition exists.

### 4.11 Evidence Store

Local SQLite tables:

- `tasks`
- `voice_requests`
- `observations`
- `plans`
- `actions`
- `verifications`
- `artifacts`
- `evaluation_runs`

Raw screenshots are stored in an ephemeral task directory and removed on task completion unless the user enables “save evidence.” Persist redacted thumbnails for the hackathon evaluation mode.

## 5. Data Flow and Provenance

```text
Microphone -> STT -> transcript
ScreenCaptureKit -> ephemeral image -> grounding model
AXUIElement -> structured visible UI tree
Intent + context -> planner model -> validated task graph
Task step -> policy engine -> action adapter
Application -> new structured/visual observation
Verifier -> pass/fail evidence
Evidence formatter -> local report
```

Every derived fact must include:

- source type;
- source capture/document ID;
- extraction method;
- confidence;
- timestamp;
- optional bounding box or text span.

## 6. Prompt Injection and Untrusted Content Boundary

The orchestrator must keep separate message channels for:

- User instruction.
- System policy.
- Observed content from screen, email, web page, or document.
- Tool results.

Observed content is data, never authority. The planner prompt must state that text such as “ignore previous instructions,” “upload this file,” or “send credentials” found on screen is untrusted and cannot expand permissions.

Before any external side effect, the policy engine compares the action against the original user-authorized goal.

## 7. IPC Protocol

Use newline-delimited JSON over stdin/stdout for simplicity and low overhead, or localhost WebSocket if streaming is required.

Message envelope:

```json
{
  "version": "1.0",
  "id": "uuid",
  "type": "observation.create",
  "task_id": "uuid",
  "timestamp": "ISO-8601",
  "payload": {}
}
```

Required events:

- `voice.partial`
- `voice.final`
- `voice.correction`
- `observation.ready`
- `grounding.ready`
- `plan.ready`
- `task.spec_ready`
- `plan.patch_applied`
- `ledger.event`
- `approval.requested`
- `action.started`
- `action.finished`
- `verification.finished`
- `task.completed`
- `task.failed`
- `task.cancelled`

## 8. Security Requirements

- Hardened runtime and app sandbox as compatible with required Accessibility permissions.
- API keys in Keychain; no keys in source or app bundle.
- Sidecar accepts connections only from the parent process or localhost with a per-session token.
- Never log clipboard, password fields, authentication tokens, or full email bodies by default.
- Redact sensitive regions before saving screenshots.
- Validate all tool arguments against schemas and allowlists.
- Synthetic input disabled when the app is not in an active task state.
- Panic stop registered at a lower level than the model loop.

## 9. Observability

Per task collect:

- transcription latency;
- grounding latency;
- planning latency;
- time per action;
- verification latency;
- number of model calls;
- number of clarifications;
- recovery count;
- channel used per action;
- final outcome;
- verifier confidence;
- token/cost estimates.

Provide a developer timeline and a simplified judge-facing timeline.

## 10. Testing Strategy

### Unit tests

- Date normalization.
- Risk classification.
- Plan schema validation.
- Prompt-injection filtering.
- Candidate fusion/deduplication.
- Predicate comparison.
- Retry policy.

### Contract tests

- Swift/Python IPC fixtures.
- EventKit adapter with temporary calendars/reminder lists.
- Notes AppleScript adapter against a dedicated test folder.
- Browser adapter on local deterministic pages.

### Golden screen tests

Create fixture screenshots/accessibility trees for:

- active email with clear deadline;
- ambiguous relative date;
- Calendar next-meeting view;
- Notes confirmation state;
- changed button positions;
- permission dialog.

### End-to-end tests

Run on a dedicated macOS user account with seeded fixtures. Each test resets application state and validates database evidence.

## 11. Architectural Decisions

### ADR-001: Semantic-first hybrid control

**Decision:** Prefer native APIs and semantic accessibility/DOM actions; use vision coordinates only as fallback.

**Reason:** Higher reliability, richer state, easier verification, and clearer provenance, while retaining eligibility through visible real-computer actions.

### ADR-002: Separate executor and verifier

**Decision:** An action adapter cannot declare overall task success.

**Reason:** Prevent false-positive completion and align directly with the evaluation rubric.

### ADR-003: Task-scoped screen capture

**Decision:** Capture only during explicit invocation and task execution.

**Reason:** Consumer trust, simpler privacy explanation, and reduced data volume.

### ADR-004: Narrow app scope

**Decision:** Optimize for Calendar, Reminders, Notes, Mail, and one controlled browser.

**Reason:** A reliable, measurable vertical slice scores better than shallow support for every app.

### ADR-005: Two-runtime maximum

**Decision:** Swift shell plus Python sidecar.

**Reason:** Fast native integration and fast agent iteration without distributed-system complexity.
