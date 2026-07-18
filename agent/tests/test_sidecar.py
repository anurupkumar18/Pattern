"""Contract tests for the Phase 0 mock sidecar.

The sidecar reads NDJSON envelopes on stdin and answers a voice.final request
with plan.ready followed by task.completed. Malformed input yields task.failed
with INVALID_MESSAGE — never a crash, never silence.
"""

import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID, uuid4

from voiceops_agent.grounding import (
    DeterministicMultimodalGroundingAdapter,
    FallbackGroundingAdapter,
)
from voiceops_agent.main import SidecarRuntime, build_grounding_adapter, handle_line
from voiceops_agent.schemas import (
    ActionResult,
    AppRef,
    EventType,
    FailureCode,
    Observation,
    Predicate,
    TaskCompleted,
    TaskFailure,
    TaskPlan,
    TaskStep,
    VerificationResult,
    VerifierSpec,
    UIElementCandidate,
    VoiceRequest,
    WindowRef,
    make_envelope,
    parse_envelope,
)

FIXTURE_PATH = Path(__file__).resolve().parents[2] / "fixtures" / "ipc" / "voice_final.json"
SCREEN_FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "mail_deadline_observation.json"
)
RESEARCH_FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "company_research_observation.json"
)
ORDER_RESCUE_OBSERVATION_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "order_1842_observation.json"
)

ORDER_RESCUE_REQUEST = (
    "Take care of this delayed order. Check whether it has moved recently. "
    "She looks like a valuable customer, so if it has been stuck for more than "
    "three days, prepare an expedited replacement, apologize to her, update the "
    "order, and remind me tomorrow to verify the new tracking."
)
ORDER_RESCUE_CORRECTION = (
    "Actually, don't create the replacement yet. Ask whether she would prefer "
    "the replacement or a full refund. Give her a twenty-dollar store credit "
    "either way, and tag Sarah in Slack because this is the third delayed package "
    "from this carrier."
)


class FixtureResearchAdapter:
    def research(self, candidates):
        return [
            {
                "name": candidate.name,
                "url": candidate.url,
                "source_title": f"{candidate.name} official source",
                "summary": f"{candidate.name} has relevant AI infrastructure capabilities.",
                "research_status": "fetched",
            }
            for candidate in candidates
        ]


def fixture_line() -> str:
    return json.dumps(json.loads(FIXTURE_PATH.read_text()))


