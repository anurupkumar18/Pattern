"""Bounded parallel research and an approval-gated Notes/Reminders plan."""

from __future__ import annotations

import ipaddress
import socket
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, timedelta
from html.parser import HTMLParser
from typing import Callable, Protocol
from urllib.parse import urljoin, urlparse
from uuid import UUID

from ..schemas import (
    Observation,
    Predicate,
    TaskPlan,
    TaskStep,
    VerifierSpec,
    VoiceRequest,
)


class ResearchPlanningError(ValueError):
    pass


@dataclass(frozen=True)
class CompanyCandidate:
    name: str
    url: str


class CompanyResearchAdapter(Protocol):
    def research(self, candidates: list[CompanyCandidate]) -> list[dict]: ...


ResearchTransport = Callable[[CompanyCandidate], dict]


class ConcurrentWebResearchAdapter:
    """Runs at most four bounded, independent public-web reads in parallel."""

    def __init__(
        self,
        transport: ResearchTransport | None = None,
        max_workers: int = 4,
    ) -> None:
        self._transport = transport or self._fetch
        self._max_workers = max(1, min(max_workers, 4))

    def research(self, candidates: list[CompanyCandidate]) -> list[dict]:
        bounded = candidates[:8]
        with ThreadPoolExecutor(max_workers=self._max_workers) as executor:
            return list(executor.map(self._safe_research, bounded))

    def _safe_research(self, candidate: CompanyCandidate) -> dict:
        try:
            validate_public_web_url(candidate.url)
            return self._transport(candidate)
        except Exception as error:
            return {
                "name": candidate.name,
                "url": candidate.url,
                "source_title": candidate.name,
                "summary": (
                    "Live source unavailable; recommendation uses only the "
                    "user-invoked visible page context."
                ),
                "research_status": "unavailable",
                "warning": str(error)[:240],
            }

    def _fetch(self, candidate: CompanyCandidate) -> dict:
        opener = urllib.request.build_opener(_SafeRedirectHandler())
        request = urllib.request.Request(
            candidate.url,
            headers={"User-Agent": "VoiceOps/0.1 research-preview"},
        )
        with opener.open(request, timeout=5) as response:
            content_type = response.headers.get_content_type()
            if content_type not in ("text/html", "application/xhtml+xml"):
                raise ResearchPlanningError(
                    f"unsupported research content type: {content_type}"
                )
            # Read only the bounded prefix needed for title, metadata, and a
            # short visible summary. Large pages are never buffered in full.
            body = response.read(256_000)
            charset = response.headers.get_content_charset() or "utf-8"
            text = body.decode(charset, errors="replace")
        parser = _SummaryParser()
        parser.feed(text)
        summary = parser.description or parser.visible_summary or "No summary available."
        return {
            "name": candidate.name,
            "url": candidate.url,
            "source_title": parser.title or candidate.name,
            "summary": summary[:1200],
            "research_status": "fetched",
        }


class _SafeRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_public_web_url(urljoin(req.full_url, newurl))
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class _SummaryParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.title = ""
        self.description = ""
        self._in_title = False
        self._visible: list[str] = []
        self._hidden_depth = 0

    @property
    def visible_summary(self) -> str:
        return " ".join(" ".join(self._visible).split())[:1200]

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag == "title":
            self._in_title = True
        if tag in ("script", "style", "noscript"):
            self._hidden_depth += 1
        if tag == "meta":
            values = dict(attrs)
            if values.get("name", "").casefold() == "description":
                self.description = values.get("content", "")[:1200]

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        if tag in ("script", "style", "noscript") and self._hidden_depth:
            self._hidden_depth -= 1

    def handle_data(self, data: str) -> None:
        value = data.strip()
        if not value or self._hidden_depth:
            return
        if self._in_title:
            self.title += value
        elif sum(map(len, self._visible)) < 1600:
            self._visible.append(value)


def validate_public_web_url(value: str) -> str:
    parsed = urlparse(value)
    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        raise ResearchPlanningError("research URLs must use public HTTP or HTTPS")
    hostname = parsed.hostname.casefold().rstrip(".")
    if hostname == "localhost" or hostname.endswith(".localhost"):
        raise ResearchPlanningError("local research targets are blocked")
    try:
        addresses = {
            item[4][0]
            for item in socket.getaddrinfo(hostname, parsed.port or 443, type=socket.SOCK_STREAM)
        }
    except socket.gaierror as error:
        raise ResearchPlanningError(f"research host could not be resolved: {hostname}") from error
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ResearchPlanningError("private or non-global research targets are blocked")
    return value


