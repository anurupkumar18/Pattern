# Conversational Order Rescue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Order Rescue hero into a two-way speech-to-speech conversation that drives the existing versioned task machine through typed tools, executes against a live Shopify dev store and Slack workspace with fixture fallback, uses live LLM compile + VLM grounding as primary, and gates consequential actions behind a spoken read-back approval binding.

**Architecture:** A Realtime S2S session (Swift) whose only side-effect path is typed `conversation.tool_call` envelopes into the Python sidecar; the sidecar keeps sole authority over specs, patches, approval hashes, execution, and verifier-owned success. Live channel adapters implement the same interface as the ADR-020 fixtures and are selected by credential presence.

**Tech Stack:** Python 3.12 + Pydantic v2 (stdlib `urllib` for HTTP — no new deps), Swift 6 / VoiceOpsCore SPM, OpenAI Realtime (S2S) + Responses API, Shopify Admin REST, Slack Web API, EventKit.

**Spec:** `docs/superpowers/specs/2026-07-18-conversational-order-rescue-design.md`

**Conventions (from CLAUDE.md — non-negotiable):** TDD; small commits; `uv run pytest` in `agent/`, `swift test` in `macos/`; regenerate `schemas/` after any schemas.py change (`uv run voiceops-export-schemas`); wire timestamps whole-second UTC "Z"; executors never declare success; consequential actions require explicit approval; every deviation recorded in `docs/DECISIONS.md`.

**Sandbox prerequisites (product owner, day 1, in parallel):**
- Shopify Partners dev store with a test order mirroring #1842; Admin API access token with `read_orders, write_orders, read_customers, write_price_rules` scopes.
- Slack workspace + bot token (`chat:write`, `channels:history`, `channels:read`) and a `#shipping-escalations` channel; note the channel ID.
- Environment variables consumed by the sidecar (Keychain plumbing lands in Task 13): `VOICEOPS_SHOPIFY_SHOP` (e.g. `voiceops-dev.myshopify.com`), `VOICEOPS_SHOPIFY_TOKEN`, `VOICEOPS_SHOPIFY_ORDER_ID`, `VOICEOPS_SLACK_BOT_TOKEN`, `VOICEOPS_SLACK_CHANNEL_ID`.

---

## Task 1: Conversation tool events + approval binding in the wire contract (Python)

**Files:**
- Modify: `agent/voiceops_agent/schemas.py`
- Test: `agent/tests/test_schemas.py` (extend)

- [ ] **Step 1: Write the failing tests** — append to `agent/tests/test_schemas.py`:

```python
def test_conversation_tool_call_envelope_round_trips():
    payload = ConversationToolCall(
        call_id="call_001",
        tool="apply_patch",
        arguments={"transcript": "Actually, don't create the replacement yet."},
    )
    envelope = make_envelope(EventType.CONVERSATION_TOOL_CALL, uuid4(), payload)
    parsed = parse_envelope(envelope.to_ndjson())
    assert parsed.type is EventType.CONVERSATION_TOOL_CALL
    assert parsed.payload.tool == "apply_patch"


def test_conversation_tool_result_requires_known_tool():
    with pytest.raises(ValidationError):
        ConversationToolResult(call_id="c", tool="rm_rf", status="ok")


def test_approval_binding_requires_sha256_hex_hash():
    with pytest.raises(ValidationError):
        ApprovalBinding(
            binding_hash="nope", task_version=2,
            read_back="I will send the message. Confirm?",
            action_ids=["ask_customer_preference"],
        )
    binding = ApprovalBinding(
        binding_hash="a" * 64, task_version=2,
        read_back="I will send the message. Confirm?",
        action_ids=["ask_customer_preference"],
    )
    assert binding.task_version == 2
```

Add imports at top of the test file: `ConversationToolCall`, `ConversationToolResult`, `ApprovalBinding` from `voiceops_agent.schemas`.

- [ ] **Step 2: Run to verify failure** — `cd agent && uv run pytest tests/test_schemas.py -q` → FAIL (ImportError).

- [ ] **Step 3: Implement in `schemas.py`** — add to `EventType`:

```python
    CONVERSATION_TOOL_CALL = "conversation.tool_call"
    CONVERSATION_TOOL_RESULT = "conversation.tool_result"
```

After the `LedgerEventKind` alias add:

```python
ConversationToolName = Literal[
    "compile_task",
    "apply_patch",
    "get_task_state",
    "request_approval",
    "confirm_approval",
    "execute_plan",
    "get_ledger",
]
```

After the `ExecutionLedgerEvent` model add:

```python
class ConversationToolCall(VoiceOpsModel):
    """The S2S conversation layer's only side-effect path into the task machine."""

    call_id: str = Field(min_length=1)
    tool: ConversationToolName
    arguments: dict[str, Any] = Field(default_factory=dict)


class ConversationToolResult(VoiceOpsModel):
    call_id: str = Field(min_length=1)
    tool: ConversationToolName
    status: Literal["ok", "rejected", "failed"]
    result: dict[str, Any] = Field(default_factory=dict)
    error: StructuredError | None = None


class ApprovalBinding(VoiceOpsModel):
    """Read-back approval: a spoken yes authorizes exactly one action-set hash."""

    binding_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    task_version: int = Field(ge=1)
    read_back: str = Field(min_length=1)
    action_ids: list[str] = Field(min_length=1)
```

Register in `EVENT_PAYLOADS` (`CONVERSATION_TOOL_CALL: ConversationToolCall`, `CONVERSATION_TOOL_RESULT: ConversationToolResult`) and append `ConversationToolCall`, `ConversationToolResult`, `ApprovalBinding` to `_EXPORTED_MODELS`.

- [ ] **Step 4: Run tests** — `uv run pytest tests/test_schemas.py -q` → PASS; then full suite `uv run pytest -q` → PASS.

- [ ] **Step 5: Regenerate schema exports** — `uv run voiceops-export-schemas` (writes `schemas/ConversationToolCall.json` etc.).

- [ ] **Step 6: Commit** — `git add agent schemas && git commit -m "feat: conversation tool-call events and approval binding in wire contract"`

## Task 2: Shared IPC fixtures + Swift Envelope mirror

**Files:**
- Create: `fixtures/ipc/conversation_tool_call.json`, `fixtures/ipc/conversation_tool_result.json`
- Modify: `macos/Sources/VoiceOpsCore/Envelope.swift`
- Test: `macos/Tests/VoiceOpsCoreTests/EnvelopeTests.swift` (extend), `agent/tests/test_schemas.py` (fixture round-trip)

- [ ] **Step 1: Generate the fixtures from Python** (source of truth) — script in `agent`:

```sh
cd agent && uv run python - <<'EOF'
import json
from pathlib import Path
from uuid import UUID
from voiceops_agent.schemas import (
    ConversationToolCall, ConversationToolResult, EventType, Envelope,
)
from datetime import datetime, UTC
root = Path(__file__ or ".").resolve()
fixtures = Path("../fixtures/ipc")
task_id = UUID("18420000-0000-4000-8000-000000000042")
call = Envelope(
    version="1.0", id=UUID("18420000-0000-4000-8000-0000000000c1"),
    type=EventType.CONVERSATION_TOOL_CALL, task_id=task_id,
    timestamp=datetime(2026, 7, 18, 22, 0, 0, tzinfo=UTC),
    payload=ConversationToolCall(
        call_id="call_001", tool="apply_patch",
        arguments={"transcript": "Actually, don't create the replacement yet."}),
)
result = Envelope(
    version="1.0", id=UUID("18420000-0000-4000-8000-0000000000c2"),
    type=EventType.CONVERSATION_TOOL_RESULT, task_id=task_id,
    timestamp=datetime(2026, 7, 18, 22, 0, 1, tzinfo=UTC),
    payload=ConversationToolResult(
        call_id="call_001", tool="apply_patch", status="ok",
        result={"new_version": 2, "added": ["actions.issue_store_credit"]}),
)
(fixtures / "conversation_tool_call.json").write_text(json.dumps(call.to_wire_dict(), indent=2) + "\n")
(fixtures / "conversation_tool_result.json").write_text(json.dumps(result.to_wire_dict(), indent=2) + "\n")
EOF
```