class TestHandleLine:
    def test_grounding_provider_defaults_to_offline_adapter(self, monkeypatch):
        monkeypatch.delenv("VOICEOPS_OPENAI_API_KEY", raising=False)

        assert isinstance(
            build_grounding_adapter(), DeterministicMultimodalGroundingAdapter
        )

    def test_grounding_provider_uses_live_adapter_with_blank_model_default(
        self, monkeypatch
    ):
        monkeypatch.setenv("VOICEOPS_OPENAI_API_KEY", "test-key")
        monkeypatch.setenv("VOICEOPS_VLM_MODEL", "  ")

        adapter = build_grounding_adapter()

        assert isinstance(adapter, FallbackGroundingAdapter)
        assert adapter._primary._model == "gpt-5.6-sol"

    def test_voice_final_yields_plan_then_completion(self):
        events = handle_line(fixture_line())
        assert [e.type for e in events] == [EventType.PLAN_READY, EventType.TASK_COMPLETED]

    def test_responses_echo_request_task_id(self):
        request_task_id = UUID(json.loads(fixture_line())["task_id"])
        events = handle_line(fixture_line())
        assert all(e.task_id == request_task_id for e in events)

    def test_plan_is_schema_valid_with_verified_step(self):
        plan = handle_line(fixture_line())[0].payload
        assert isinstance(plan, TaskPlan)
        step = plan.steps[0]
        assert step.postconditions, "every write step needs an outcome predicate"
        assert step.verifier.kind == "structured"

    def test_completion_succeeds_only_with_passing_verification(self):
        completed = handle_line(fixture_line())[1].payload
        assert isinstance(completed, TaskCompleted)
        assert completed.state == "succeeded"
        assert completed.verification and all(v.passed for v in completed.verification)

    def test_invalid_json_yields_task_failed(self):
        events = handle_line("{this is not json")
        assert [e.type for e in events] == [EventType.TASK_FAILED]
        failure = events[0].payload
        assert isinstance(failure, TaskFailure)
        assert failure.error.code == FailureCode.INVALID_MESSAGE

    def test_schema_invalid_message_echoes_task_id_in_failure(self):
        message = json.loads(fixture_line())
        message["type"] = "voice.telepathy"
        events = handle_line(json.dumps(message))
        assert events[0].type == EventType.TASK_FAILED
        assert events[0].task_id == UUID(message["task_id"])

    def test_unhandled_event_types_are_ignored(self):
        cancelled = json.loads(fixture_line())
        cancelled["type"] = "task.cancelled"
        cancelled["payload"] = {"reason": "user pressed escape"}
        assert handle_line(json.dumps(cancelled)) == []

    def test_observation_then_voice_yields_grounding_before_plan(self):
        runtime = SidecarRuntime()
        voice = parse_envelope(fixture_line())
        observation = Observation.model_validate_json(SCREEN_FIXTURE_PATH.read_text())
        observation_envelope = make_envelope(
            EventType.OBSERVATION_READY, voice.task_id, observation
        )

        assert runtime.handle_line(observation_envelope.to_ndjson()) == []
        events = runtime.handle_line(fixture_line())

        assert [event.type for event in events] == [
            EventType.GROUNDING_READY,
            EventType.PLAN_READY,
        ]
        assert events[0].payload.references[0].phrase == "this email"

    def test_reminder_cannot_complete_until_action_and_all_verifiers_finish(self):
        runtime = SidecarRuntime()
        voice = parse_envelope(fixture_line())
        observation = Observation.model_validate_json(SCREEN_FIXTURE_PATH.read_text())
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, voice.task_id, observation
        ).to_ndjson())
        planned = runtime.handle_line(fixture_line())
        plan = planned[-1].payload
        step = plan.steps[0]

        action = ActionResult(
            step_id=step.id,
            status="executed",
            started_at=datetime.now(UTC),
            ended_at=datetime.now(UTC),
            channel="eventkit",
            raw_result={"calendar_item_id": "created-id"},
        )
        assert runtime.handle_line(make_envelope(
            EventType.ACTION_FINISHED, voice.task_id, action
        ).to_ndjson()) == []

        emitted = []
        for predicate in step.postconditions:
            verification = VerificationResult(
                predicate_id=predicate.id,
                passed=True,
                method="eventkit_fetch_back",
                confidence=1,
                expected=predicate.expected,
                observed={"verified": True},
            )
            emitted.extend(runtime.handle_line(make_envelope(
                EventType.VERIFICATION_FINISHED, voice.task_id, verification
            ).to_ndjson()))

        assert [event.type for event in emitted] == [EventType.TASK_COMPLETED]
        assert emitted[0].payload.state == "succeeded"
        assert len(emitted[0].payload.verification) == len(step.postconditions)

    def test_failed_reminder_predicate_finishes_partial_not_success(self):
        runtime = SidecarRuntime()
        voice = parse_envelope(fixture_line())
        observation = Observation.model_validate_json(SCREEN_FIXTURE_PATH.read_text())
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, voice.task_id, observation
        ).to_ndjson())
        plan = runtime.handle_line(fixture_line())[-1].payload
        step = plan.steps[0]
        action = ActionResult(
            step_id=step.id, status="executed",
            started_at=datetime.now(UTC), ended_at=datetime.now(UTC),
            channel="eventkit", raw_result={"calendar_item_id": "created-id"},
        )
        runtime.handle_line(make_envelope(
            EventType.ACTION_FINISHED, voice.task_id, action
        ).to_ndjson())

        emitted = []
        for index, predicate in enumerate(step.postconditions):
            verification = VerificationResult(
                predicate_id=predicate.id,
                passed=index != len(step.postconditions) - 1,
                method="eventkit_fetch_back",
                confidence=1,
                expected=predicate.expected,
                observed={"verified": index != len(step.postconditions) - 1},
                failure_reason=(
                    None if index != len(step.postconditions) - 1
                    else "Reminder could not be shown"
                ),
            )
            emitted.extend(runtime.handle_line(make_envelope(
                EventType.VERIFICATION_FINISHED, voice.task_id, verification
            ).to_ndjson()))

        assert emitted[0].payload.state == "partial"
        assert not all(result.passed for result in emitted[0].payload.verification)

    def test_meeting_briefing_observation_yields_real_plan_without_mock_success(self):
        runtime = SidecarRuntime()
        task_id = uuid4()
        observation_path = (
            Path(__file__).resolve().parents[2]
            / "fixtures"
            / "screen"
            / "calendar_next_meeting_observation.json"
        )
        observation = Observation.model_validate_json(observation_path.read_text())
        voice = VoiceRequest(
            transcript="Prepare me for my next meeting using what's already open.",
            locale="en-US", confidence=1, segments=[],
        )
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, task_id, observation
        ).to_ndjson())

        events = runtime.handle_line(make_envelope(
            EventType.VOICE_FINAL, task_id, voice
        ).to_ndjson())

        assert [event.type for event in events] == [
            EventType.GROUNDING_READY, EventType.PLAN_READY,
        ]
        assert events[-1].payload.steps[0].tool == "notes.create_meeting_brief"

    def test_research_observation_yields_approval_gated_plan_without_mock_success(self):
        runtime = SidecarRuntime(research_adapter=FixtureResearchAdapter())
        task_id = uuid4()
        observation = Observation.model_validate_json(RESEARCH_FIXTURE_PATH.read_text())
        voice = VoiceRequest(
            transcript=(
                "Research the companies on this page, put the best three in Notes, "
                "and schedule follow-ups next week."
            ),
            locale="en-US", confidence=1, segments=[],
        )
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, task_id, observation
        ).to_ndjson())

        events = runtime.handle_line(make_envelope(
            EventType.VOICE_FINAL, task_id, voice
        ).to_ndjson())

        assert [event.type for event in events] == [
            EventType.GROUNDING_READY, EventType.PLAN_READY,
        ]
        step = events[-1].payload.steps[0]
        assert step.tool == "research.create_note_and_followups"
        assert step.requires_confirmation is True
        assert len(step.arguments["recommendations"]) == 3
        assert len(step.arguments["followups"]) == 3

    def test_unsupported_grounded_request_fails_closed_without_mock_success(self):
        runtime = SidecarRuntime()
        task_id = uuid4()
        observation = Observation.model_validate_json(SCREEN_FIXTURE_PATH.read_text())
        voice = VoiceRequest(
            transcript="Take care of this delayed high-value order.",
            locale="en-US", confidence=1, segments=[],
        )
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, task_id, observation
        ).to_ndjson())

        events = runtime.handle_line(make_envelope(
            EventType.VOICE_FINAL, task_id, voice
        ).to_ndjson())

        assert [event.type for event in events] == [
            EventType.GROUNDING_READY, EventType.TASK_FAILED,
        ]
        assert events[-1].payload.error.code == FailureCode.TARGET_NOT_FOUND
        assert "did not perform or verify" in events[-1].payload.error.message

    def test_order_rescue_correction_patches_executes_and_independently_verifies(self):
        runtime = SidecarRuntime()
        task_id = uuid4()
        observation = Observation.model_validate_json(
            ORDER_RESCUE_OBSERVATION_PATH.read_text()
        )
        initial = VoiceRequest(
            transcript=ORDER_RESCUE_REQUEST,
            locale="en-US", confidence=1, segments=[],
        )
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, task_id, observation
        ).to_ndjson())

        planned = runtime.handle_line(make_envelope(
            EventType.VOICE_FINAL, task_id, initial
        ).to_ndjson())

        assert [event.type for event in planned] == [
            EventType.GROUNDING_READY, EventType.TASK_SPEC_READY,
        ]
        task_v1 = planned[-1].payload
        assert task_v1.version == 1
        assert task_v1.entities["order"] == "#1842"
        assert "create_replacement" in task_v1.actions

        correction = VoiceRequest(
            transcript=ORDER_RESCUE_CORRECTION,
            locale="en-US", confidence=1, segments=[],
        )
        completed = runtime.handle_line(make_envelope(
            EventType.VOICE_CORRECTION, task_id, correction
        ).to_ndjson())

        assert completed[0].type is EventType.PLAN_PATCH_APPLIED
        assert completed[1].type is EventType.TASK_SPEC_READY
        assert all(
            event.type is EventType.LEDGER_EVENT for event in completed[2:-1]
        )
        assert completed[-1].type is EventType.TASK_COMPLETED
        task_v2 = completed[1].payload
        result = completed[-1].payload
        assert task_v2.version == 2
        assert "create_replacement" not in task_v2.actions
        assert {
            "ask_customer_preference", "issue_store_credit", "notify_operations"
        }.issubset(task_v2.actions)
        assert result.state == "succeeded"
        assert result.summary == "ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED"
        assert len(result.verification) == 7
        assert all(item.passed for item in result.verification)
        assert {item.predicate_id for item in result.verification[-2:]} == {
            "no-refund-issued", "no-replacement-created"
        }
        assert {
            event.payload.event_type for event in completed[2:-1]
        } == {"observed", "interpreted", "decided", "acted", "verified"}

    def test_order_rescue_rejects_incomplete_correction_without_mutating_plan(self):
        runtime = SidecarRuntime()
        task_id = uuid4()
        initial = VoiceRequest(
            transcript="Take care of delayed order #1842.",
            locale="en-US", confidence=1, segments=[],
        )
        runtime.handle_line(make_envelope(
            EventType.VOICE_FINAL, task_id, initial
        ).to_ndjson())
        incomplete = VoiceRequest(
            transcript="Actually, just send Sarah a note.",
            locale="en-US", confidence=1, segments=[],
        )

        rejected = runtime.handle_line(make_envelope(
            EventType.VOICE_CORRECTION, task_id, incomplete
        ).to_ndjson())

        assert [event.type for event in rejected] == [EventType.TASK_FAILED]
        assert rejected[0].payload.error.code is FailureCode.AMBIGUOUS_STATE
        assert runtime._order_rescue_tasks[task_id].version == 1

    def test_each_step_must_execute_before_its_predicate_can_verify(self):
        runtime = SidecarRuntime()
        task_id = uuid4()

        def step(index: int) -> TaskStep:
            predicate = Predicate(
                id=f"pred-{index}",
                description=f"Result {index} exists",
                expected={"result": index},
            )
            return TaskStep(
                id=f"step-{index}",
                description=f"Perform action {index}",
                tool=f"fixture.action_{index}",
                arguments={},
                postconditions=[predicate],
                risk="reversible_write",
                requires_confirmation=False,
                verifier=VerifierSpec(kind="structured", description="Fixture fetch-back"),
            )

        first, second = step(1), step(2)
        runtime._plans[task_id] = TaskPlan(
            goal="Perform two independently verified actions",
            summary="Two-step fixture",
            steps=[first, second],
        )
        runtime._verifications[task_id] = {}
        runtime.handle_line(make_envelope(
            EventType.ACTION_FINISHED,
            task_id,
            ActionResult(
                step_id=first.id, status="executed",
                started_at=datetime.now(UTC), ended_at=datetime.now(UTC),
                channel="fixture",
            ),
        ).to_ndjson())
        first_verification = VerificationResult(
            predicate_id=first.postconditions[0].id,
            passed=True,
            method="fixture_fetch_back",
            confidence=1,
            expected=first.postconditions[0].expected,
            observed={"result": 1},
        )
        assert runtime.handle_line(make_envelope(
            EventType.VERIFICATION_FINISHED, task_id, first_verification
        ).to_ndjson()) == []

        second_verification = VerificationResult(
            predicate_id=second.postconditions[0].id,
            passed=True,
            method="fixture_fetch_back",
            confidence=1,
            expected=second.postconditions[0].expected,
            observed={"result": 2},
        )
        events = runtime.handle_line(make_envelope(
            EventType.VERIFICATION_FINISHED, task_id, second_verification
        ).to_ndjson())

        assert [event.type for event in events] == [EventType.TASK_FAILED]
        assert events[0].payload.error.code == FailureCode.INVALID_MESSAGE
        assert "before step 'step-2' executed" in events[0].payload.error.message

    def test_grounding_adapter_failure_becomes_typed_task_failure(self):
        class BrokenAdapter:
            def resolve(self, grounding_input):
                raise RuntimeError("provider unavailable")

        runtime = SidecarRuntime(grounding_adapter=BrokenAdapter())
        voice = parse_envelope(fixture_line())
        observation = Observation(
            capture_id=uuid4(), timestamp=datetime.now(UTC),
            active_app=AppRef(bundle_id="com.apple.mail", name="Mail"),
            window=WindowRef(title="Email", bounds=(0, 0, 100, 100)),
            elements=[], screenshot_path="file:///tmp/capture.png",
        )
        runtime.handle_line(make_envelope(
            EventType.OBSERVATION_READY, voice.task_id, observation
        ).to_ndjson())

        events = runtime.handle_line(fixture_line())

        assert [event.type for event in events] == [EventType.TASK_FAILED]
        assert events[0].payload.error.code == FailureCode.MODEL_INVALID_OUTPUT


