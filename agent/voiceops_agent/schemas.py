"""Versioned IPC envelope and task object schemas.

Single source of truth for the Swift<->Python wire contract (ARD §7). The Swift
`VoiceOpsCore` Codable types mirror these models and are held to them by the
shared fixtures in fixtures/ipc/. Run `uv run voiceops-export-schemas` after any
change here to refresh the committed JSON Schema exports in schemas/.
"""

from __future__ import annotations

import json
import sys
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Any, Literal
from uuid import UUID, uuid4

from pydantic import BaseModel, ConfigDict, Field, SerializeAsAny, model_validator

PROTOCOL_VERSION = "1.0"


class VoiceOpsModel(BaseModel):
    """Strict base: unknown fields are protocol errors, not noise to ignore."""

    model_config = ConfigDict(extra="forbid")


class EventType(StrEnum):
    VOICE_PARTIAL = "voice.partial"
    VOICE_FINAL = "voice.final"
    OBSERVATION_READY = "observation.ready"
    GROUNDING_READY = "grounding.ready"
    PLAN_READY = "plan.ready"
    APPROVAL_REQUESTED = "approval.requested"
    ACTION_STARTED = "action.started"
    ACTION_FINISHED = "action.finished"
    VERIFICATION_FINISHED = "verification.finished"
    TASK_COMPLETED = "task.completed"
    TASK_FAILED = "task.failed"
    TASK_CANCELLED = "task.cancelled"


Risk = Literal["read", "reversible_write", "consequential", "destructive"]
CandidateSource = Literal["accessibility", "ocr", "vision", "dom"]
TaskState = Literal["succeeded", "partial", "failed", "needs_user"]


class FailureCode(StrEnum):
    TARGET_NOT_FOUND = "TARGET_NOT_FOUND"
    TARGET_STALE = "TARGET_STALE"
    NO_STATE_CHANGE = "NO_STATE_CHANGE"
    PERMISSION_DENIED = "PERMISSION_DENIED"
    APP_NOT_RUNNING = "APP_NOT_RUNNING"
    TIMEOUT = "TIMEOUT"
    AMBIGUOUS_STATE = "AMBIGUOUS_STATE"
    MODEL_INVALID_OUTPUT = "MODEL_INVALID_OUTPUT"
    CONSEQUENTIAL_STATE_UNCERTAIN = "CONSEQUENTIAL_STATE_UNCERTAIN"
    INVALID_MESSAGE = "INVALID_MESSAGE"


# --- Voice ---


class TranscriptSegment(VoiceOpsModel):
    text: str
    start_ms: int = Field(ge=0)
    end_ms: int = Field(ge=0)
    confidence: float = Field(ge=0.0, le=1.0)


class TranscriptPartial(VoiceOpsModel):
    transcript: str
    confidence: float | None = Field(default=None, ge=0.0, le=1.0)
    locale: str | None = None


class VoiceRequest(VoiceOpsModel):
    transcript: str = Field(min_length=1)
    locale: str = "en-US"
    confidence: float = Field(ge=0.0, le=1.0)
    segments: list[TranscriptSegment] = Field(default_factory=list)


# --- Observation and grounding ---


class AppRef(VoiceOpsModel):
    bundle_id: str
    name: str


class WindowRef(VoiceOpsModel):
    title: str
    bounds: tuple[float, float, float, float]


class UIElementCandidate(VoiceOpsModel):
    id: str
    role: str | None = None
    label: str | None = None
    value: str | None = None
    bounds: tuple[float, float, float, float]
    source: CandidateSource
    confidence: float = Field(ge=0.0, le=1.0)
    actions: list[str] = Field(default_factory=list)
    app_bundle_id: str
    stable_attributes: dict[str, str] = Field(default_factory=dict)


class Observation(VoiceOpsModel):
    capture_id: UUID
    timestamp: datetime
    active_app: AppRef
    window: WindowRef
    focused_element_id: str | None = None
    pointer: tuple[float, float] | None = None
    elements: list[UIElementCandidate] = Field(default_factory=list)
    screenshot_path: str | None = None


class ResolvedReference(VoiceOpsModel):
    phrase: str
    candidate_id: str
    resolved_text: str
    confidence: float = Field(ge=0.0, le=1.0)
    provenance: dict[str, Any]


class GroundingResult(VoiceOpsModel):
    references: list[ResolvedReference]
    adapter: Literal["openai", "deterministic"]
    warnings: list[str] = Field(default_factory=list)


# --- Task objects ---


class Predicate(VoiceOpsModel):
    id: str
    description: str
    expected: dict[str, Any]


class VerifierSpec(VoiceOpsModel):
    kind: Literal["structured", "visual", "content", "composite"]
    description: str


class TaskStep(VoiceOpsModel):
    id: str
    description: str
    tool: str
    arguments: dict[str, Any]
    preconditions: list[Predicate] = Field(default_factory=list)
    postconditions: list[Predicate]
    risk: Risk
    requires_confirmation: bool
    fallback_tools: list[str] = Field(default_factory=list)
    max_attempts: int = Field(default=2, ge=1)
    timeout_seconds: int = Field(default=30, ge=1)
    verifier: VerifierSpec

    @model_validator(mode="after")
    def _consequential_needs_confirmation(self) -> "TaskStep":
        if self.risk in ("consequential", "destructive") and not self.requires_confirmation:
            raise ValueError(
                f"steps with risk={self.risk!r} must set requires_confirmation=true"
            )
        return self


class TaskPlan(VoiceOpsModel):
    goal: str
    summary: str
    steps: list[TaskStep] = Field(min_length=1)


# --- Action and verification ---


