from datetime import date
from pathlib import Path
from threading import Lock
from time import sleep
from uuid import UUID

import pytest

from voiceops_agent.schemas import Observation, VoiceRequest
from voiceops_agent.workflows.research_followup import (
    CompanyCandidate,
    ConcurrentWebResearchAdapter,
    ResearchPlanningError,
    build_research_followup_plan,
    validate_public_web_url,
)


FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "company_research_observation.json"
)
TASK_ID = UUID("6f66e633-b31f-410e-b692-0a9b9519db40")


class FixtureResearchAdapter:
    def research(self, candidates):
        return [
            {
                "name": candidate.name,
                "url": candidate.url,
                "source_title": f"{candidate.name} — official site",
                "summary": f"{candidate.name} builds reliable AI infrastructure.",
                "research_status": "fetched",
            }
            for candidate in candidates
        ]


def request():
    return VoiceRequest(
        transcript=(
            "Research the companies on this page, put the best three in Notes, "
            "and schedule follow-ups next week."
        ),
        locale="en-US",
        confidence=1,
        segments=[],
    )


def test_research_plan_bounds_candidates_selects_exactly_three_and_requires_approval():
    observation = Observation.model_validate_json(FIXTURE.read_text())

    plan = build_research_followup_plan(
        TASK_ID, request(), observation,
        adapter=FixtureResearchAdapter(),
        today=date(2026, 7, 18),
    )

    step = plan.steps[0]
    assert step.tool == "research.create_note_and_followups"
    assert step.risk == "reversible_write"
    assert step.requires_confirmation is True
    assert step.max_attempts == 1
    assert len(step.arguments["recommendations"]) == 3
    assert len(step.arguments["followups"]) == 3
    assert [item["due_date"] for item in step.arguments["followups"]] == [
        "2026-07-20", "2026-07-22", "2026-07-24",
    ]
    assert all(item["url"].startswith("https://") for item in step.arguments["recommendations"])
    assert {predicate.id for predicate in step.postconditions} == {
        "research-note-exists",
        "research-exactly-three",
        "research-citations",
        "research-followups",
        "research-visible",
    }


def test_private_and_non_http_research_targets_are_rejected():
    for url in (
        "file:///etc/passwd",
        "http://127.0.0.1/admin",
        "http://localhost:8080",
        "http://10.0.0.4/internal",
        "ftp://example.com/data",
    ):
        with pytest.raises(ResearchPlanningError):
            validate_public_web_url(url)


def test_research_adapter_executes_independent_fetches_concurrently():
    active = 0
    max_active = 0
    lock = Lock()

    def transport(candidate):
        nonlocal active, max_active
        with lock:
            active += 1
            max_active = max(max_active, active)
        sleep(0.03)
        with lock:
            active -= 1
        return {
            "name": candidate.name,
            "url": candidate.url,
            "source_title": candidate.name,
            "summary": "summary",
            "research_status": "fetched",
        }

    candidates = [
        CompanyCandidate(name=f"Company {index}", url=f"https://example.com/{index}")
        for index in range(4)
    ]
    results = ConcurrentWebResearchAdapter(transport=transport).research(candidates)

    assert len(results) == 4
    assert max_active > 1
