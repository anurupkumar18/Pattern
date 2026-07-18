"""Deterministic Screen-to-Reminder planning for the Phase 3 vertical slice."""

from __future__ import annotations

import re
from datetime import date, datetime, timedelta
from uuid import UUID

from ..schemas import (
    GroundingResult,
    Observation,
    Predicate,
    TaskPlan,
    TaskStep,
    VerifierSpec,
    VoiceRequest,
)


class ReminderPlanningError(ValueError):
    """Visible reminder facts are missing or ambiguous and need user input."""


_DATE_FORMATS = (
    "%B %d, %Y",
    "%b %d, %Y",
    "%Y-%m-%d",
    "%m/%d/%Y",
    "%m-%d-%Y",
)
_DATE_CANDIDATE = re.compile(
    r"(?:"
    r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|"
    r"Dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?"
    r"|\d{4}-\d{2}-\d{2}"
    r"|\d{1,2}[/-]\d{1,2}(?:[/-]\d{4})?"
    r")",
    re.IGNORECASE,
)


def parse_visible_deadline(value: str) -> date:
    """Parse only absolute, year-bearing dates; never guess a calendar year."""
    match = _DATE_CANDIDATE.search(value)
    if match is None:
        raise ReminderPlanningError(
            "I could not find a deadline date. What date should the reminder use?"
        )
    candidate = re.sub(r"(?<=\d)(?:st|nd|rd|th)", "", match.group(0), flags=re.I)
    if re.search(r"\b\d{4}\b", candidate) is None:
        raise ReminderPlanningError(
            "The visible deadline has no year. What year should I use?"
        )
    for format_string in _DATE_FORMATS:
        try:
            if format_string == "%Y-%m-%d":
                return date.fromisoformat(candidate)
            return datetime.strptime(
                candidate.replace("  ", " "), format_string
            ).date()
        except ValueError:
            continue
    raise ReminderPlanningError(
        f"I could not interpret the visible deadline {candidate!r}. What date should I use?"
    )


def build_reminder_plan(
    task_id: UUID,
    request: VoiceRequest,
    observation: Observation,
    grounding: GroundingResult,
) -> TaskPlan:
    """Turn grounded screen facts into one reversible, verifiable EventKit write."""
    deadline_reference = next(
        (
            reference
            for reference in grounding.references
            if "deadline" in reference.phrase.casefold()
        ),
        None,
    )
    if deadline_reference is None:
        raise ReminderPlanningError(
            "I could not ground the deadline on screen. Which date should I use?"
        )
    deadline = parse_visible_deadline(deadline_reference.resolved_text)
    due_date = deadline - timedelta(days=_days_before_deadline(request.transcript))

    email_reference = next(
        (
            reference
            for reference in grounding.references
            if reference.phrase.casefold() == "this email"
        ),
        None,
    )
    title = _bounded(
        (email_reference.resolved_text if email_reference else None)
        or observation.window.title
        or "Follow up on visible commitment",
        240,
    )
    marker = f"voiceops-task:{task_id}"
    source_heading = (
        f"Source: {observation.active_app.name} — {observation.window.title}"
    )
    visible_details = _visible_details(observation)
    notes = "\n".join(
        part
        for part in (
            source_heading,
            f"Deadline: {deadline_reference.resolved_text}",
            "Visible details:\n" + visible_details if visible_details else None,
            f"Requested: {request.transcript}",
            marker,
        )
        if part
    )

    predicates = [
        Predicate(
            id="reminder-exists",
            description="The committed reminder can be fetched back from EventKit",
            expected={"task_marker": marker},
        ),
        Predicate(
            id="reminder-title",
            description="The reminder title contains the visible commitment",
            expected={"contains": title},
        ),
        Predicate(
            id="reminder-due-date",
            description="The reminder is due two days before the visible deadline",
            expected={"local_date": due_date.isoformat()},
        ),
        Predicate(
            id="reminder-notes",
            description="The reminder notes retain source context and task provenance",
            expected={"contains": [source_heading, marker]},
        ),
        Predicate(
            id="reminder-visible",
            description="The created reminder is visibly displayed in Reminders",
            expected={"visible": True},
        ),
    ]
    step = TaskStep(
        id="create-screen-reminder",
        description=(
            f"Create and display {title!r} in Reminders, due {due_date.isoformat()}"
        ),
        tool="reminders.create",
        arguments={
            "title": title,
            "deadline_date": deadline.isoformat(),
            "due_date": due_date.isoformat(),
            "notes": notes,
            "task_marker": marker,
            "source_app": observation.active_app.name,
            "source_window": observation.window.title,
            "source_capture_id": str(observation.capture_id),
            "source_reference_provenance": deadline_reference.provenance,
        },
        postconditions=predicates,
        risk="reversible_write",
        requires_confirmation=False,
        fallback_tools=[],
        max_attempts=1,
        timeout_seconds=30,
        verifier=VerifierSpec(
            kind="composite",
            description=(
                "Fetch the committed reminder through EventKit, compare title, due "
                "date, and notes, then confirm the reminder is visible"
            ),
        ),
    )
    return TaskPlan(
        goal=request.transcript,
        summary=(
            f"Create one reminder for {title!r}, due "
            f"{due_date.strftime('%B')} {due_date.day}, {due_date.year}, "
            "then fetch it back and verify every field"
        ),
        steps=[step],
    )


def _days_before_deadline(transcript: str) -> int:
    normalized = transcript.casefold()
    match = re.search(r"\b(\d{1,2})\s+days?\s+before\b", normalized)
    if match:
        return int(match.group(1))
    words = {
        "one": 1,
        "two": 2,
        "three": 3,
        "four": 4,
        "five": 5,
        "six": 6,
        "seven": 7,
    }
    for word, number in words.items():
        if re.search(rf"\b{word}\s+days?\s+before\b", normalized):
            return number
    raise ReminderPlanningError(
        "How many days before the deadline should I remind you?"
    )


def _visible_details(observation: Observation) -> str:
    details: list[str] = []
    for candidate in observation.elements[:24]:
        parts = [part for part in (candidate.label, candidate.value) if part]
        if not parts:
            continue
        detail = _bounded(": ".join(dict.fromkeys(parts)), 500)
        if detail not in details:
            details.append(detail)
    return "\n".join(f"- {detail}" for detail in details)


def _bounded(value: str, limit: int) -> str:
    return value.strip()[:limit]