class TestSidecarProcess:
    def run_sidecar(self, stdin: str) -> list[dict]:
        proc = subprocess.run(
            [sys.executable, "-m", "voiceops_agent.main"],
            input=stdin,
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert proc.returncode == 0, proc.stderr
        return [json.loads(line) for line in proc.stdout.splitlines() if line.strip()]

    def test_full_exchange_over_stdio(self):
        messages = self.run_sidecar(fixture_line() + "\n")
        envelopes = [parse_envelope(m) for m in messages]
        assert [e.type for e in envelopes] == [EventType.PLAN_READY, EventType.TASK_COMPLETED]

    def test_screen_observation_exchange_over_stdio(self):
        voice = parse_envelope(fixture_line())
        observation = Observation.model_validate_json(SCREEN_FIXTURE_PATH.read_text())
        observed = make_envelope(
            EventType.OBSERVATION_READY, voice.task_id, observation
        ).to_ndjson()

        messages = self.run_sidecar(observed + fixture_line() + "\n")
        envelopes = [parse_envelope(message) for message in messages]

        assert [envelope.type for envelope in envelopes] == [
            EventType.GROUNDING_READY,
            EventType.PLAN_READY,
        ]
        assert [reference.phrase for reference in envelopes[0].payload.references] == [
            "this email",
            "the deadline",
        ]

    def test_recovers_after_malformed_line(self):
        messages = self.run_sidecar("garbage\n" + fixture_line() + "\n")
        types = [m["type"] for m in messages]
        assert types == ["task.failed", "plan.ready", "task.completed"]

    def test_order_rescue_exchange_over_stdio(self):
        task_id = uuid4()
        observation = Observation.model_validate_json(
            ORDER_RESCUE_OBSERVATION_PATH.read_text()
        )
        initial = VoiceRequest(
            transcript=ORDER_RESCUE_REQUEST,
            locale="en-US", confidence=1, segments=[],
        )
        correction = VoiceRequest(
            transcript=ORDER_RESCUE_CORRECTION,
            locale="en-US", confidence=1, segments=[],
        )
        stdin = "".join([
            make_envelope(EventType.OBSERVATION_READY, task_id, observation).to_ndjson(),
            make_envelope(EventType.VOICE_FINAL, task_id, initial).to_ndjson(),
            make_envelope(EventType.VOICE_CORRECTION, task_id, correction).to_ndjson(),
        ])

        messages = self.run_sidecar(stdin)
        types = [message["type"] for message in messages]

        assert types[:4] == [
            "grounding.ready", "task.spec_ready", "plan.patch_applied", "task.spec_ready"
        ]
        assert types[-1] == "task.completed"
        assert messages[-1]["payload"]["summary"] == (
            "ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED"
        )


class TestConversationDispatch:
    def test_conversation_tool_call_routes_to_router(self):
        from voiceops_agent.schemas import ConversationToolCall

        runtime = SidecarRuntime()
        envelope = make_envelope(
            EventType.CONVERSATION_TOOL_CALL,
            uuid4(),
            ConversationToolCall(
                call_id="c1",
                tool="compile_task",
                arguments={"transcript": "Take care of this delayed order"},
            ),
        )
        events = runtime.handle_line(envelope.to_ndjson())
        assert events[0].type == EventType.TASK_SPEC_READY
        assert events[-1].type == EventType.CONVERSATION_TOOL_RESULT
        assert events[-1].payload.status == "ok"

    def test_conversation_tool_call_with_bad_arguments_is_rejected(self):
        from voiceops_agent.schemas import ConversationToolCall

        runtime = SidecarRuntime()
        envelope = make_envelope(
            EventType.CONVERSATION_TOOL_CALL,
            uuid4(),
            ConversationToolCall(call_id="c1", tool="compile_task"),
        )
        events = runtime.handle_line(envelope.to_ndjson())
        assert len(events) == 1
        assert events[0].payload.status == "rejected"
