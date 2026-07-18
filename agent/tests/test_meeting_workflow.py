from pathlib import Path
from uuid import UUID

from voiceops_agent.schemas import Observation, VoiceRequest
from voiceops_agent.workflows.meeting_briefing import build_meeting_briefing_plan


FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "calendar_next_meeting_observation.json"
)
TASK_ID = UUID("5d64db13-846f-4ca6-89ec-4cd7f4d9142c")


def test_meeting_briefing_plan_is_one_reversible_verified_note_write():
    observation = Observation.model_validate_json(FIXTURE.read_text())
    request = VoiceRequest(
        transcript="Prepare me for my next meeting using what's already open.",
        locale="en-US",
        confidence=1,
        segments=[],
    )

    plan = build_meeting_briefing_plan(TASK_ID, request, observation)

    assert len(plan.steps) == 1
    step = plan.steps[0]
    assert step.tool == "notes.create_meeting_brief"
    assert step.risk == "reversible_write"
    assert step.requires_confirmation is False
    assert step.max_attempts == 2
    assert step.arguments["task_marker"] == f"voiceops-task:{TASK_ID}"
    assert step.arguments["required_headings"] == [
        "Meeting",
        "Participants",
        "Context",
        "Open Questions",
        "Sources",
    ]
    assert "VoiceOps Product Review" in step.arguments["visible_context"]
    assert {predicate.id for predicate in step.postconditions} == {
        "meeting-selected",
        "brief-exists",
        "brief-headings",
        "brief-meeting-identity",
        "brief-visible",
    }
