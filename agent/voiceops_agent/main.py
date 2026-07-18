"""Phase 0 mock sidecar: NDJSON envelopes on stdin/stdout.

Answers voice.final with a schema-valid mock plan.ready followed by
task.completed. Real planning, policy, and verification subsystems replace
build_mock_plan in later phases; the wire contract stays the same.
"""

from __future__ import annotations

import json
import sys
from uuid import UUID, uuid4

from .schemas import (
    Envelope,
    EventType,
    FailureCode,
    Predicate,
    StructuredError,
    TaskCompleted,
    TaskFailure,
    TaskPlan,
    TaskStep,
    VerificationResult,
    VerifierSpec,
    VoiceRequest,
    make_envelope,
    parse_envelope,
)


def build_mock_plan(request: VoiceRequest) -> TaskPlan:
    predicate = Predicate(
        id="pred-reminder-exists",
        description="A reminder with the extracted commitment exists in the configured list",
        expected={"source_transcript": request.transcript},
    )
    step = TaskStep(
        id="step-1",
        description="Create a reminder for the spoken commitment via EventKit",
        tool="reminders.create",
        arguments={"transcript": request.transcript, "locale": request.locale},
        postconditions=[predicate],
        risk="reversible_write",
        requires_confirmation=False,
        fallback_tools=["applescript.reminders"],
        verifier=VerifierSpec(
            kind="structured",
            description="Fetch the reminder back through EventKit and compare normalized fields",
        ),
    )
    return TaskPlan(
        goal=request.transcript,
        summary="Mock Phase 0 plan: one verified EventKit write",
        steps=[step],
    )


def _extract_task_id(line: str) -> UUID | None:
    try:
        return UUID(str(json.loads(line).get("task_id")))
    except (ValueError, AttributeError):
        return None


def _failure(line: str, error: Exception) -> Envelope:
    payload = TaskFailure(
        error=StructuredError(
            code=FailureCode.INVALID_MESSAGE,
            message=str(error)[:500],
        ),
        summary="Message rejected before task execution",
    )
    return make_envelope(EventType.TASK_FAILED, _extract_task_id(line) or uuid4(), payload)


def handle_line(line: str) -> list[Envelope]:
    try:
        envelope = parse_envelope(line)
    except ValueError as exc:
        return [_failure(line, exc)]

    if envelope.type is not EventType.VOICE_FINAL:
        return []

    plan = build_mock_plan(envelope.payload)
    completed = TaskCompleted(
        state="succeeded",
        summary="Phase 0 mock exchange: request validated and mock plan produced",
        verification=[
            VerificationResult(
                predicate_id="phase0-plan-validates",
                passed=True,
                method="schema_validation",
                confidence=1.0,
                expected={"plan": "validates against TaskPlan schema"},
                observed={"steps": len(plan.steps)},
            )
        ],
    )
    return [
        make_envelope(EventType.PLAN_READY, envelope.task_id, plan),
        make_envelope(EventType.TASK_COMPLETED, envelope.task_id, completed),
    ]


def main() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        for event in handle_line(line):
            sys.stdout.write(event.to_ndjson())
        sys.stdout.flush()


if __name__ == "__main__":
    main()
