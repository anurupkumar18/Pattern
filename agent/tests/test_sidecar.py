"""Contract tests for the Phase 0 mock sidecar.

The sidecar reads NDJSON envelopes on stdin and answers a voice.final request
with plan.ready followed by task.completed. Malformed input yields task.failed
with INVALID_MESSAGE — never a crash, never silence.
"""

import json
import subprocess
import sys
from pathlib import Path
from uuid import UUID

from voiceops_agent.main import handle_line
from voiceops_agent.schemas import (
    EventType,
    FailureCode,
    TaskCompleted,
    TaskFailure,
    TaskPlan,
    parse_envelope,
)

FIXTURE_PATH = Path(__file__).resolve().parents[2] / "fixtures" / "ipc" / "voice_final.json"


def fixture_line() -> str:
    return json.dumps(json.loads(FIXTURE_PATH.read_text()))


class TestHandleLine:
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

    def test_recovers_after_malformed_line(self):
        messages = self.run_sidecar("garbage\n" + fixture_line() + "\n")
        types = [m["type"] for m in messages]
        assert types == ["task.failed", "plan.ready", "task.completed"]
