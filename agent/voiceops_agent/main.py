"""Typed mock sidecar: NDJSON envelopes on stdin/stdout.

It optionally correlates an observation.ready with voice.final, emits grounded
screen references, then returns the Phase 0 schema-valid mock plan and verified
completion. Real planning, policy, and action subsystems replace
build_mock_plan in later phases; the wire contract stays stable.
"""

from __future__ import annotations

import json
import sys
from uuid import UUID, uuid4

from .grounding import (
    DeterministicMultimodalGroundingAdapter,
    GroundingInput,
    MultimodalGroundingAdapter,
)

from .schemas import (
    Envelope,
    EventType,
    FailureCode,
    Observation,
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


class SidecarRuntime:
    """Task-correlated state for the long-lived NDJSON sidecar process."""

    def __init__(
        self,
        grounding_adapter: MultimodalGroundingAdapter | None = None,
    ) -> None:
        self._observations: dict[UUID, Observation] = {}
        self._grounding_adapter = (
            grounding_adapter or DeterministicMultimodalGroundingAdapter()
        )

    def handle_line(self, line: str) -> list[Envelope]:
        try:
            envelope = parse_envelope(line)
        except ValueError as exc:
            return [_failure(line, exc)]

        if envelope.type is EventType.OBSERVATION_READY:
            self._observations[envelope.task_id] = envelope.payload
            return []

        if envelope.type is EventType.TASK_CANCELLED:
            self._observations.pop(envelope.task_id, None)
            return []

        if envelope.type is not EventType.VOICE_FINAL:
            return []

        events: list[Envelope] = []
        observation = self._observations.pop(envelope.task_id, None)
        if observation is not None:
            try:
                grounding = self._grounding_adapter.resolve(
                    GroundingInput(request=envelope.payload, observation=observation)
                )
            except Exception as error:
                failure = TaskFailure(
                    error=StructuredError(
                        code=FailureCode.MODEL_INVALID_OUTPUT,
                        message=f"Screen grounding failed: {str(error)[:400]}",
                    ),
                    summary="The visible context could not be grounded safely",
                )
                return [make_envelope(EventType.TASK_FAILED, envelope.task_id, failure)]
            events.append(
                make_envelope(EventType.GROUNDING_READY, envelope.task_id, grounding)
            )

        plan = build_mock_plan(envelope.payload)
        completion_summary = (
            "Phase 2 mock exchange: screen references grounded and plan validated"
            if observation is not None
            else "Phase 0 mock exchange: request validated and mock plan produced"
        )
        completed = TaskCompleted(
            state="succeeded",
            summary=completion_summary,
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
        return events + [
            make_envelope(EventType.PLAN_READY, envelope.task_id, plan),
            make_envelope(EventType.TASK_COMPLETED, envelope.task_id, completed),
        ]


def handle_line(line: str) -> list[Envelope]:
    """Stateless compatibility helper used by Phase 0 contract tests."""
    return SidecarRuntime().handle_line(line)


def main() -> None:
    runtime = SidecarRuntime()
    for line in sys.stdin:
        if not line.strip():
            continue
        for event in runtime.handle_line(line):
            sys.stdout.write(event.to_ndjson())
        sys.stdout.flush()


if __name__ == "__main__":
    main()