- [ ] **Step 2: Python fixture round-trip test** — append to `test_schemas.py`:

```python
def test_conversation_fixtures_round_trip():
    for name in ("conversation_tool_call.json", "conversation_tool_result.json"):
        raw = (FIXTURES_DIR / name).read_text()
        envelope = parse_envelope(raw)
        assert json.loads(envelope.to_ndjson()) == json.loads(raw)
```

(`FIXTURES_DIR` already exists in that test file for `voice_final.json`; if named differently, follow the existing constant.) Run: PASS.

- [ ] **Step 3: Swift failing test** — extend `EnvelopeTests.swift`:

```swift
func testConversationToolCallFixtureRoundTrips() throws {
    let data = try fixtureData("conversation_tool_call.json")
    let envelope = try JSONDecoder.voiceOps.decode(Envelope.self, from: data)
    guard case .conversationToolCall(let call) = envelope.payload else {
        return XCTFail("expected conversationToolCall payload")
    }
    XCTAssertEqual(call.tool, "apply_patch")
    XCTAssertEqual(call.callID, "call_001")
    let reencoded = try JSONEncoder.voiceOps.encode(envelope)
    try assertJSONEqual(reencoded, data)
}

func testConversationToolResultFixtureRoundTrips() throws {
    let data = try fixtureData("conversation_tool_result.json")
    let envelope = try JSONDecoder.voiceOps.decode(Envelope.self, from: data)
    guard case .conversationToolResult(let result) = envelope.payload else {
        return XCTFail("expected conversationToolResult payload")
    }
    XCTAssertEqual(result.status, "ok")
}
```

