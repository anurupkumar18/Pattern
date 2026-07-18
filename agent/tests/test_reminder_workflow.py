from datetime import date
from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.grounding import (
    DeterministicMultimodalGroundingAdapter,
    GroundingInput,
)
from voiceops_agent.schemas import Observation, VoiceRequest
from voiceops_agent.workflows.reminders import (
    ReminderPlanningError,
    build_reminder_plan,
    parse_visible_deadline,
)


FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "mail_deadline_observation.json"
)
TASK_ID = UUID("b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d")


def request(text: str) -> VoiceRequest:
    return VoiceRequest(transcript=text, locale="en-US", confidence=1, segments=[])


def fixture_input():
    observation = Observation.model_validate_json(FIXTURE.read_text())
    voice = request(
        "Using this email, remind me two days before the deadline "
        "and include the important details."
    )
    grounding = DeterministicMultimodalGroundingAdapter().resolve(
        GroundingInput(request=voice, observation=observation)
    )
    return voice, observation, grounding


def test_parse_visible_deadline_requires_an_unambiguous_year():
    assert parse_visible_deadline("July 31, 2026") == date(2026, 7, 31)
    assert parse_visible_deadline("2026-07-31") == date(2026, 7, 31)

    with pytest.raises(ReminderPlanningError, match="year"):
        parse_visible_deadline("July 31")


def test_build_reminder_plan_extracts_due_date_context_and_all_predicates():
    voice, observation, grounding = fixture_input()

    plan = build_reminder_plan(TASK_ID, voice, observation, grounding)

    assert len(plan.steps) == 1
    step = plan.steps[0]
    assert step.tool == "reminders.create"
    assert step.risk == "reversible_write"
    assert step.requires_confirmation is False
    assert step.arguments["title"] == "Hackathon deadline details"
    assert step.arguments["deadline_date"] == "2026-07-31"
    assert step.arguments["due_date"] == "2026-07-29"
    assert step.arguments["task_marker"] == f"voiceops-task:{TASK_ID}"
    assert "Mail — Hackathon details" in step.arguments["notes"]
    assert "July 31, 2026" in step.arguments["notes"]
    assert {predicate.id for predicate in step.postconditions} == {
        "reminder-exists",
        "reminder-title",
        "reminder-due-date",
        "reminder-notes",
        "reminder-visible",
    }


def test_build_reminder_plan_refuses_missing_grounded_deadline():
    voice, observation, grounding = fixture_input()
    grounding = grounding.model_copy(update={
        "references": [
            reference
            for reference in grounding.references
            if "deadline" not in reference.phrase
        ]
    })

    with pytest.raises(ReminderPlanningError, match="deadline"):
        build_reminder_plan(TASK_ID, voice, observation, grounding)