class ApprovalRequest(VoiceOpsModel):
    step_id: str
    description: str
    risk: Risk
    data_preview: dict[str, Any] = Field(default_factory=dict)


class ActionStarted(VoiceOpsModel):
    step_id: str
    tool: str
    channel: str


class StructuredError(VoiceOpsModel):
    code: FailureCode
    message: str
    details: dict[str, Any] = Field(default_factory=dict)


class ActionResult(VoiceOpsModel):
    step_id: str
    status: Literal["executed", "no_op", "failed", "uncertain"]
    started_at: datetime
    ended_at: datetime
    channel: str
    target_provenance: dict[str, Any] = Field(default_factory=dict)
    raw_result: dict[str, Any] = Field(default_factory=dict)
    state_change_hint: str | None = None
    error: StructuredError | None = None


class VerificationResult(VoiceOpsModel):
    predicate_id: str
    passed: bool
    method: str
    confidence: float = Field(ge=0.0, le=1.0)
    expected: dict[str, Any]
    observed: dict[str, Any]
    evidence_ids: list[str] = Field(default_factory=list)
    failure_reason: str | None = None


class TaskCompleted(VoiceOpsModel):
    state: TaskState
    summary: str
    verification: list[VerificationResult] = Field(default_factory=list)

    @model_validator(mode="after")
    def _succeeded_requires_passing_verification(self) -> "TaskCompleted":
        # Invariant 2 (CLAUDE.md): only verifier evidence can justify SUCCEEDED.
        if self.state == "succeeded" and (
            not self.verification or not all(v.passed for v in self.verification)
        ):
            raise ValueError(
                "state='succeeded' requires non-empty verification with every predicate passed"
            )
        return self


class TaskFailure(VoiceOpsModel):
    error: StructuredError
    summary: str | None = None


class TaskCancelled(VoiceOpsModel):
    reason: str | None = None


EVENT_PAYLOADS: dict[EventType, type[VoiceOpsModel]] = {
    EventType.VOICE_PARTIAL: TranscriptPartial,
    EventType.VOICE_FINAL: VoiceRequest,
    EventType.OBSERVATION_READY: Observation,
    EventType.GROUNDING_READY: GroundingResult,
    EventType.PLAN_READY: TaskPlan,
    EventType.APPROVAL_REQUESTED: ApprovalRequest,
    EventType.ACTION_STARTED: ActionStarted,
    EventType.ACTION_FINISHED: ActionResult,
    EventType.VERIFICATION_FINISHED: VerificationResult,
    EventType.TASK_COMPLETED: TaskCompleted,
    EventType.TASK_FAILED: TaskFailure,
    EventType.TASK_CANCELLED: TaskCancelled,
}


class Envelope(VoiceOpsModel):
    version: Literal["1.0"]
    id: UUID
    type: EventType
    task_id: UUID
    timestamp: datetime
    payload: SerializeAsAny[VoiceOpsModel]

    @model_validator(mode="before")
    @classmethod
    def _resolve_payload_type(cls, data: Any) -> Any:
        if isinstance(data, dict):
            try:
                event = EventType(data.get("type"))
            except ValueError:
                return data  # field validation reports the unknown type
            payload = data.get("payload")
            if isinstance(payload, dict):
                data = {**data, "payload": EVENT_PAYLOADS[event].model_validate(payload)}
        return data

    @model_validator(mode="after")
    def _payload_matches_type(self) -> "Envelope":
        expected = EVENT_PAYLOADS[self.type]
        if not isinstance(self.payload, expected):
            raise ValueError(
                f"payload for {self.type} must be {expected.__name__}, "
                f"got {type(self.payload).__name__}"
            )
        return self

    def to_wire_dict(self) -> dict[str, Any]:
        return self.model_dump(mode="json")

    def to_ndjson(self) -> str:
        return json.dumps(self.to_wire_dict(), separators=(",", ":")) + "\n"


def parse_envelope(data: str | bytes | dict[str, Any]) -> Envelope:
    """Validate one wire message. Raises ValueError/ValidationError on any defect."""
    if isinstance(data, (str, bytes)):
        data = json.loads(data)
    return Envelope.model_validate(data)


def make_envelope(type: EventType, task_id: UUID, payload: VoiceOpsModel) -> Envelope:
    return Envelope(
        version=PROTOCOL_VERSION,
        id=uuid4(),
        type=type,
        task_id=task_id,
        # Whole seconds keep the wire format inside strict ISO-8601 parsers (Swift).
        timestamp=datetime.now(UTC).replace(microsecond=0),
        payload=payload,
    )


_EXPORTED_MODELS: tuple[type[VoiceOpsModel], ...] = (
    Envelope,
    TranscriptPartial,
    TranscriptSegment,
    VoiceRequest,
    Observation,
    UIElementCandidate,
    GroundingResult,
    TaskPlan,
    TaskStep,
    Predicate,
    VerifierSpec,
    ApprovalRequest,
    ActionStarted,
    ActionResult,
    StructuredError,
    VerificationResult,
    TaskCompleted,
    TaskFailure,
    TaskCancelled,
)


def export_json_schemas(target_dir: Path) -> list[Path]:
    target_dir = Path(target_dir)
    target_dir.mkdir(parents=True, exist_ok=True)
    written: list[Path] = []
    for model in _EXPORTED_MODELS:
        path = target_dir / f"{model.__name__}.json"
        path.write_text(json.dumps(model.model_json_schema(), indent=2) + "\n")
        written.append(path)
    return written


def export_json_schemas_cli() -> None:
    default = Path(__file__).resolve().parents[2] / "schemas"
    target = Path(sys.argv[1]) if len(sys.argv) > 1 else default
    for path in export_json_schemas(target):
        print(path)