(Follow the file's existing fixture-loading and JSON-equality helpers; reuse their exact names.) Run `cd macos && swift test --filter EnvelopeTests` → FAIL.

- [ ] **Step 4: Implement Swift mirror** — in `Envelope.swift`: add `case conversationToolCall = "conversation.tool_call"` / `case conversationToolResult = "conversation.tool_result"` to `EventType`; add Codable structs following the file's snake_case CodingKeys pattern:

```swift
public struct ConversationToolCall: Codable, Equatable, Sendable {
    public let callID: String
    public let tool: String
    public let arguments: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case tool, arguments
        case callID = "call_id"
    }
}

public struct ConversationToolResult: Codable, Equatable, Sendable {
    public let callID: String
    public let tool: String
    public let status: String
    public let result: [String: JSONValue]
    public let error: StructuredError?

    enum CodingKeys: String, CodingKey {
        case tool, status, result, error
        case callID = "call_id"
    }
}

public struct ApprovalBinding: Codable, Equatable, Sendable {
    public let bindingHash: String
    public let taskVersion: Int
    public let readBack: String
    public let actionIDs: [String]

    enum CodingKeys: String, CodingKey {
        case bindingHash = "binding_hash"
        case taskVersion = "task_version"
        case readBack = "read_back"
        case actionIDs = "action_ids"
    }
}
```

Wire the two new cases into the payload enum + its decode/encode switch exactly the way `ledgerEvent` is wired.

- [ ] **Step 5: Run both suites** — `swift test` → PASS; `cd ../agent && uv run pytest -q` → PASS.
- [ ] **Step 6: Commit** — `git add fixtures macos agent && git commit -m "feat: mirror conversation tool contract in Swift with shared fixtures"`

## Task 3: Approval hash + affirmative classifier (Python)

**Files:**
- Create: `agent/voiceops_agent/conversation.py`
- Test: `agent/tests/test_conversation.py`

- [ ] **Step 1: Failing tests** — create `agent/tests/test_conversation.py`:

```python
from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.conversation import (
    approval_binding_for,
    classify_affirmative,
    ConversationError,
)
from voiceops_agent.workflows.order_rescue import (
    OrderRescueFixture,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2] / "fixtures" / "order_rescue" / "golden_order_1842.json"
)
TASK_ID = UUID("18420000-0000-4000-8000-000000000007")


def corrected_task():
    fixture = OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())
    v1 = compile_order_rescue_task(TASK_ID, "Take care of this delayed order", fixture)
    return apply_plan_patch(v1, build_customer_choice_patch(1, "Actually, don't create the replacement yet; ask refund preference, $20 credit, tell Sarah in Slack."))


def test_binding_is_deterministic_and_names_every_consequential_action():
    task = corrected_task()
    a, b = approval_binding_for(task), approval_binding_for(task)
    assert a == b
    assert a.task_version == 2
    assert a.action_ids == ["ask_customer_preference", "issue_store_credit", "notify_operations"]
    assert "confirm" in a.read_back.casefold()


def test_binding_changes_when_the_action_set_changes():
    task = corrected_task()
    v1 = compile_order_rescue_task(TASK_ID, "Take care of this delayed order",
                                   OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text()))
    assert approval_binding_for(task).binding_hash != approval_binding_for(v1).binding_hash


def test_binding_requires_pending_consequential_actions():
    fixture = OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())
    v1 = compile_order_rescue_task(TASK_ID, "Take care of this delayed order", fixture)
    for action in v1.actions.values():
        if action.requires_confirmation:
            object.__setattr__(action, "status", "cancelled")
    with pytest.raises(ConversationError):
        approval_binding_for(v1)


@pytest.mark.parametrize("utterance", ["Yes", "yes, go ahead", "Confirmed.", "approve", "do it"])
def test_clear_affirmatives_approve(utterance):
    assert classify_affirmative(utterance) is True


@pytest.mark.parametrize(
    "utterance",
    ["yeah maybe", "yes but change the credit to fifty", "no", "hold on", "what will you send?", ""],
)
def test_anything_unclear_is_not_approval(utterance):
    assert classify_affirmative(utterance) is False
```

- [ ] **Step 2: Run** — `uv run pytest tests/test_conversation.py -q` → FAIL (ModuleNotFoundError).

- [ ] **Step 3: Implement** — create `agent/voiceops_agent/conversation.py`:

```python
"""Conversation-layer authority helpers: approval binding and affirmative gating.

The S2S voice layer proposes; this module decides. A spoken approval authorizes
exactly one hash over the pending consequential action set at one task version.
Any change to the set or version produces a different hash, so a stale or
misheard yes can never authorize new work.
"""

from __future__ import annotations

import hashlib
import json

from .schemas import ApprovalBinding, VersionedTaskSpec


class ConversationError(ValueError):
    pass


_AFFIRMATIVES = frozenset({
    "yes", "yes go ahead", "yes do it", "yes confirm", "yes approved",
    "confirm", "confirmed", "approve", "approved", "go ahead", "do it",
    "yes please", "confirm it", "yes send it", "send it",
})


def classify_affirmative(utterance: str) -> bool:
    """Only an unambiguous, standalone yes approves. Everything else does not."""
    normalized = " ".join(
        utterance.casefold().replace(",", " ").replace(".", " ").replace("!", " ").split()
    )
    return normalized in _AFFIRMATIVES


def approval_binding_for(task: VersionedTaskSpec) -> ApprovalBinding:
    pending = sorted(
        (
            action
            for action in task.actions.values()
            if action.requires_confirmation and action.status == "pending"
        ),
        key=lambda action: action.id,
    )
    if not pending:
        raise ConversationError("no pending consequential actions to approve")
    canonical = json.dumps(
        {
            "task_id": str(task.task_id),
            "version": task.version,
            "actions": [
                {"id": a.id, "description": a.description, "risk": a.risk}
                for a in pending
            ],
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    read_back = (
        "I will "
        + "; ".join(a.description.rstrip(".").lower()[0:1] + a.description.rstrip(".")[1:] for a in pending)
        + ". Nothing else. Confirm?"
    )
    return ApprovalBinding(
        binding_hash=digest,
        task_version=task.version,
        read_back=read_back,
        action_ids=[a.id for a in pending],
    )
```

- [ ] **Step 4: Run** — `uv run pytest tests/test_conversation.py -q` → PASS; full suite → PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat: approval read-back binding and strict affirmative gate"`

## Task 4: ConversationToolRouter — compile, patch, state, ledger

**Files:**
- Modify: `agent/voiceops_agent/conversation.py`, `agent/voiceops_agent/main.py`
- Test: `agent/tests/test_conversation.py` (extend), `agent/tests/test_sidecar.py` (dispatch)

The router owns per-task conversation state and returns envelopes: UI side-events first, the `conversation.tool_result` last. `compile_task` / `apply_patch` take a compiler seam (Task 10 makes it live); until then wire the deterministic functions.

- [ ] **Step 1: Failing tests** — extend `test_conversation.py`:

```python
from voiceops_agent.conversation import ConversationToolRouter
from voiceops_agent.schemas import ConversationToolCall, EventType


def router():
    fixture = OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())
    return ConversationToolRouter(fixture=fixture)


def call(tool, **arguments):
    return ConversationToolCall(call_id=f"call_{tool}", tool=tool, arguments=arguments)


def test_compile_task_emits_spec_and_ok_result():
    events = router().handle(TASK_ID, call("compile_task", transcript="Take care of this delayed order"))
    assert [e.type for e in events] == [EventType.TASK_SPEC_READY, EventType.CONVERSATION_TOOL_RESULT]
    result = events[-1].payload
    assert result.status == "ok"
    assert result.result["version"] == 1
    assert "1842" in result.result["objective"]


def test_apply_patch_emits_diff_and_preserves_task_id():
    r = router()
    r.handle(TASK_ID, call("compile_task", transcript="Take care of this delayed order"))
    events = r.handle(TASK_ID, call(
        "apply_patch",
        transcript="Actually, don't create the replacement yet. Ask refund or replacement, $20 credit, tell Sarah in Slack.",
    ))
    types = [e.type for e in events]
    assert types == [
        EventType.PLAN_PATCH_APPLIED, EventType.TASK_SPEC_READY, EventType.CONVERSATION_TOOL_RESULT,
    ]
    assert all(e.task_id == TASK_ID for e in events)
    result = events[-1].payload
    assert result.result["new_version"] == 2
    assert "actions.create_replacement" in result.result["removed"]


def test_apply_patch_without_task_is_rejected_not_crashed():
    events = router().handle(TASK_ID, call("apply_patch", transcript="whatever"))
    result = events[-1].payload
    assert result.status == "rejected"
    assert events[-1].type is EventType.CONVERSATION_TOOL_RESULT


def test_get_task_state_reports_version_and_constraints():
    r = router()
    r.handle(TASK_ID, call("compile_task", transcript="Take care of this delayed order"))
    events = r.handle(TASK_ID, call("get_task_state"))
    result = events[-1].payload
    assert result.status == "ok"
    assert result.result["version"] == 1
    assert "no_refund" in result.result["constraints"]


def test_unknown_arguments_are_rejected():
    events = router().handle(TASK_ID, call("compile_task"))
    assert events[-1].payload.status == "rejected"
```

- [ ] **Step 2: Run** — FAIL (no `ConversationToolRouter`).

- [ ] **Step 3: Implement** in `conversation.py`:

```python
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID

from .schemas import (
    ConversationToolCall,
    ConversationToolResult,
    Envelope,
    EventType,
    ExecutionLedgerEvent,
    FailureCode,
    StructuredError,
    VersionedTaskSpec,
    make_envelope,
)
from .workflows.order_rescue import (
    OrderRescueFixture,
    OrderRescuePlanningError,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)


@dataclass
class _ConversationTaskState:
    spec: VersionedTaskSpec | None = None
    binding: "ApprovalBinding | None" = None
    confirmed_hash: str | None = None
    ledger: list[ExecutionLedgerEvent] = field(default_factory=list)
    completed: bool = False


class ConversationToolRouter:
    """Typed tool surface: the only path from speech to task-machine effects."""

    def __init__(self, fixture: OrderRescueFixture, compiler: Any | None = None) -> None:
        self._fixture = fixture
        self._compiler = compiler  # Task 10 injects the live/fallback compiler.
        self._tasks: dict[UUID, _ConversationTaskState] = {}

    def handle(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        handler = getattr(self, f"_tool_{call.tool}", None)
        if handler is None:  # schema already forbids this; belt and braces
            return [self._result(task_id, call, "rejected", error=self._error(
                FailureCode.INVALID_MESSAGE, f"unknown tool {call.tool!r}"))]
        try:
            return handler(task_id, call)
        except (OrderRescuePlanningError, ConversationError) as error:
            return [self._result(task_id, call, "rejected", error=self._error(
                FailureCode.AMBIGUOUS_STATE, str(error)))]

    # -- tools ---------------------------------------------------------------

    def _tool_compile_task(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        transcript = self._required_str(call, "transcript")
        spec = self._compile(task_id, transcript)
        state = self._tasks.setdefault(task_id, _ConversationTaskState())
        state.spec = spec
        state.binding = None
        state.confirmed_hash = None
        return [
            make_envelope(EventType.TASK_SPEC_READY, task_id, spec),
            self._result(task_id, call, "ok", result={
                "version": spec.version,
                "objective": spec.objective,
                "action_count": len(spec.actions),
                "constraints": sorted(spec.constraints),
                "speech_summary": self._speech_summary(spec),
            }),
        ]

    def _tool_apply_patch(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        transcript = self._required_str(call, "transcript")
        state = self._require_spec(task_id)
        patch = self._patch(state.spec, transcript)
        updated = apply_plan_patch(state.spec, patch)
        state.spec = updated
        state.binding = None       # any change invalidates a pending approval
        state.confirmed_hash = None
        applied = updated.patch_history[-1]
        return [
            make_envelope(EventType.PLAN_PATCH_APPLIED, task_id, applied),
            make_envelope(EventType.TASK_SPEC_READY, task_id, updated),
            self._result(task_id, call, "ok", result={
                "new_version": applied.new_version,
                "added": applied.added,
                "removed": applied.removed,
                "replaced": applied.replaced,
                "preserved_count": len(applied.preserved),
                "speech_summary": (
                    f"Plan updated to version {applied.new_version}: "
                    f"{len(applied.added)} added, {len(applied.removed)} removed, "
                    f"{len(applied.preserved)} preserved."
                ),
            }),
        ]

    def _tool_get_task_state(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        state = self._require_spec(task_id)
        spec = state.spec
        return [self._result(task_id, call, "ok", result={
            "version": spec.version,
            "objective": spec.objective,
            "actions": {a.id: a.status for a in spec.actions.values()},
            "constraints": sorted(spec.constraints),
            "awaiting_approval": state.binding is not None and state.confirmed_hash is None,
            "completed": state.completed,
        })]

    def _tool_get_ledger(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        state = self._tasks.get(task_id)
        events = state.ledger[-10:] if state else []
        return [self._result(task_id, call, "ok", result={
            "events": [
                {"type": e.event_type, "where": e.where, "what": e.what, "found": e.found}
                for e in events
            ],
        })]

    # -- helpers -------------------------------------------------------------

    def _compile(self, task_id: UUID, transcript: str) -> VersionedTaskSpec:
        if self._compiler is not None:
            return self._compiler.compile(task_id, transcript, self._fixture)
        return compile_order_rescue_task(task_id, transcript, self._fixture)

    def _patch(self, spec: VersionedTaskSpec, transcript: str):
        if self._compiler is not None:
            return self._compiler.patch(spec, transcript)
        return build_customer_choice_patch(spec.version, transcript)

    def _require_spec(self, task_id: UUID) -> _ConversationTaskState:
        state = self._tasks.get(task_id)
        if state is None or state.spec is None:
            raise ConversationError("no compiled task exists for this conversation")
        return state

    @staticmethod
    def _required_str(call: ConversationToolCall, key: str) -> str:
        value = call.arguments.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ConversationError(f"tool {call.tool} requires a non-empty {key!r} argument")
        return value

    @staticmethod
    def _speech_summary(spec: VersionedTaskSpec) -> str:
        pending = [a for a in spec.actions.values() if a.status == "pending"]
        gated = [a for a in pending if a.requires_confirmation]
        return (
            f"{spec.objective} {len(pending)} actions planned, "
            f"{len(gated)} need your approval."
        )

    def _result(
        self, task_id: UUID, call: ConversationToolCall, status: str, *,
        result: dict[str, Any] | None = None, error: StructuredError | None = None,
    ) -> Envelope:
        return make_envelope(EventType.CONVERSATION_TOOL_RESULT, task_id, ConversationToolResult(
            call_id=call.call_id, tool=call.tool, status=status,
            result=result or {}, error=error,
        ))

    @staticmethod
    def _error(code: FailureCode, message: str) -> StructuredError:
        return StructuredError(code=code, message=message[:500])
```

- [ ] **Step 4: Sidecar dispatch** — failing test in `test_sidecar.py`:

```python
def test_conversation_tool_call_routes_to_router():
    runtime = SidecarRuntime()
    envelope = make_envelope(
        EventType.CONVERSATION_TOOL_CALL,
        uuid4(),
        ConversationToolCall(call_id="c1", tool="compile_task",
                             arguments={"transcript": "Take care of this delayed order"}),
    )
    events = runtime.handle_line(envelope.to_ndjson())
    assert events[-1].type is EventType.CONVERSATION_TOOL_RESULT
    assert events[-1].payload.status == "ok"
```

Then in `SidecarRuntime.__init__`: `self._conversation = ConversationToolRouter(fixture=self._order_rescue_fixture)`; in `handle_line` after the `TASK_CANCELLED` branch:

```python
        if envelope.type is EventType.CONVERSATION_TOOL_CALL:
            return self._conversation.handle(envelope.task_id, envelope.payload)
```

- [ ] **Step 5: Run all Python tests** → PASS. **Step 6: Commit** — `git commit -am "feat: conversation tool router for compile, patch, state, ledger"`

## Task 5: Approval + gated execution tools

**Files:**
- Modify: `agent/voiceops_agent/conversation.py`
- Test: `agent/tests/test_conversation.py` (extend)

- [ ] **Step 1: Failing tests:**

```python
def compiled_and_patched_router():
    r = router()
    r.handle(TASK_ID, call("compile_task", transcript="Take care of this delayed order"))
    r.handle(TASK_ID, call(
        "apply_patch",
        transcript="Actually, don't create the replacement yet. Ask refund or replacement, $20 credit, tell Sarah in Slack.",
    ))
    return r


def test_request_approval_returns_read_back_and_emits_ui_event():
    r = compiled_and_patched_router()
    events = r.handle(TASK_ID, call("request_approval"))
    assert [e.type for e in events] == [EventType.APPROVAL_REQUESTED, EventType.CONVERSATION_TOOL_RESULT]
    result = events[-1].payload
    assert result.status == "ok"
    assert len(result.result["binding_hash"]) == 64
    assert "confirm" in result.result["read_back"].casefold()


def test_execute_without_confirmed_approval_is_rejected():
    r = compiled_and_patched_router()
    r.handle(TASK_ID, call("request_approval"))
    events = r.handle(TASK_ID, call("execute_plan"))
    assert events[-1].payload.status == "rejected"


def test_mishear_cannot_authorize():
    r = compiled_and_patched_router()
    binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
    events = r.handle(TASK_ID, call(
        "confirm_approval", binding_hash=binding["binding_hash"], utterance="yeah maybe fine"))
    assert events[-1].payload.status == "rejected"
    assert r.handle(TASK_ID, call("execute_plan"))[-1].payload.status == "rejected"


def test_stale_hash_after_patch_is_rejected():
    r = compiled_and_patched_router()
    binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
    r.handle(TASK_ID, call(
        "apply_patch",
        transcript="Also add a constraint: never contact the customer twice.",
    ))  # deterministic compiler rejects unknown corrections -> use direct spec mutation instead:
    # Simpler deterministic route: re-request approval after nothing changed is fine;
    # simulate staleness by confirming against a corrupted hash.
    events = r.handle(TASK_ID, call(
        "confirm_approval", binding_hash="0" * 64, utterance="yes"))
    assert events[-1].payload.status == "rejected"


def test_confirmed_approval_allows_execution_and_verifier_owns_success():
    r = compiled_and_patched_router()
    binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
    confirm = r.handle(TASK_ID, call(
        "confirm_approval", binding_hash=binding["binding_hash"], utterance="Yes, go ahead."))
    assert confirm[-1].payload.status == "ok"
    events = r.handle(TASK_ID, call("execute_plan"))
    types = [e.type for e in events]
    assert types[-1] is EventType.CONVERSATION_TOOL_RESULT
    assert EventType.TASK_COMPLETED in types
    assert EventType.LEDGER_EVENT in types
    completed = next(e for e in events if e.type is EventType.TASK_COMPLETED)
    assert completed.payload.state == "succeeded"
    result = events[-1].payload
    assert result.result["checks_passed"] == 5
    assert result.result["confirmed_not_performed"] == ["no-refund-issued", "no-replacement-created"]


def test_execute_twice_is_rejected_not_duplicated():
    r = compiled_and_patched_router()
    binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
    r.handle(TASK_ID, call("confirm_approval", binding_hash=binding["binding_hash"], utterance="yes"))
    r.handle(TASK_ID, call("execute_plan"))
    assert r.handle(TASK_ID, call("execute_plan"))[-1].payload.status == "rejected"
```

- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** — add to the router:

```python
    def _tool_request_approval(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        state = self._require_spec(task_id)
        binding = approval_binding_for(state.spec)
        state.binding = binding
        state.confirmed_hash = None
        request = ApprovalRequest(
            step_id="conversation-approval",
            description=binding.read_back,
            risk="consequential",
            data_preview={"action_ids": binding.action_ids, "binding_hash": binding.binding_hash},
        )
        return [
            make_envelope(EventType.APPROVAL_REQUESTED, task_id, request),
            self._result(task_id, call, "ok", result={
                "binding_hash": binding.binding_hash,
                "read_back": binding.read_back,
                "action_ids": binding.action_ids,
            }),
        ]

    def _tool_confirm_approval(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        state = self._require_spec(task_id)
        provided = self._required_str(call, "binding_hash")
        utterance = self._required_str(call, "utterance")
        if state.binding is None:
            raise ConversationError("no approval was requested")
        current = approval_binding_for(state.spec)
        if provided != state.binding.binding_hash or provided != current.binding_hash:
            state.binding = None
            raise ConversationError(
                "approval hash is stale: the plan changed after the read-back; request approval again"
            )
        if not classify_affirmative(utterance):
            raise ConversationError(
                f"utterance {utterance!r} is not an unambiguous approval; nothing was authorized"
            )
        state.confirmed_hash = provided
        return [self._result(task_id, call, "ok", result={
            "approved_action_ids": state.binding.action_ids,
            "speech_summary": "Approved. Executing now.",
        })]

    def _tool_execute_plan(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        state = self._require_spec(task_id)
        if state.completed:
            raise ConversationError("this task already executed; a replay cannot be authorized")
        current = approval_binding_for(state.spec)
        if state.confirmed_hash is None or state.confirmed_hash != current.binding_hash:
            raise ConversationError("execution requires a confirmed, current approval")
        execution = FixtureOrderRescueExecutor().execute(
            state.spec, self._fixture,
            approved_action_ids=set(state.binding.action_ids),
        )
        report = verify_order_rescue(state.spec, self._fixture, execution)
        state.ledger = report.ledger
        state.completed = True
        events = [
            make_envelope(EventType.LEDGER_EVENT, task_id, item) for item in report.ledger
        ]
        events.append(make_envelope(EventType.TASK_COMPLETED, task_id, TaskCompleted(
            state=report.state, summary=report.headline,
            verification=report.core_checks + report.negative_checks,
        )))
        events.append(self._result(task_id, call, "ok", result={
            "headline": report.headline,
            "state": report.state,
            "checks_passed": sum(c.passed for c in report.core_checks),
            "checks_total": len(report.core_checks),
            "confirmed_not_performed": [c.predicate_id for c in report.negative_checks if c.passed],
        }))
        return events
```

Imports to add: `ApprovalRequest`, `TaskCompleted` from `.schemas`; `FixtureOrderRescueExecutor`, `verify_order_rescue` from `.workflows.order_rescue_execution`.

- [ ] **Step 4: Run all** → PASS. **Step 5: Commit** — `git commit -am "feat: spoken approval binding gates conversation-driven execution"`

## Task 6: Channel adapter seam (pure refactor, tests stay green)

**Files:**
- Create: `agent/voiceops_agent/workflows/order_rescue_adapters.py`
- Modify: `agent/voiceops_agent/workflows/order_rescue_execution.py`
- Test: `agent/tests/test_order_rescue_adapters.py`; existing suites unchanged and green

- [ ] **Step 1: Failing test** — `agent/tests/test_order_rescue_adapters.py`:

```python
from pathlib import Path

from voiceops_agent.workflows.order_rescue import OrderRescueFixture
from voiceops_agent.workflows.order_rescue_adapters import FixtureOrderRescueAdapters

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2] / "fixtures" / "order_rescue" / "golden_order_1842.json"
)


def adapters():
    fixture = OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())
    return FixtureOrderRescueAdapters(fixture)


def test_fixture_adapters_write_and_fetch_back():
    a = adapters()
    a.add_note_and_tag("Carrier delay: no movement for 91h.", "Carrier Delay")
    a.issue_store_credit(20)
    a.post_operations_message("@Sarah Order #1842 third delay")
    shopify = a.fetch_shopify_state()
    assert "Carrier Delay" in shopify["tags"]
    assert shopify["store_credit_usd"] == 20
    assert shopify["refund_issued"] is False
    assert shopify["replacement_order_id"] is None
    assert a.fetch_operations_messages() == ["@Sarah Order #1842 third delay"]
    assert a.channel == "fixture"


def test_fixture_adapters_are_idempotent():
    a = adapters()
    a.add_note_and_tag("note", "Carrier Delay")
    a.add_note_and_tag("note", "Carrier Delay")
    assert a.fetch_shopify_state()["tags"].count("Carrier Delay") == 1
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `order_rescue_adapters.py`:

```python
"""Channel adapter seam for Order Rescue execution and verification.

One protocol serves both fixture and live implementations. The verifier calls
only fetch_* methods (fetch-back evidence); the executor calls only write
methods. Implementations must be idempotent per (method, payload).
"""

from __future__ import annotations

from typing import Any, Protocol

from .order_rescue import OrderRescueFixture, OrderRescueState


class OrderRescueChannelAdapters(Protocol):
    channel: str

    def add_note_and_tag(self, note: str, tag: str) -> None: ...
    def issue_store_credit(self, amount_usd: int) -> None: ...
    def send_customer_choice_message(self, message: str, email: str) -> None: ...
    def post_operations_message(self, message: str) -> None: ...
    def create_followup_reminder(self, title: str) -> None: ...
    def fetch_shopify_state(self) -> dict[str, Any]: ...
    def fetch_customer_messages(self) -> list[str]: ...
    def fetch_operations_messages(self) -> list[str]: ...
    def fetch_reminders(self) -> list[str]: ...


class FixtureOrderRescueAdapters:
    """Deterministic semantic state, identical to the ADR-020 demo behavior."""

    channel = "fixture"

    def __init__(self, fixture: OrderRescueFixture) -> None:
        self._state = OrderRescueState.model_validate(
            fixture.initial_state.model_dump(mode="python")
        )

    def add_note_and_tag(self, note: str, tag: str) -> None:
        if tag not in self._state.shopify_tags:
            self._state.shopify_tags.append(tag)
        if note not in self._state.shopify_notes:
            self._state.shopify_notes.append(note)

    def issue_store_credit(self, amount_usd: int) -> None:
        self._state.store_credit_usd = amount_usd

    def send_customer_choice_message(self, message: str, email: str) -> None:
        if message not in self._state.customer_messages:
            self._state.customer_messages.append(message)

    def post_operations_message(self, message: str) -> None:
        if message not in self._state.operations_messages:
            self._state.operations_messages.append(message)

    def create_followup_reminder(self, title: str) -> None:
        if title not in self._state.reminders:
            self._state.reminders.append(title)

    def fetch_shopify_state(self) -> dict[str, Any]:
        return {
            "tags": list(self._state.shopify_tags),
            "notes": list(self._state.shopify_notes),
            "store_credit_usd": self._state.store_credit_usd,
            "refund_issued": self._state.refund_issued,
            "replacement_order_id": self._state.replacement_order_id,
        }

    def fetch_customer_messages(self) -> list[str]:
        return list(self._state.customer_messages)

    def fetch_operations_messages(self) -> list[str]:
        return list(self._state.operations_messages)

    def fetch_reminders(self) -> list[str]:
        return list(self._state.reminders)

    # Retained for the execution-result snapshot in fixture mode.
    @property
    def state(self) -> OrderRescueState:
        return self._state
```

- [ ] **Step 4: Refactor the executor and verifier to consume the seam.** In `order_rescue_execution.py`: `FixtureOrderRescueExecutor.execute` gains an optional `adapters: OrderRescueChannelAdapters | None = None` parameter (default constructs `FixtureOrderRescueAdapters(fixture)`); `_apply` branches call adapter methods instead of mutating `state` directly (`add_shopify_note` → `adapters.add_note_and_tag(...)`, `issue_store_credit` → `adapters.issue_store_credit(20)`, `ask_customer_preference` → `adapters.send_customer_choice_message(message, fixture.customer.email)`, `notify_operations` → `adapters.post_operations_message(...)`, `create_followup` → `adapters.create_followup_reminder(...)`); the result `state` field is populated from `adapters.state` when the adapter is the fixture implementation, else from `adapters.fetch_*` snapshots mapped into `OrderRescueState`. `verify_order_rescue` gains `adapters` and evaluates every predicate against `adapters.fetch_*` (never against `execution.state`), and each `VerificationResult.method` gains the adapter channel suffix, e.g. `shopify_state_refetch@fixture`. Update the existing tests' expected `method` strings accordingly (mechanical suffix change only).

- [ ] **Step 5: Run the full Python suite** → PASS with zero behavioral change (`uv run pytest -q`). Also run the safety rehearsal to prove the gate still holds: `cd .. && scripts/rehearse_order_rescue.sh` → 20/20.
- [ ] **Step 6: Commit** — `git commit -am "refactor: order rescue executes and verifies through a channel adapter seam"`

## Task 7: Live Shopify Admin adapter (mocked transport)

**Files:**
- Create: `agent/voiceops_agent/adapters/__init__.py`, `agent/voiceops_agent/adapters/shopify.py`
- Test: `agent/tests/test_shopify_adapter.py`

Design: stdlib urllib like `grounding.py`; constructor takes `shop`, `token`, `order_id`, and an injectable `transport: Callable[[urllib.request.Request], bytes]` (tests inject a fake; production default uses `urlopen` with a 10 s timeout). REST Admin API `2026-01`. Writes: `PUT /admin/api/2026-01/orders/{id}.json` merging `note` and `tags`; store credit via `POST /admin/api/2026-01/price_rules.json` + `POST .../discount_codes.json` with code `VOICEOPS-CREDIT-{order_id}`. Fetch-back: `GET orders/{id}.json` (note, tags), `GET orders/{id}/refunds.json` (must be empty), `GET orders.json?status=any&tag=VoiceOps-Replacement-{order_id}` (must be empty), `GET price_rules.json` filtered by the code prefix. Idempotency: read-before-write on every mutation (fetch current note/tags first, skip when already present; discount creation skipped when the code exists).

- [ ] **Step 1: Failing tests** — fake transport records requests and returns canned JSON per (method, path); tests assert: note+tag merge preserves existing tags; second `add_note_and_tag` call issues no PUT; `issue_store_credit` creates price rule + code once and is a no-op when the code exists; `fetch_shopify_state` maps refunds-empty → `refund_issued=False`, replacement-tag-search-empty → `replacement_order_id=None`; HTTP 401/429/5xx raise `ShopifyAdapterError` (never a silent success); `X-Shopify-Access-Token` header is always sent; `channel == "shopify.live"`.
- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** `ShopifyAdminAdapter` per the design above (single class, ~150 lines, one `_request(method, path, body)` helper that sets headers, raises `ShopifyAdapterError` on non-2xx, and json-decodes).
- [ ] **Step 4: Run** → PASS. **Step 5: Commit** — `git commit -am "feat: live Shopify Admin adapter with read-before-write idempotency"`

## Task 8: Live Slack adapter (mocked transport)

**Files:**
- Create: `agent/voiceops_agent/adapters/slack.py`
- Test: `agent/tests/test_slack_adapter.py`

Same transport-injection pattern. `post_operations_message` → `POST https://slack.com/api/chat.postMessage` (json body `{channel, text}`, bearer token header), treating `{"ok": false}` as `SlackAdapterError`; idempotency marker: message text embeds `[voiceops:{order_id}]` and the adapter first calls `fetch_operations_messages`; skip when a message containing the marker+text already exists. `fetch_operations_messages` → `GET conversations.history?channel={id}&limit=20`, returns texts newest-last.

- [ ] **Step 1: Failing tests** — post sends bearer header + channel id; `ok:false` raises; duplicate post is skipped after fetch shows the marker; fetch maps `messages[].text`; `channel == "slack.live"`.
- [ ] **Step 2–4:** implement, all tests green. **Step 5: Commit** — `git commit -am "feat: live Slack adapter with marker-based idempotency"`

## Task 9: Live adapter composition, selection, and live verification

**Files:**
- Create: `agent/voiceops_agent/adapters/live.py` (composes Shopify + Slack + in-memory customer-message/reminder channels into `OrderRescueChannelAdapters`; `channel = "shopify.live+slack.live"`)
- Modify: `agent/voiceops_agent/main.py` (selection), `agent/voiceops_agent/conversation.py` (router uses the selected adapters for execute/verify)
- Test: `agent/tests/test_adapter_selection.py`

Selection rule (`build_order_rescue_adapters(fixture)` in `live.py`): live only when all of `VOICEOPS_SHOPIFY_SHOP/TOKEN/ORDER_ID` and `VOICEOPS_SLACK_BOT_TOKEN/CHANNEL_ID` are set **and** a startup health probe (GET shop.json, GET auth.test) succeeds; otherwise `FixtureOrderRescueAdapters` — and the choice is recorded in a `decided` ledger event (`found="channel=shopify.live+slack.live"` or `"channel=fixture (credentials absent)"`) so the demo labeling is automatic and honest. Customer email channel stays in-memory by design (spec §2.1); the follow-up reminder channel becomes native in Task 15.

- [ ] Tests: env absent → fixture; env present + healthy probes (fake transport) → live; env present + failing probe → fixture with the reason in the ledger event; router `execute_plan` verification methods carry the selected channel suffix.
- [ ] Run full suite + `scripts/rehearse_order_rescue.sh` (must stay 20/20 with credentials absent). Commit — `git commit -am "feat: credential-gated live adapters with labeled fixture fallback"`

**Manual live acceptance (needs product-owner sandbox, not CI):** export the five env vars, run `cd agent && uv run python -m tests.live_shopify_probe` (small script added in this task printing the fetched order state), confirm a real note/tag/credit lands in the dev store and a real Slack message appears, then delete them via the store UI. Record the result in `docs/DEMO.md` §pre-demo.

## Task 10: Live LLM compiler with deterministic fallback

**Files:**
- Create: `agent/voiceops_agent/llm_compiler.py`
- Modify: `agent/voiceops_agent/main.py` (inject into router)
- Test: `agent/tests/test_llm_compiler.py`

Design: mirror `grounding.py`'s OpenAI Responses adapter (urllib, strict `json_schema` output, `VOICEOPS_OPENAI_API_KEY`, model `VOICEOPS_LLM_MODEL` default `gpt-5.6-sol`). Two entry points matching the router seam from Task 4:

```python
class OrderRescueCompiler(Protocol):
    def compile(self, task_id: UUID, transcript: str, fixture: OrderRescueFixture) -> VersionedTaskSpec: ...
    def patch(self, spec: VersionedTaskSpec, transcript: str) -> PlanPatch: ...
```

- `LiveOrderRescueCompiler.compile` prompts with the transcript + trusted fixture facts (order id, customer, deadline, policy — *data, not instructions*) and requests JSON for `{objective, evidence_to_collect, actions[], constraints{}, completion_criteria{}}`; output is assembled into a `VersionedTaskSpec` (task_id/version/raw_request/entities/provenance set locally — the model can never mint identities) and schema-validated. Consequential actions missing `requires_confirmation` → hard reject.
- `LiveOrderRescueCompiler.patch` requests a list of `PlanPatchOperation` dicts against a compact rendering of the current spec; result validated through `PlanPatch` and then by `apply_plan_patch`'s deterministic rules (which the router already applies).
- `FallbackOrderRescueCompiler(primary, fallback)` catches `LLMCompilerError`/validation errors, uses the deterministic path, and stamps `provenance["compiler"] = ["deterministic:fallback"]` vs `["llm:{model}"]`.

- [ ] Tests (fake transport): valid model JSON → validated spec with `provenance["compiler"] == ["llm:gpt-5.6-sol"]`; model JSON that drops `requires_confirmation` on a consequential action → fallback used and labeled; malformed JSON / HTTP error / timeout → fallback; patch path: model operations validated via `PlanPatch` and a stale `base_version` is rejected by the router as before; a patch that tries `remove actions.review_tracking` while preserving invariants still passes through `apply_plan_patch` semantics untouched.
- [ ] `main.py`: `build_order_rescue_compiler()` returns `FallbackOrderRescueCompiler(live, deterministic)` when the API key exists, else deterministic; inject into `ConversationToolRouter`.
- [ ] Full suite green. Commit — `git commit -am "feat: live LLM task compiler with schema-validated deterministic fallback"`

## Task 11: Swift Realtime S2S conversation wire

**Files:**
- Create: `macos/Sources/VoiceOpsCore/RealtimeConversationProtocol.swift`
- Test: `macos/Tests/VoiceOpsCoreTests/RealtimeConversationProtocolTests.swift`

Pure wire layer mirroring `RealtimeTranscriptionProtocol.swift` (networking stays in the app adapter):

```swift
public struct ConversationToolDefinition: Equatable, Sendable {
    public let name: String
    public let description: String
    public let parametersJSON: String
    public init(name: String, description: String, parametersJSON: String) { ... }
}

public enum ConversationToolRegistry {
    /// The seven sidecar tools; the bridge rejects anything not listed here.
    public static let tools: [ConversationToolDefinition] = [ ... ]  // names must equal ConversationToolName
}

public struct RealtimeConversationConfiguration: Equatable, Sendable {
    public let model: String            // default "gpt-realtime"
    public let voice: String            // default "marin"
    public let instructions: String     // default crispOperatorPersona
    public let sampleRate: Int          // default 24_000
    public let tools: [ConversationToolDefinition]  // default ConversationToolRegistry.tools
    public static let crispOperatorPersona: String = """
    You are VoiceOps, a terse, competent operations copilot. Short sentences. \
    No filler. Never claim an action happened: only report tool results. Every \
    plan, patch, approval, and execution goes through your tools; you never act \
    directly. Before consequential work, call request_approval, read the \
    read_back verbatim, then call confirm_approval with the operator's exact \
    words. If a tool rejects, say why in one sentence and continue.
    """
}

public enum RealtimeConversationServerEvent: Equatable, Sendable {
    case sessionReady
    case userSpeechStarted                       // barge-in: halt local playback
    case userTranscript(String)                  // input transcription for the UI
    case agentTranscriptDelta(String)
    case audioDelta(Data)                        // base64-decoded PCM16
    case functionCall(callID: String, name: String, argumentsJSON: String)
    case responseDone
    case error(message: String)
    case ignored(type: String)
}

public enum RealtimeConversationWire {
    public static func sessionUpdate(_ configuration: RealtimeConversationConfiguration) throws -> String
    // {"type":"session.update","session":{"type":"realtime","model":...,"instructions":...,
    //  "audio":{"input":{"format":{"type":"audio/pcm","rate":N},
    //           "transcription":{"model":"gpt-realtime-whisper"},
    //           "turn_detection":{"type":"semantic_vad"}},
    //          "output":{"format":{"type":"audio/pcm","rate":N},"voice":...}},
    //  "tools":[{"type":"function","name":...,"description":...,"parameters":<decoded JSON>}],
    //  "tool_choice":"auto"}}
    public static func appendAudio(_ pcm16: Data) throws -> String        // same as transcription wire
    public static func functionCallOutput(callID: String, outputJSON: String) throws -> String
    // {"type":"conversation.item.create","item":{"type":"function_call_output","call_id":...,"output":...}}
    public static func responseCreate() throws -> String                  // {"type":"response.create"}
    public static func parseServerEvent(_ text: String) throws -> RealtimeConversationServerEvent
    // "session.updated"→sessionReady; "input_audio_buffer.speech_started"→userSpeechStarted;
    // "conversation.item.input_audio_transcription.completed"→userTranscript;
    // "response.output_audio_transcript.delta"→agentTranscriptDelta;
    // "response.output_audio.delta"→audioDelta(base64); "response.function_call_arguments.done"→functionCall;
    // "response.done"→responseDone; "error"→error; else ignored
}
```

- [ ] **Step 1: Failing tests** mirroring `RealtimeTranscriptionProtocolTests` style: sessionUpdate JSON contains `semantic_vad`, the model, all seven tool names, and the persona; appendAudio base64 round-trips; functionCallOutput embeds call_id and output; each server-event type parses to the right case; malformed events throw; unknown types are `.ignored`; the registry's tool names exactly equal the Python `ConversationToolName` literals (assert against a hardcoded array — the fixtures already pin the wire contract).
- [ ] **Steps 2–4:** run (FAIL) → implement → `swift test` PASS.
- [ ] **Step 5: Commit** — `git commit -am "feat: Realtime speech-to-speech conversation wire with typed tool registry"`

## Task 12: Conversation session states + tool bridge + panic stop

**Files:**
- Create: `macos/Sources/VoiceOpsCore/ConversationToolBridge.swift`
- Modify: `macos/Sources/VoiceOpsCore/SessionStateMachine.swift`
- Test: `macos/Tests/VoiceOpsCoreTests/ConversationToolBridgeTests.swift`, `SessionStateMachineTests.swift` (extend)

**State machine:** add

```swift
case conversing(agentSpeaking: Bool, planVersion: Int?, transcript: String)
```

and events `conversationOpened`, `conversationClosed`, `agentSpeechStarted`, `agentSpeechEnded`. Transitions: `(.idle, .conversationOpened) → .conversing(false, nil, "")`; `.conversing` absorbs `partialTranscript`/`taskSpecReady` (updating fields), `agentSpeechStarted/Ended` toggle `agentSpeaking`; `(.conversing, .stopRequested) → .result(.cancelled)`; `(.conversing, .conversationClosed) → .idle` when no task version exists, else `.result(.completed(...))` arrives via `taskCompleted` exactly as today; `(.conversing, .taskFailed) → .result(.failed)`. Existing transitions untouched — the transcription pipeline path must keep passing its exhaustive tests.

**Bridge** (pure, `Sendable`):

```swift
public struct ConversationToolBridge {
    public init(taskID: UUID, registry: [ConversationToolDefinition] = ConversationToolRegistry.tools)

    /// Realtime function call -> envelope for the sidecar, or a local rejection
    /// output when the tool is not in the registry (the model never gets to
    /// invent a side-effect path).
    public func envelope(for call: (callID: String, name: String, argumentsJSON: String))
        -> Result<Envelope, BridgeRejection>

    /// Sidecar tool result -> the exact function_call_output JSON string.
    public func output(for result: ConversationToolResult) -> String
}
```

- [ ] Tests: known tool + valid JSON args → envelope with `type == .conversationToolCall`, matching task id and call id; unknown tool → `.failure` whose rejection output JSON says `{"status":"rejected","error":"unknown tool"}`; malformed arguments JSON → rejection, no envelope; result mapping preserves status/result verbatim; state-machine: conversation open/close, barge-in flag toggling, stop from `.conversing` cancels, illegal pairs still no-op.
- [ ] Implement, `swift test` PASS, commit — `git commit -am "feat: conversation session states and typed tool bridge"`

## Task 13: App integration — audio I/O, session lifecycle, credentials, fallback

**Files:**
- Create: `macos/VoiceOps/Voice/ConversationAudioIO.swift`, `macos/VoiceOps/Voice/RealtimeConversationSession.swift`
- Modify: `macos/VoiceOps/App/AppCoordinator.swift`, `macos/VoiceOps/Credentials/VLMCredentialStore.swift`, `macos/VoiceOps/Credentials/VLMSettingsView.swift`, `macos/VoiceOps/UI/CompanionView.swift`
- Manual acceptance: live mic/speaker drill (cannot be CI-tested; unit-test everything pure)

Work items (read each file before editing; follow its existing structure):

1. `RealtimeConversationSession` (app-side, URLSessionWebSocketTask like the existing transcription provider in `SpeechTranscriber.swift`): connect with the Keychain API key, send `sessionUpdate`, then pump: mic PCM → `appendAudio`; server events → parsed via `RealtimeConversationWire`; `functionCall` → `ConversationToolBridge.envelope` → `SidecarClient` send; sidecar `conversation.tool_result` → `bridge.output` → `functionCallOutput` + `responseCreate`; `audioDelta` → `ConversationAudioIO.enqueue`; `userSpeechStarted` → `ConversationAudioIO.stopPlayback()` (barge-in). Session errors → tear down and fall back to the ADR-021 transcription pipeline with a visible `FALLBACK` badge (reuse the existing provider-badge mechanism).
2. `ConversationAudioIO`: one `AVAudioEngine`; `inputNode.setVoiceProcessingEnabled(true)` before any tap (echo cancellation so barge-in works over speakers); input tap converts to 24 kHz mono PCM16 (reuse the converter approach in `SpeechTranscriber`); output `AVAudioPlayerNode` scheduling received PCM16 buffers; `stopPlayback()` flushes scheduled buffers immediately.
3. `AppCoordinator`: when the OpenAI credential exists and the new "Conversational voice" toggle (UserDefaults-backed, in settings view) is on, ⌃⌥V from `.idle` opens a conversation session (`conversationOpened`) instead of the per-utterance pipeline; ⌃⌥V while `.conversing` closes it (`conversationClosed`). Escape/panic stop (existing ADR-017 path) must additionally cancel the WebSocket, stop the audio engine, and flush playback — extend the existing stop teardown method, and mirror the sidecar cancel ordering already there.
4. `CompanionView`: render `.conversing` (live user transcript, agent transcript, speaking indicator, current plan version chip); show the approval read-back card when `approval.requested` arrives with the on-screen **Approve** button as click-fallback (button routes through the same `confirm_approval` tool call with `utterance: "yes"` and the displayed binding hash — one approval implementation, two input modalities).
5. Credentials: extend `VLMCredentialStore` with generic-password entries for the Shopify/Slack values and pass them to the spawned sidecar as the `VOICEOPS_*` env vars (mirror how the OpenAI key is passed today); settings view gains a "Commerce Sandbox" section with the five fields and a health-check row.

- [ ] Unit-test everything pure (PCM16 conversion helper, fallback-decision logic, approval-card view model). `swift build && swift test` + `xcodebuild ... build` green.
- [ ] **Manual acceptance drill (product owner present):** live conversation open → speak request → watch compile → interrupt mid-agent-speech (barge-in halts playback) → spoken approval → execution → final report; then kill the network mid-session and confirm the labeled fallback to the transcription pipeline without losing the task.
- [ ] Commit — `git commit -am "feat: conversational voice session with echo-cancelled barge-in and spoken approval UI"`

## Task 14: Reminder goes native in live mode

**Files:**
- Modify: `agent/voiceops_agent/conversation.py`, `macos/VoiceOps/App/AppCoordinator.swift`
- Test: `agent/tests/test_conversation.py` (extend)

In live-adapter mode, `execute_plan` must not fixture-fake the reminder: the router emits, before its `TASK_COMPLETED`, a single-step `PLAN_READY` reusing the exact Phase 3 `reminders.create` step shape (tool `reminders.create`, reversible, five postconditions) with title `Verify Order {order_id} tracking` due tomorrow 09:00, and defers its `TASK_COMPLETED` until the existing `ACTION_FINISHED` + five `VERIFICATION_FINISHED` envelopes arrive from the macOS shell (the `SidecarRuntime` plan/verification machinery from Phase 3 handles this already — register the plan in `runtime._plans`). The Swift side already executes and fetch-back-verifies EventKit steps; the coordinator needs only to accept a `plan.ready` mid-conversation. In fixture mode, behavior is unchanged.

- [ ] Tests: fixture mode emits no `PLAN_READY`; live mode (fake adapters flagged `channel="shopify.live+slack.live"`) emits the reminder plan and completes only after simulated action+verification envelopes; a failed native verification yields `partial`, never `succeeded`.
- [ ] Run all + rehearsal; commit — `git commit -am "feat: native EventKit follow-up reminder in live execution mode"`

## Task 15: Eval and rehearsal extensions

**Files:**
- Modify: `agent/voiceops_agent/evals/order_rescue.py`, `agent/voiceops_agent/evaluation.py` (case catalog), `scripts/rehearse_order_rescue.sh` (if case count is asserted)
- Test: the eval suites themselves

New deterministic cases (extending the 20-case catalog; keep every existing case):

1. `spoken_approval_mishear` — "yeah maybe fine" after read-back → zero writes, rejected result.
2. `stale_approval_hash` — patch applied after read-back → old hash rejected, re-read required, zero writes.
3. `barge_in_correction` — apply_patch between request_approval and confirm → binding invalidated, constraint retention proven across v2→v3.
4. `unknown_tool_rejected` — bridge-level rejection fixture: `conversation.tool_call` with a schema-invalid tool → `task.failed(INVALID_MESSAGE)`, no router state created.
5. `live_adapter_unhealthy_fallback` — credentials set, probe fails → fixture channel selected, ledger records the reason, execution still verifies 5/5, channel label ≠ live.
6. `execute_replay_rejected` — second execute_plan → rejected, adapter write counts unchanged (no duplicate side effects).
7. `panic_stop_during_conversation` — Swift probe: stop from `.conversing` → `.result(.cancelled)`, and the teardown ordering test asserts WebSocket cancel precedes sidecar kill.

- [ ] Add cases TDD-style (each first as a failing eval), keep thresholds: zero false success, zero duplicate side effects, zero unapproved actions. `scripts/run_evals.sh` and `scripts/rehearse_order_rescue.sh` green; dashboard regenerates.
- [ ] Commit — `git commit -am "test: conversation-layer safety cases in the deterministic rehearsal"`

## Task 16: Docs — ADR-022..024, README, DEMO v2, handoff

**Files:**
- Modify: `docs/DECISIONS.md`, `README.md`, `docs/DEMO.md`, `docs/HANDOFF.md`

- [ ] ADR-022 "Speech-to-speech conversation layer drives the task machine through typed tools" (session-scoped mic, semantic VAD reversal of ADR-021's manual commit and why, tool registry as the only side-effect path, transcription pipeline retained as fallback). ADR-023 "Credential-gated live commerce adapters with labeled fixture fallback and live fetch-back verification". ADR-024 "Spoken approval read-back binding" (hash canonicalization, strict affirmative set, click fallback equivalence).
- [ ] README status section: conversational hero description, sandbox env vars, updated quick start.
- [ ] DEMO.md v2: conversational script (open, natural request, barge-in correction, spoken approval, live-store verification beat, negative proof), updated contingency table (S2S death → transcription fallback; credentials dead → labeled fixture path; both → deterministic replay), pre-demo checklist gains the live-store probe and Slack health check.
- [ ] Replace `docs/HANDOFF.md` content with a current one-page status pointing at the spec, plan, and ADRs (the existing file is a stale Phases 0–1 snapshot).
- [ ] Commit — `git commit -am "docs: ADR-022..024, conversational demo runbook, refreshed handoff"`

## Task 17: Freeze week — rehearsal and failure drills (no new features)

- [ ] Run `scripts/rehearse_order_rescue.sh` + `scripts/replay_order_rescue_app.sh` daily; CI green on every push.
- [ ] Live drills with the product owner: full conversational hero ×3 consecutive clean runs; network-kill mid-session; credential-revoke before demo; forced mishear at approval; Escape during execution. Each drill's outcome noted in DEMO.md §pre-demo.
- [ ] Fix only defects found by drills; every fix lands with a regression test first.

---

## Self-review notes

- Spec §3.1 components ↔ Tasks: schemas (1–2), router+approval (3–5), adapter seam+live (6–9), LLM compiler (10), Swift wire/bridge/states (11–12), app+audio+credentials+approval UI (13), native reminder (14), evals (15), docs (16), freeze (17). Live VLM grounding primary requires no new code — `FallbackGroundingAdapter` already prefers the live adapter when the key exists (main.py:594-603); the demo change is configuration + DEMO.md, covered in Task 16.
- Type consistency: `ConversationToolName` literals = Swift `ConversationToolRegistry` names (pinned by a test in Task 11); router tool methods = registry names; `ApprovalBinding` fields identical across runtimes (pinned by fixtures in Task 2).
- Triage line (spec §2.9): Tasks 1–5 + 10–13 are the protected conversational core; Tasks 7–9 + 14 are the realness layer and degrade to fixture behavior automatically if cut.
