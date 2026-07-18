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
    TaskCompleted,
    TaskFailure,
    TaskPlan,
    VerificationResult,
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
        assert adapter._primary._model == "gpt-5.6-terra"

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
