"""Deterministic cross-runtime correctness evaluation and report generation.

This suite intentionally does not claim live microphone, TCC, UI, or network
latency. It exercises fixture-backed orchestration plus a compiled Swift probe;
permissioned live trials remain a separate manual acceptance gate.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from dataclasses import asdict, dataclass
from datetime import UTC, date, datetime
from pathlib import Path
from typing import Callable
from uuid import UUID, uuid4

from .grounding import DeterministicMultimodalGroundingAdapter, GroundingInput
from .main import SidecarRuntime
from .schemas import (
    ActionResult,
    EventType,
    FailureCode,
    Observation,
    StructuredError,
    VerificationResult,
    VoiceRequest,
    make_envelope,
)
from .workflows.meeting_briefing import build_meeting_briefing_plan
from .workflows.reminders import (
    ReminderPlanningError,
    build_reminder_plan,
    parse_visible_deadline,
)
from .workflows.research_followup import (
    ResearchPlanningError,
    build_research_followup_plan,
    validate_public_web_url,
)


@dataclass(frozen=True)
class CaseOutcome:
    passed: bool
    detail: str
    reported_success: bool = False
    required_predicates_passed: bool | None = None
    recovery_attempted: bool = False
    recovery_succeeded: bool = False
    duplicate_count: int = 0
    provenance_covered: bool = False


@dataclass(frozen=True)
class EvaluationResult:
    case_id: str
    workflow: str
    passed: bool
    detail: str
    reported_success: bool
    required_predicates_passed: bool | None
    false_success: bool
    recovery_attempted: bool
    recovery_succeeded: bool
    duplicate_count: int
    provenance_required: bool
    provenance_covered: bool


class FixtureResearchAdapter:
    def __init__(self, *, unavailable: bool = False) -> None:
        self.unavailable = unavailable
        self.candidate_count = 0

    def research(self, candidates):
        self.candidate_count = len(candidates)
        return [
            {
                "name": candidate.name,
                "url": candidate.url,
                "source_title": candidate.name,
                "summary": (
                    "Live source unavailable; recommendation uses only the "
                    "user-invoked visible page context."
                    if self.unavailable
                    else f"{candidate.name} builds reliable AI infrastructure."
                ),
                "research_status": "unavailable" if self.unavailable else "fetched",
                **({"warning": "fixture source unavailable"} if self.unavailable else {}),
            }
            for candidate in candidates
        ]


def _voice(transcript: str) -> VoiceRequest:
    return VoiceRequest(
        transcript=transcript, locale="en-US", confidence=1, segments=[]
    )


def _fixture(repo: Path, name: str) -> Observation:
    path = repo / "fixtures" / "screen" / name
    return Observation.model_validate_json(path.read_text())


def _reminder_context(repo: Path):
    task_id = UUID("b3e9a1c2-6d4f-4a8b-9c0d-1e2f3a4b5c6d")
    observation = _fixture(repo, "mail_deadline_observation.json")
    voice = _voice(
        "Using this email, remind me two days before the deadline and include "
        "the important details."
    )
    grounding = DeterministicMultimodalGroundingAdapter().resolve(
        GroundingInput(request=voice, observation=observation)
    )
    return task_id, voice, observation, grounding


def _planned_runtime(repo: Path):
    task_id, voice, observation, _ = _reminder_context(repo)
    runtime = SidecarRuntime()
    runtime.handle_line(make_envelope(
        EventType.OBSERVATION_READY, task_id, observation).to_ndjson())
    events = runtime.handle_line(make_envelope(
        EventType.VOICE_FINAL, task_id, voice).to_ndjson())
    return runtime, task_id, events[-1].payload.steps[0]


def _executed_action(step_id: str, *, status: str = "executed") -> ActionResult:
    error = None
    if status != "executed":
        error = StructuredError(
            code=FailureCode.NO_STATE_CHANGE,
            message="fixture action did not confirm a state change",
        )
    return ActionResult(
        step_id=step_id, status=status,
        started_at=datetime.now(UTC), ended_at=datetime.now(UTC),
        channel="fixture_eventkit", raw_result={"calendar_item_id": "fixture-id"},
        error=error,
    )


def _send_verifications(runtime, task_id, step, failed_index: int | None = None):
    emitted = []
    for index, predicate in enumerate(step.postconditions):
        passed = index != failed_index
        emitted.extend(runtime.handle_line(make_envelope(
            EventType.VERIFICATION_FINISHED,
            task_id,
            VerificationResult(
                predicate_id=predicate.id, passed=passed,
                method="fixture_fetch_back", confidence=1,
                expected=predicate.expected, observed={"verified": passed},
                evidence_ids=[f"fixture:{predicate.id}"],
                failure_reason=None if passed else "fixture predicate failed",
            ),
        ).to_ndjson()))
    return emitted


def _case_reminder_clear_plan(repo: Path) -> CaseOutcome:
    task_id, voice, observation, grounding = _reminder_context(repo)
    plan = build_reminder_plan(task_id, voice, observation, grounding)
    step = plan.steps[0]
    passed = (
        step.arguments["due_date"] == "2026-07-29"
        and len(step.postconditions) == 5
        and step.max_attempts == 2
        and step.arguments["source_reference_provenance"]["capture_id"]
            == str(observation.capture_id)
    )
    return CaseOutcome(
        passed, "Clear grounded deadline produced a five-predicate EventKit plan.",
        provenance_covered=passed)


def _case_reminder_ambiguous_year(_: Path) -> CaseOutcome:
    try:
        parse_visible_deadline("July 31")
    except ReminderPlanningError:
        return CaseOutcome(True, "A deadline without a year failed closed for clarification.")
    return CaseOutcome(False, "The ambiguous deadline was incorrectly accepted.")


def _case_grounding_deictic(repo: Path) -> CaseOutcome:
    _, _, observation, grounding = _reminder_context(repo)
    phrases = {item.phrase for item in grounding.references}
    covered = all(
        item.provenance.get("capture_id") == str(observation.capture_id)
        and item.provenance.get("candidate_id")
        for item in grounding.references
    )
    passed = phrases == {"this email", "the deadline"} and covered
    return CaseOutcome(
        passed, "Deictic email and deadline references retained native provenance.",
        provenance_covered=covered)


def _case_reminder_waits(repo: Path) -> CaseOutcome:
    runtime, task_id, step = _planned_runtime(repo)
    events = runtime.handle_line(make_envelope(
        EventType.ACTION_FINISHED, task_id, _executed_action(step.id)).to_ndjson())
    return CaseOutcome(
        events == [], "Executor completion emitted no task success before verification.")


def _case_reminder_all_pass(repo: Path) -> CaseOutcome:
    runtime, task_id, step = _planned_runtime(repo)
    runtime.handle_line(make_envelope(
        EventType.ACTION_FINISHED, task_id, _executed_action(step.id)).to_ndjson())
    emitted = _send_verifications(runtime, task_id, step)
    completed = emitted[-1].payload if emitted else None
    all_pass = bool(completed and all(item.passed for item in completed.verification))
    success = bool(completed and completed.state == "succeeded")
    return CaseOutcome(
        success and all_pass,
        "All five independent reminder predicates produced verified success.",
        reported_success=success, required_predicates_passed=all_pass,
        provenance_covered=all_pass)


def _case_reminder_failed_predicate(repo: Path) -> CaseOutcome:
    runtime, task_id, step = _planned_runtime(repo)
    runtime.handle_line(make_envelope(
        EventType.ACTION_FINISHED, task_id, _executed_action(step.id)).to_ndjson())
    emitted = _send_verifications(runtime, task_id, step, failed_index=4)
    completed = emitted[-1].payload if emitted else None
    reported_success = bool(completed and completed.state == "succeeded")
    predicates_passed = bool(
        completed and all(item.passed for item in completed.verification))
    passed = bool(completed and completed.state == "partial" and not reported_success)
    return CaseOutcome(
        passed, "A failed visible-state predicate returned partial, never success.",
        reported_success=reported_success,
        required_predicates_passed=predicates_passed)


def _case_action_failure(repo: Path) -> CaseOutcome:
    runtime, task_id, step = _planned_runtime(repo)
    events = runtime.handle_line(make_envelope(
        EventType.ACTION_FINISHED, task_id,
        _executed_action(step.id, status="failed")).to_ndjson())
    failed = bool(events and events[-1].type is EventType.TASK_FAILED)
    return CaseOutcome(
        failed, "A native action failure became task.failed with no success claim.",
        reported_success=False, required_predicates_passed=False)


def _case_meeting_plan(repo: Path) -> CaseOutcome:
    observation = _fixture(repo, "calendar_next_meeting_observation.json")
    plan = build_meeting_briefing_plan(
        uuid4(), _voice("Prepare me for my next meeting using what's already open."),
        observation)
    step = plan.steps[0]
    passed = (
        step.tool == "notes.create_meeting_brief"
        and step.max_attempts == 2
        and len(step.postconditions) == 5
        and step.arguments["source_capture_id"] == str(observation.capture_id)
    )
    return CaseOutcome(
        passed, "Meeting Briefing produced an idempotent five-predicate Notes plan.",
        provenance_covered=passed)


def _research_plan(repo: Path, adapter: FixtureResearchAdapter, observation=None):
    observation = observation or _fixture(repo, "company_research_observation.json")
    return build_research_followup_plan(
        UUID("6f66e633-b31f-410e-b692-0a9b9519db40"),
        _voice(
            "Research the companies on this page, put the best three in Notes, "
            "and schedule follow-ups next week."),
        observation, adapter=adapter, today=date(2026, 7, 18))


def _case_research_approval(repo: Path) -> CaseOutcome:
    plan = _research_plan(repo, FixtureResearchAdapter())
    step = plan.steps[0]
    passed = (
        step.requires_confirmation
        and len(step.arguments["recommendations"]) == 3
        and len(step.arguments["followups"]) == 3
        and step.max_attempts == 1
    )
    return CaseOutcome(
        passed, "Exactly three cited recommendations remained behind approval.",
        provenance_covered=all(item["url"] for item in step.arguments["recommendations"]))


def _case_research_bounded(repo: Path) -> CaseOutcome:
    observation = _fixture(repo, "company_research_observation.json")
    template = observation.elements[0]
    elements = [
        template.model_copy(update={
            "id": f"company-{index}", "label": f"Company {index}",
            "value": f"https://example.com/company-{index}",
        })
        for index in range(12)
    ]
    adapter = FixtureResearchAdapter()
    plan = _research_plan(
        repo, adapter, observation.model_copy(update={"elements": elements}))
    passed = adapter.candidate_count == 8 and len(
        plan.steps[0].arguments["recommendations"]) == 3
    return CaseOutcome(
        passed, "Twelve visible links were bounded to eight reads and three results.",
        provenance_covered=passed)


def _case_research_unavailable(repo: Path) -> CaseOutcome:
    plan = _research_plan(repo, FixtureResearchAdapter(unavailable=True))
    recommendations = plan.steps[0].arguments["recommendations"]
    labeled = all(
        item["research_status"] == "unavailable"
        and "unavailable" in item["summary"].casefold()
        for item in recommendations
    )
    return CaseOutcome(
        labeled, "Unavailable sources remained visibly labeled in every recommendation.",
        provenance_covered=all(item["url"] for item in recommendations))


def _case_research_private_blocked(_: Path) -> CaseOutcome:
    blocked = 0
    for url in ("http://127.0.0.1/admin", "http://10.0.0.4", "file:///etc/passwd"):
        try:
            validate_public_web_url(url)
        except ResearchPlanningError:
            blocked += 1
    return CaseOutcome(
        blocked == 3, "Loopback, private, and non-HTTP research targets were blocked.")


def _case_invalid_ipc(_: Path) -> CaseOutcome:
    events = SidecarRuntime().handle_line("{not-json")
    passed = bool(
        len(events) == 1
        and events[0].type is EventType.TASK_FAILED
        and events[0].payload.error.code is FailureCode.INVALID_MESSAGE
    )
    return CaseOutcome(passed, "Malformed IPC produced typed INVALID_MESSAGE failure.")


def _case_grounding_failure(repo: Path) -> CaseOutcome:
    class BrokenGrounder:
        def resolve(self, _):
            raise RuntimeError("fixture provider unavailable")

    task_id, voice, observation, _ = _reminder_context(repo)
    runtime = SidecarRuntime(grounding_adapter=BrokenGrounder())
    runtime.handle_line(make_envelope(
        EventType.OBSERVATION_READY, task_id, observation).to_ndjson())
    events = runtime.handle_line(make_envelope(
        EventType.VOICE_FINAL, task_id, voice).to_ndjson())
    passed = bool(
        events and events[-1].type is EventType.TASK_FAILED
        and events[-1].payload.error.code is FailureCode.MODEL_INVALID_OUTPUT
    )
    return CaseOutcome(passed, "Grounding provider failure became typed fail-closed output.")


def _case_orphan_verification(_: Path) -> CaseOutcome:
    task_id = uuid4()
    verification = VerificationResult(
        predicate_id="orphan", passed=True, method="fixture", confidence=1,
        expected={}, observed={})
    events = SidecarRuntime().handle_line(make_envelope(
        EventType.VERIFICATION_FINISHED, task_id, verification).to_ndjson())
    passed = bool(events and events[0].type is EventType.TASK_FAILED)
    return CaseOutcome(passed, "Verification without a pending plan was rejected.")


PYTHON_EVALUATORS: dict[str, Callable[[Path], CaseOutcome]] = {
    "reminder_clear_plan": _case_reminder_clear_plan,
    "reminder_ambiguous_year": _case_reminder_ambiguous_year,
    "grounding_deictic": _case_grounding_deictic,
    "reminder_waits": _case_reminder_waits,
    "reminder_all_pass": _case_reminder_all_pass,
    "reminder_failed_predicate": _case_reminder_failed_predicate,
    "action_failure": _case_action_failure,
    "meeting_plan": _case_meeting_plan,
    "research_approval": _case_research_approval,
    "research_bounded": _case_research_bounded,
    "research_unavailable": _case_research_unavailable,
    "research_private_blocked": _case_research_private_blocked,
    "invalid_ipc": _case_invalid_ipc,
    "grounding_failure": _case_grounding_failure,
    "orphan_verification": _case_orphan_verification,
}


def _native_probe(repo: Path) -> dict[str, dict]:
    process = subprocess.run(
        ["swift", "run", "-q", "--package-path", str(repo / "macos"),
         "voiceops-eval-probe"],
        cwd=repo, capture_output=True, text=True, timeout=120,
    )
    if process.returncode != 0:
        raise RuntimeError(f"native evaluation probe failed: {process.stderr[-1000:]}")
    results = [json.loads(line) for line in process.stdout.splitlines() if line.strip()]
    return {result["case_id"]: result for result in results}


def run_evaluation(
    repo: Path,
    *,
    run_id: str,
    native_results: dict[str, dict] | None = None,
) -> dict:
    catalog = json.loads((repo / "evals" / "cases.json").read_text())
    native_results = native_results if native_results is not None else _native_probe(repo)
    results: list[EvaluationResult] = []
    for case in catalog:
        if case["kind"] == "python":
            outcome = PYTHON_EVALUATORS[case["evaluator"]](repo)
        else:
            raw = native_results.get(case["evaluator"])
            if raw is None:
                outcome = CaseOutcome(False, "Native probe did not return this case.")
            else:
                outcome = CaseOutcome(
                    passed=bool(raw["passed"]), detail=str(raw["detail"]),
                    recovery_attempted=bool(raw["recovery_attempted"]),
                    recovery_succeeded=bool(raw["recovery_succeeded"]),
                    duplicate_count=int(raw["duplicate_count"]),
                )
        false_success = bool(
            outcome.reported_success
            and outcome.required_predicates_passed is not True)
        results.append(EvaluationResult(
            case_id=case["id"], workflow=case["workflow"],
            passed=outcome.passed and not false_success,
            detail=outcome.detail, reported_success=outcome.reported_success,
            required_predicates_passed=outcome.required_predicates_passed,
            false_success=false_success,
            recovery_attempted=outcome.recovery_attempted,
            recovery_succeeded=outcome.recovery_succeeded,
            duplicate_count=outcome.duplicate_count,
            provenance_required=bool(case["requires_provenance"]),
            provenance_covered=(
                outcome.provenance_covered if case["requires_provenance"] else True),
        ))

    passed = sum(item.passed for item in results)
    recovery_attempts = sum(item.recovery_attempted for item in results)
    recovery_successes = sum(item.recovery_succeeded for item in results)
    provenance_required = sum(item.provenance_required for item in results)
    provenance_covered = sum(
        item.provenance_required and item.provenance_covered for item in results)
    false_successes = sum(item.false_success for item in results)
    duplicate_count = sum(item.duplicate_count for item in results)
    case_pass_rate = passed / len(results) if results else 0
    recovery_rate = (
        recovery_successes / recovery_attempts if recovery_attempts else 1.0)
    provenance_rate = (
        provenance_covered / provenance_required if provenance_required else 1.0)
    gates = {
        "case_pass_rate_at_least_85_percent": case_pass_rate >= 0.85,
        "false_successes_zero": false_successes == 0,
        "duplicates_zero": duplicate_count == 0,
        "recovery_success_at_least_70_percent": recovery_rate >= 0.70,
        "provenance_coverage_100_percent": provenance_rate == 1.0,
    }
    return {
        "run_id": run_id,
        "scope": "deterministic_offline_cross_runtime_correctness",
        "status": "passed" if all(gates.values()) else "failed",
        "cases": len(results),
        "passed": passed,
        "failed": len(results) - passed,
        "case_pass_rate": case_pass_rate,
        "false_successes": false_successes,
        "duplicate_side_effects": duplicate_count,
        "recovery_attempts": recovery_attempts,
        "recovery_successes": recovery_successes,
        "recovery_success_rate": recovery_rate,
        "provenance_required_cases": provenance_required,
        "provenance_covered_cases": provenance_covered,
        "provenance_coverage_rate": provenance_rate,
        "median_task_latency_ms": None,
        "user_interruption_latency_ms": None,
        "gates": gates,
        "limitations": [
            "No live microphone, TCC permission, EventKit, Notes, Reminders, or network trial is performed.",
            "Latency targets require repeated permissioned runs on a dedicated macOS account.",
            "The native probe exercises recovery policy and duplicate guards, not CGEvent delivery by macOS.",
        ],
        "results": [asdict(item) for item in results],
    }


def render_markdown(report: dict) -> str:
    percent = lambda value: f"{value * 100:.1f}%"
    lines = [
        "# VoiceOps Deterministic Evaluation Report",
        "",
        f"**Run:** `{report['run_id']}`",
        "",
        f"**Status:** **{report['status'].upper()}**",
        "",
        f"**Scope:** `{report['scope']}`",
        "",
        "## Summary",
        "",
        "| Metric | Result |",
        "|---|---:|",
        f"| Case pass rate | {report['passed']}/{report['cases']} ({percent(report['case_pass_rate'])}) |",
        f"| False successes | {report['false_successes']} |",
        f"| Duplicate side effects | {report['duplicate_side_effects']} |",
        f"| Recovery success | {report['recovery_successes']}/{report['recovery_attempts']} ({percent(report['recovery_success_rate'])}) |",
        f"| Provenance coverage | {report['provenance_covered_cases']}/{report['provenance_required_cases']} ({percent(report['provenance_coverage_rate'])}) |",
        "| Live task latency | Not measured by this offline suite |",
        "",
        "## Cases",
        "",
        "| Case | Workflow | Result | Evidence |",
        "|---|---|---:|---|",
    ]
    for result in report["results"]:
        detail = result["detail"].replace("|", "\\|")
        lines.append(
            f"| `{result['case_id']}` | {result['workflow']} | "
            f"{'PASS' if result['passed'] else 'FAIL'} | {detail} |")
    lines.extend(["", "## Gates", ""])
    for name, passed in report["gates"].items():
        lines.append(f"- {'PASS' if passed else 'FAIL'} — `{name}`")
    lines.extend(["", "## Limitations", ""])
    lines.extend(f"- {item}" for item in report["limitations"])
    lines.extend([
        "",
        "This report is correctness evidence, not a claim of completed live acceptance testing.",
        "",
    ])
    return "\n".join(lines)


def write_report(report: dict, output_dir: Path) -> tuple[Path, Path]:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "latest.json"
    markdown_path = output_dir / "latest.md"
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    markdown_path.write_text(render_markdown(report))
    return json_path, markdown_path


def main() -> None:
    default_repo = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=default_repo)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--run-id", default="fixture-baseline-v1")
    args = parser.parse_args()
    repo = args.repo_root.resolve()
    output = (args.output_dir or repo / "evals" / "reports").resolve()
    report = run_evaluation(repo, run_id=args.run_id)
    json_path, markdown_path = write_report(report, output)
    print(
        f"evaluation: {report['passed']}/{report['cases']} passed; "
        f"false_successes={report['false_successes']}; status={report['status']}")
    print(json_path)
    print(markdown_path)
    if report["status"] != "passed":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
