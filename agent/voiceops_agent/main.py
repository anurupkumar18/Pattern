"""Typed VoiceOps sidecar: NDJSON envelopes on stdin/stdout.

It optionally correlates an observation.ready with voice.final, emits grounded
screen references, and runs the Phase 3 Screen-to-Reminder orchestration. The
legacy Phase 0 mock exchange remains for voice-only contract checks; a grounded
reminder can complete only after a native action result and every independent
verification predicate arrive from the macOS shell.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from uuid import UUID, uuid4

from .grounding import (
    DeterministicMultimodalGroundingAdapter,
    FallbackGroundingAdapter,
    GroundingInput,
    MultimodalGroundingAdapter,
    OpenAIMultimodalGroundingAdapter,
)

from .schemas import (
    ActionResult,
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
    VersionedTaskSpec,
    VoiceRequest,
    make_envelope,
    parse_envelope,
)
from .workflows.order_rescue import (
    OrderRescueFixture,
    OrderRescuePlanningError,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)
from .workflows.order_rescue_execution import (
    FixtureOrderRescueExecutor,
    OrderRescueExecutionError,
    verify_order_rescue,
)
from .workflows.reminders import ReminderPlanningError, build_reminder_plan
from .workflows.meeting_briefing import build_meeting_briefing_plan
from .workflows.research_followup import (
    CompanyResearchAdapter,
    ResearchPlanningError,
    build_research_followup_plan,
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
        research_adapter: CompanyResearchAdapter | None = None,
        order_rescue_fixture: OrderRescueFixture | None = None,
    ) -> None:
        self._observations: dict[UUID, Observation] = {}
        self._grounding_adapter = grounding_adapter or build_grounding_adapter()
        self._research_adapter = research_adapter
        self._plans: dict[UUID, TaskPlan] = {}
        self._actions: dict[UUID, dict[str, ActionResult]] = {}
        self._verifications: dict[UUID, dict[str, VerificationResult]] = {}
        self._order_rescue_fixture = order_rescue_fixture or load_order_rescue_fixture()
        self._order_rescue_tasks: dict[UUID, VersionedTaskSpec] = {}

    def handle_line(self, line: str) -> list[Envelope]:
        try:
            envelope = parse_envelope(line)
        except ValueError as exc:
            return [_failure(line, exc)]

        if envelope.type is EventType.OBSERVATION_READY:
            self._observations[envelope.task_id] = envelope.payload
            return []

        if envelope.type is EventType.TASK_CANCELLED:
            self._cleanup(envelope.task_id)
            return []

        if envelope.type is EventType.ACTION_FINISHED:
            return self._handle_action_finished(envelope.task_id, envelope.payload)

        if envelope.type is EventType.VERIFICATION_FINISHED:
            return self._handle_verification_finished(
                envelope.task_id, envelope.payload
            )

        if envelope.type is EventType.VOICE_CORRECTION:
            return self._handle_order_rescue_correction(
                envelope.task_id, envelope.payload
            )

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

            if self._is_order_rescue(envelope.payload, observation):
                task = compile_order_rescue_task(
                    envelope.task_id,
                    envelope.payload.transcript,
                    self._order_rescue_fixture,
                )
                self._order_rescue_tasks[envelope.task_id] = task
                return events + [
                    make_envelope(EventType.TASK_SPEC_READY, envelope.task_id, task)
                ]

            if self._is_screen_to_reminder(envelope.payload):
                try:
                    plan = build_reminder_plan(
                        envelope.task_id,
                        envelope.payload,
                        observation,
                        grounding,
                    )
                except ReminderPlanningError as error:
                    failure = TaskFailure(
                        error=StructuredError(
                            code=FailureCode.AMBIGUOUS_STATE,
                            message=str(error),
                        ),
                        summary="One reminder detail needs clarification",
                    )
                    return events + [
                        make_envelope(
                            EventType.TASK_FAILED, envelope.task_id, failure
                        )
                    ]
                self._plans[envelope.task_id] = plan
                self._verifications[envelope.task_id] = {}
                return events + [
                    make_envelope(EventType.PLAN_READY, envelope.task_id, plan)
                ]

            if self._is_meeting_briefing(envelope.payload):
                plan = build_meeting_briefing_plan(
                    envelope.task_id,
                    envelope.payload,
                    observation,
                )
                self._plans[envelope.task_id] = plan
                self._verifications[envelope.task_id] = {}
                return events + [
                    make_envelope(EventType.PLAN_READY, envelope.task_id, plan)
                ]

            if self._is_research_followup(envelope.payload):
                try:
                    plan = build_research_followup_plan(
                        envelope.task_id,
                        envelope.payload,
                        observation,
                        adapter=self._research_adapter,
                    )
                except ResearchPlanningError as error:
                    return events + [make_envelope(
                        EventType.TASK_FAILED,
                        envelope.task_id,
                        TaskFailure(
                            error=StructuredError(
                                code=FailureCode.TARGET_NOT_FOUND,
                                message=str(error),
                            ),
                            summary="The visible company set could not be researched safely",
                        ),
                    )]
                self._plans[envelope.task_id] = plan
                self._verifications[envelope.task_id] = {}
                return events + [
                    make_envelope(EventType.PLAN_READY, envelope.task_id, plan)
                ]

        if observation is not None:
            failure = TaskFailure(
                error=StructuredError(
                    code=FailureCode.TARGET_NOT_FOUND,
                    message=(
                        "This visible workflow is not supported yet. VoiceOps did not "
                        "perform or verify any action."
                    ),
                ),
                summary="No supported workflow matched the grounded request",
            )
            return events + [
                make_envelope(EventType.TASK_FAILED, envelope.task_id, failure)
            ]

        if self._is_order_rescue(envelope.payload):
            task = compile_order_rescue_task(
                envelope.task_id,
                envelope.payload.transcript,
                self._order_rescue_fixture,
            )
            self._order_rescue_tasks[envelope.task_id] = task
            return [make_envelope(EventType.TASK_SPEC_READY, envelope.task_id, task)]

        # Retained only for the voice-only Phase 0 protocol fixture. Every
        # grounded app request above must route to a real workflow or fail
        # closed; it may never inherit this schema-only success path.
        plan = build_mock_plan(envelope.payload)
        completion_summary = (
            "Phase 0 mock exchange: request validated and mock plan produced"
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

    def _handle_order_rescue_correction(
        self, task_id: UUID, correction: VoiceRequest
    ) -> list[Envelope]:
        current = self._order_rescue_tasks.get(task_id)
        if current is None:
            return [make_envelope(
                EventType.TASK_FAILED,
                task_id,
                TaskFailure(
                    error=StructuredError(
                        code=FailureCode.TARGET_NOT_FOUND,
                        message="No active Order Rescue task matches this correction.",
                    ),
                    summary="The correction was not applied",
                ),
            )]
        if not self._is_customer_choice_correction(correction):
            return [make_envelope(
                EventType.TASK_FAILED,
                task_id,
                TaskFailure(
                    error=StructuredError(
                        code=FailureCode.AMBIGUOUS_STATE,
                        message=(
                            "The correction must explicitly defer the replacement, ask "
                            "replacement-or-refund preference, authorize the $20 credit, "
                            "and request the Sarah Slack escalation."
                        ),
                    ),
                    summary="The active plan was preserved without changes",
                ),
            )]

        try:
            patch = build_customer_choice_patch(current.version, correction.transcript)
            updated = apply_plan_patch(current, patch)
            approved = {
                action.id
                for action in updated.actions.values()
                if action.requires_confirmation and action.status == "pending"
            }
            execution = FixtureOrderRescueExecutor().execute(
                updated,
                self._order_rescue_fixture,
                approved_action_ids=approved,
            )
            report = verify_order_rescue(
                updated, self._order_rescue_fixture, execution
            )
        except (OrderRescuePlanningError, OrderRescueExecutionError) as error:
            return [make_envelope(
                EventType.TASK_FAILED,
                task_id,
                TaskFailure(
                    error=StructuredError(
                        code=FailureCode.AMBIGUOUS_STATE,
                        message=str(error),
                    ),
                    summary="The active plan was preserved without unsafe execution",
                ),
            )]

        self._order_rescue_tasks[task_id] = updated
        events = [
            make_envelope(
                EventType.PLAN_PATCH_APPLIED,
                task_id,
                updated.patch_history[-1],
            ),
            make_envelope(EventType.TASK_SPEC_READY, task_id, updated),
        ]
        events.extend(
            make_envelope(EventType.LEDGER_EVENT, task_id, item)
            for item in report.ledger
        )
        events.append(make_envelope(
            EventType.TASK_COMPLETED,
            task_id,
            TaskCompleted(
                state=report.state,
                summary=report.headline,
                verification=report.core_checks + report.negative_checks,
            ),
        ))
        self._cleanup(task_id)
        return events

    def _handle_action_finished(
        self, task_id: UUID, action: ActionResult
    ) -> list[Envelope]:
        plan = self._plans.get(task_id)
        if plan is None:
            return [self._protocol_failure(
                task_id, "action result arrived without a pending plan"
            )]
        step = next((item for item in plan.steps if item.id == action.step_id), None)
        if step is None:
            return [self._protocol_failure(
                task_id, f"action result referenced unknown step {action.step_id!r}"
            )]
        if action.status != "executed":
            error = action.error or StructuredError(
                code=(
                    FailureCode.CONSEQUENTIAL_STATE_UNCERTAIN
                    if action.status == "uncertain"
                    else FailureCode.NO_STATE_CHANGE
                ),
                message=(
                    action.state_change_hint
                    or f"{step.description} returned {action.status}"
                ),
            )
            self._cleanup(task_id)
            return [make_envelope(
                EventType.TASK_FAILED,
                task_id,
                TaskFailure(error=error, summary="The planned action did not complete"),
            )]
        actions = self._actions.setdefault(task_id, {})
        if action.step_id in actions:
            return [self._protocol_failure(
                task_id, f"duplicate action result for step {action.step_id!r}"
            )]
        actions[action.step_id] = action
        return []

    def _handle_verification_finished(
        self, task_id: UUID, verification: VerificationResult
    ) -> list[Envelope]:
        plan = self._plans.get(task_id)
        if plan is None:
            return [self._protocol_failure(
                task_id,
                "verification arrived before a pending action was executed",
            )]
        expected_predicates = {
            predicate.id: (step, predicate)
            for step in plan.steps
            for predicate in step.postconditions
        }
        expected = expected_predicates.get(verification.predicate_id)
        if expected is None:
            return [self._protocol_failure(
                task_id,
                f"verification referenced unknown predicate {verification.predicate_id!r}",
            )]
        owner_step, predicate = expected
        action = self._actions.get(task_id, {}).get(owner_step.id)
        if action is None or action.status != "executed":
            return [self._protocol_failure(
                task_id,
                f"verification for {verification.predicate_id!r} arrived before "
                f"step {owner_step.id!r} executed",
            )]
        if verification.expected != predicate.expected:
            return [self._protocol_failure(
                task_id,
                f"verification expectation drifted for {verification.predicate_id!r}",
            )]

        received = self._verifications.setdefault(task_id, {})
        received[verification.predicate_id] = verification
        if received.keys() != expected_predicates.keys():
            return []

        ordered = [received[predicate_id] for predicate_id in expected_predicates]
        passed_count = sum(result.passed for result in ordered)
        if passed_count == len(ordered):
            state = "succeeded"
            summary = (
                "Task completed and independently verified "
                f"({passed_count}/{len(ordered)} checks passed)"
            )
        elif passed_count:
            state = "partial"
            summary = (
                "The planned actions completed, but verification was incomplete "
                f"({passed_count}/{len(ordered)} checks passed)"
            )
        else:
            state = "failed"
            summary = "The planned actions could not be verified"
        completed = TaskCompleted(
            state=state,
            summary=summary,
            verification=ordered,
        )
        self._cleanup(task_id)
        return [make_envelope(EventType.TASK_COMPLETED, task_id, completed)]

    def _protocol_failure(self, task_id: UUID, message: str) -> Envelope:
        self._cleanup(task_id)
        return make_envelope(
            EventType.TASK_FAILED,
            task_id,
            TaskFailure(
                error=StructuredError(
                    code=FailureCode.INVALID_MESSAGE,
                    message=message,
                ),
                summary="The action protocol was rejected",
            ),
        )

    def _cleanup(self, task_id: UUID) -> None:
        self._observations.pop(task_id, None)
        self._plans.pop(task_id, None)
        self._actions.pop(task_id, None)
        self._verifications.pop(task_id, None)
        self._order_rescue_tasks.pop(task_id, None)

    @staticmethod
    def _is_screen_to_reminder(request: VoiceRequest) -> bool:
        transcript = request.transcript.casefold()
        return "remind" in transcript and "deadline" in transcript

    @staticmethod
    def _is_meeting_briefing(request: VoiceRequest) -> bool:
        transcript = request.transcript.casefold()
        return "meeting" in transcript and any(
            verb in transcript for verb in ("prepare", "brief", "prep")
        )

    @staticmethod
    def _is_research_followup(request: VoiceRequest) -> bool:
        transcript = request.transcript.casefold()
        return (
            "research" in transcript
            and "compan" in transcript
            and "follow" in transcript
        )

    @staticmethod
    def _is_order_rescue(
        request: VoiceRequest, observation: Observation | None = None
    ) -> bool:
        transcript = request.transcript.casefold()
        if "delayed order" not in transcript:
            return False
        if any(token in transcript for token in ("#1842", "order 1842", "maya")):
            return True
        if observation is None:
            return False
        visible = " ".join(
            value
            for element in observation.elements
            for value in (element.label, element.value)
            if value
        ).casefold()
        return "#1842" in visible and "maya" in visible

    @staticmethod
    def _is_customer_choice_correction(correction: VoiceRequest) -> bool:
        transcript = correction.transcript.casefold()
        deferring = any(
            phrase in transcript
            for phrase in (
                "don't create the replacement",
                "don’t create the replacement",
                "do not create the replacement",
            )
        )
        return (
            deferring
            and "refund" in transcript
            and "credit" in transcript
            and "sarah" in transcript
            and "slack" in transcript
        )


def handle_line(line: str) -> list[Envelope]:
    """Stateless compatibility helper used by Phase 0 contract tests."""
    return SidecarRuntime().handle_line(line)


def load_order_rescue_fixture(path: Path | None = None) -> OrderRescueFixture:
    configured = os.environ.get("VOICEOPS_ORDER_RESCUE_FIXTURE", "").strip()
    fixture_path = path or (
        Path(configured).expanduser()
        if configured
        else Path(__file__).resolve().parents[2]
        / "fixtures"
        / "order_rescue"
        / "golden_order_1842.json"
    )
    return OrderRescueFixture.model_validate_json(fixture_path.read_text())


def build_grounding_adapter() -> MultimodalGroundingAdapter:
    fallback = DeterministicMultimodalGroundingAdapter()
    api_key = os.environ.get("VOICEOPS_OPENAI_API_KEY", "").strip()
    if not api_key:
        return fallback
    model = os.environ.get("VOICEOPS_VLM_MODEL", "").strip() or "gpt-5.6-terra"
    return FallbackGroundingAdapter(
        primary=OpenAIMultimodalGroundingAdapter(api_key=api_key, model=model),
        fallback=fallback,
    )


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