def build_research_followup_plan(
    task_id: UUID,
    request: VoiceRequest,
    observation: Observation,
    *,
    adapter: CompanyResearchAdapter | None = None,
    today: date | None = None,
) -> TaskPlan:
    candidates = _company_candidates(observation)
    if len(candidates) < 3:
        raise ResearchPlanningError(
            "I found fewer than three public company links on the visible page."
        )
    findings = (adapter or ConcurrentWebResearchAdapter()).research(candidates)
    ranked = sorted(
        (dict(finding, score=_score(finding)) for finding in findings),
        key=lambda finding: (-finding["score"], finding["name"].casefold()),
    )[:3]
    if len(ranked) != 3:
        raise ResearchPlanningError("Three research recommendations are required.")

    for rank, finding in enumerate(ranked, start=1):
        finding["rank"] = rank
        finding["rationale"] = (
            f"Ranked #{rank} from the bounded source set: "
            f"{finding['summary'][:320]}"
        )
    schedule = _next_week_schedule(today or date.today())
    followups = [
        {
            "company": finding["name"],
            "url": finding["url"],
            "due_date": due.isoformat(),
            "title": f"Follow up with {finding['name']}",
        }
        for finding, due in zip(ranked, schedule, strict=True)
    ]
    marker = f"voiceops-task:{task_id}"
    predicates = [
        Predicate(
            id="research-note-exists",
            description="The comparison note can be fetched by task marker",
            expected={"task_marker": marker},
        ),
        Predicate(
            id="research-exactly-three",
            description="The comparison note lists exactly three recommendations",
            expected={"recommendation_count": 3},
        ),
        Predicate(
            id="research-citations",
            description="Every recommendation retains its public source URL and rationale",
            expected={"source_urls": [item["url"] for item in ranked]},
        ),
        Predicate(
            id="research-followups",
            description="Exactly three approved follow-up reminders exist next week",
            expected={
                "count": 3,
                "local_dates": [item["due_date"] for item in followups],
            },
        ),
        Predicate(
            id="research-visible",
            description="The comparison note is visibly displayed in Notes",
            expected={"visible": True},
        ),
    ]
    step = TaskStep(
        id="create-research-followups",
        description=(
            "Create one comparison note and three follow-up reminders on "
            + ", ".join(item["due_date"] for item in followups)
        ),
        tool="research.create_note_and_followups",
        arguments={
            "task_marker": marker,
            "recommendations": ranked,
            "followups": followups,
            "source_app": observation.active_app.name,
            "source_window": observation.window.title,
            "source_capture_id": str(observation.capture_id),
            "required_headings": ["Recommendations", "Comparison", "Sources"],
        },
        postconditions=predicates,
        risk="reversible_write",
        requires_confirmation=True,
        fallback_tools=[],
        max_attempts=1,
        timeout_seconds=60,
        verifier=VerifierSpec(
            kind="composite",
            description=(
                "Refetch the Notes comparison and all three EventKit reminders, "
                "then compare count, dates, sources, and visible state"
            ),
        ),
    )
    return TaskPlan(
        goal=request.transcript,
        summary=(
            "Review the top three researched companies and approve three proposed "
            "next-week follow-up dates before writing Notes or Reminders"
        ),
        steps=[step],
    )


def _company_candidates(observation: Observation) -> list[CompanyCandidate]:
    candidates: list[CompanyCandidate] = []
    seen: set[str] = set()
    for element in observation.elements:
        if not element.value or not element.label:
            continue
        parsed = urlparse(element.value)
        if parsed.scheme not in ("http", "https"):
            continue
        key = element.value.casefold()
        if key in seen:
            continue
        hostname = (parsed.hostname or "").casefold().rstrip(".")
        if (
            not hostname
            or hostname == "localhost"
            or hostname.endswith(".localhost")
            or _is_non_global_ip_literal(hostname)
        ):
            continue
        seen.add(key)
        candidates.append(CompanyCandidate(
            name=element.label.strip()[:160], url=element.value
        ))
        if len(candidates) == 8:
            break
    return candidates


def _is_non_global_ip_literal(hostname: str) -> bool:
    try:
        return not ipaddress.ip_address(hostname).is_global
    except ValueError:
        return False


def _score(finding: dict) -> int:
    score = 40
    if finding.get("research_status") == "fetched":
        score += 25
    if str(finding.get("url", "")).startswith("https://"):
        score += 10
    score += min(15, len(str(finding.get("summary", ""))) // 80)
    score += min(10, len(str(finding.get("source_title", ""))) // 20)
    return min(score, 100)


def _next_week_schedule(today: date) -> list[date]:
    days_until_monday = (7 - today.weekday()) % 7
    if days_until_monday == 0:
        days_until_monday = 7
    monday = today + timedelta(days=days_until_monday)
    return [monday, monday + timedelta(days=2), monday + timedelta(days=4)]
