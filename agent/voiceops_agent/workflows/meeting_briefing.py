"""Deterministic plan for the EventKit-to-Notes Meeting Briefing hero."""

from __future__ import annotations

from uuid import UUID

from ..schemas import (
    Observation,
    Predicate,
    TaskPlan,
    TaskStep,
    VerifierSpec,
    VoiceRequest,
)


REQUIRED_HEADINGS = [
    "Meeting",
    "Participants",
    "Context",
    "Open Questions",
    "Sources",
]


def build_meeting_briefing_plan(
    task_id: UUID,
    request: VoiceRequest,
    observation: Observation,
) -> TaskPlan:
    marker = f"voiceops-task:{task_id}"
    visible_context = _visible_context(observation)
    predicates = [
        Predicate(
            id="meeting-selected",
            description="The next upcoming non-all-day event is selected through EventKit",
            expected={"selector": "next_upcoming_non_all_day", "within_days": 7},
        ),
        Predicate(
            id="brief-exists",
            description="The created note can be fetched back by task marker",
            expected={"task_marker": marker},
        ),
        Predicate(
            id="brief-headings",
            description="The note contains every required briefing section",
            expected={"headings": REQUIRED_HEADINGS},
        ),
        Predicate(
            id="brief-meeting-identity",
            description="The note contains the selected EventKit meeting title and time",
            expected={"matches_selected_event": True},
        ),
        Predicate(
            id="brief-visible",
            description="The created briefing note is visibly displayed in Notes",
            expected={"visible": True},
        ),
    ]
    step = TaskStep(
        id="create-meeting-brief",
        description="Find the next meeting and create a verified structured Apple Note",
        tool="notes.create_meeting_brief",
        arguments={
            "task_marker": marker,
            "required_headings": REQUIRED_HEADINGS,
            "visible_context": visible_context,
            "source_app": observation.active_app.name,
            "source_window": observation.window.title,
            "source_capture_id": str(observation.capture_id),
            "meeting_selector": "next_upcoming_non_all_day",
            "meeting_horizon_days": 7,
        },
        postconditions=predicates,
        risk="reversible_write",
        requires_confirmation=False,
        fallback_tools=[],
        max_attempts=2,
        timeout_seconds=45,
        verifier=VerifierSpec(
            kind="composite",
            description=(
                "Refetch the selected EventKit event and Apple Note, compare "
                "required content, and confirm the exact note is visible"
            ),
        ),
    )
    return TaskPlan(
        goal=request.transcript,
        summary=(
            "Select the next meeting, create one structured briefing note from "
            "EventKit plus the visible context, then verify and show it"
        ),
        steps=[step],
    )


def _visible_context(observation: Observation) -> str:
    lines = [
        f"Active source: {observation.active_app.name} — {observation.window.title}"
    ]
    for candidate in observation.elements[:32]:
        values = list(dict.fromkeys(
            value.strip()
            for value in (candidate.label, candidate.value)
            if value and value.strip()
        ))
        if values:
            lines.append(" — ".join(values)[:600])
    return "\n".join(lines)[:8000]
