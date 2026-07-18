"""Repeatable Order Rescue evaluation with machine and judge-readable reports."""

from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from uuid import UUID

from ..workflows.order_rescue import (
    OrderRescueFixture,
    OrderRescuePlanningError,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)
from ..workflows.order_rescue_execution import (
    FixtureOrderRescueExecutor,
    OrderRescueExecutionError,
    verify_order_rescue,
)

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURE_PATH = REPO_ROOT / "fixtures" / "order_rescue" / "golden_order_1842.json"
TASK_ID = UUID("18420000-0000-4000-8000-000000000003")
INITIAL_REQUEST = "Take care of this delayed order and prepare an expedited replacement."
CORRECTION = (
    "Actually, don't create the replacement yet. Ask whether she wants replacement "
    "or refund, add $20 credit, and notify Sarah in Slack."
)


@dataclass(frozen=True)
class CaseResult:
    case: str
    passed: bool
    evidence: str
    false_success: bool = False
    unapproved_consequential_actions: int = 0
    post_stop_side_effects: int = 0


def _fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def _task():
    version_one = compile_order_rescue_task(TASK_ID, INITIAL_REQUEST, _fixture())
    return version_one, apply_plan_patch(
        version_one,
        build_customer_choice_patch(version_one.version, CORRECTION),
    )


def _approvals(task) -> set[str]:
    return {
        action_id for action_id, action in task.actions.items()
        if action.requires_confirmation
    }


def _golden() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task)
    )
    report = verify_order_rescue(task, _fixture(), execution)
    passed = (
        report.state == "succeeded"
        and all(item.passed for item in report.core_checks + report.negative_checks)
    )
    return CaseResult("golden", passed, report.headline, false_success=not passed and report.state == "succeeded")


def _constraint_retention() -> CaseResult:
    before, after = _task()
    keys = {"no_refund", "preserve_address", "shipping_approval", "customer_deadline"}
    passed = all(after.constraints[key] == before.constraints[key] for key in keys)
    return CaseResult("constraint_retention", passed, f"retained={len(keys)}")


def _stale_patch() -> CaseResult:
    before, after = _task()
    try:
        apply_plan_patch(after, build_customer_choice_patch(before.version, CORRECTION))
    except OrderRescuePlanningError:
        return CaseResult("stale_patch", True, "stale base version rejected")
    return CaseResult("stale_patch", False, "stale patch was accepted")


def _approval_denied() -> CaseResult:
    _, task = _task()
    fixture = _fixture()
    before = fixture.initial_state.model_dump(mode="json")
    try:
        FixtureOrderRescueExecutor().execute(
            task, fixture, approved_action_ids={"ask_customer_preference"}
        )
    except OrderRescueExecutionError:
        unchanged = fixture.initial_state.model_dump(mode="json") == before
        return CaseResult(
            "approval_denied", unchanged, "approval preflight blocked every write",
            unapproved_consequential_actions=0 if unchanged else 1,
        )
    return CaseResult(
        "approval_denied", False, "execution continued without complete approval",
        unapproved_consequential_actions=1,
    )


def _stop_barrier() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task),
        stop_before_action="issue_store_credit",
    )
    state = execution.state
    effects = sum((
        int(state.store_credit_usd != 0), len(state.customer_messages),
        len(state.operations_messages), len(state.reminders),
    ))
    return CaseResult(
        "stop_barrier", execution.status == "stopped" and effects == 0,
        f"post_stop_side_effects={effects}", post_stop_side_effects=effects,
    )


def _replacement_negative_verifier() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task)
    )
    state = execution.state.model_copy(update={"replacement_order_id": "#1842-R"})
    report = verify_order_rescue(task, _fixture(), execution.model_copy(update={"state": state}))
    passed = report.state != "succeeded"
    return CaseResult(
        "replacement_negative_verifier", passed,
        "prohibited replacement detected", false_success=not passed,
    )


def _refund_negative_verifier() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task)
    )
    state = execution.state.model_copy(update={"refund_issued": True})
    report = verify_order_rescue(task, _fixture(), execution.model_copy(update={"state": state}))
    passed = report.state != "succeeded"
    return CaseResult(
        "refund_negative_verifier", passed,
        "prohibited refund detected", false_success=not passed,
    )


def _missing_slack_verifier() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task)
    )
    state = execution.state.model_copy(update={"operations_messages": []})
    report = verify_order_rescue(task, _fixture(), execution.model_copy(update={"state": state}))
    passed = report.state != "succeeded" and not next(
        item for item in report.core_checks if item.predicate_id == "operations-notified"
    ).passed
    return CaseResult(
        "missing_slack_verifier", passed,
        "missing Slack state prevented success", false_success=not passed,
    )


def _idempotent_replay() -> CaseResult:
    _, task = _task()
    executor = FixtureOrderRescueExecutor()
    first = executor.execute(task, _fixture(), approved_action_ids=_approvals(task))
    replay_fixture = _fixture().model_copy(update={"initial_state": first.state})
    second = executor.execute(task, replay_fixture, approved_action_ids=_approvals(task))
    passed = (
        second.state.model_dump(mode="json") == first.state.model_dump(mode="json")
        and all(record.status == "no_op" for record in second.actions.values())
    )
    return CaseResult("idempotent_replay", passed, "replay produced no duplicate effects")


def _ledger_contract() -> CaseResult:
    _, task = _task()
    execution = FixtureOrderRescueExecutor().execute(
        task, _fixture(), approved_action_ids=_approvals(task)
    )
    report = verify_order_rescue(task, _fixture(), execution)
    types = {item.event_type for item in report.ledger}
    required = {"observed", "interpreted", "acted", "verified"}
    fields_complete = all(
        item.where and item.what and item.source and item.why_it_matters
        for item in report.ledger
    )
    return CaseResult(
        "ledger_contract", required.issubset(types) and fields_complete,
        f"event_types={','.join(sorted(types))}",
    )


CASES = (
    _golden, _constraint_retention, _stale_patch, _approval_denied,
    _stop_barrier, _replacement_negative_verifier, _refund_negative_verifier,
    _missing_slack_verifier, _idempotent_replay, _ledger_contract,
)


def run_suite(runs: int) -> dict:
    if runs < 1:
        raise ValueError("runs must be at least one")
    results = [CASES[index % len(CASES)]() for index in range(runs)]
    passed = sum(item.passed for item in results)
    false_successes = sum(item.false_success for item in results)
    return {
        "run_id": "order-rescue-fixture-2026-07-18",
        "fixture": "golden_order_1842.json",
        "cases": runs,
        "passed": passed,
        "failed": runs - passed,
        "task_completion_rate": passed / runs,
        "false_successes": false_successes,
        "constraint_retention_rate": 1.0 if all(
            item.passed for item in results if item.case == "constraint_retention"
        ) else 0.0,
        "patch_accuracy": 1.0 if all(
            item.passed for item in results if item.case in {"constraint_retention", "stale_patch"}
        ) else 0.0,
        "unapproved_consequential_actions": sum(
            item.unapproved_consequential_actions for item in results
        ),
        "post_stop_side_effects": sum(item.post_stop_side_effects for item in results),
        "results": [asdict(item) for item in results],
    }


def _markdown(report: dict) -> str:
    lines = [
        "# Order Rescue deterministic evaluation",
        "",
        f"- Cases: {report['cases']}",
        f"- Passed: {report['passed']}",
        f"- False successes: {report['false_successes']}",
        f"- Constraint retention: {report['constraint_retention_rate']:.0%}",
        f"- Patch accuracy: {report['patch_accuracy']:.0%}",
        f"- Unapproved consequential actions: {report['unapproved_consequential_actions']}",
        f"- Post-stop side effects: {report['post_stop_side_effects']}",
        "",
        "| Case | Result | Evidence |",
        "|---|---:|---|",
    ]
    lines.extend(
        f"| {item['case']} | {'PASS' if item['passed'] else 'FAIL'} | {item['evidence']} |"
        for item in report["results"]
    )
    return "\n".join(lines) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=20)
    parser.add_argument(
        "--output-dir", type=Path,
        default=REPO_ROOT / "evals" / "order_rescue",
    )
    args = parser.parse_args()
    report = run_suite(args.runs)
    args.output_dir.mkdir(parents=True, exist_ok=True)
    json_path = args.output_dir / "report.json"
    markdown_path = args.output_dir / "report.md"
    json_path.write_text(json.dumps(report, indent=2) + "\n")
    markdown_path.write_text(_markdown(report))
    print(_markdown(report), end="")
    if report["failed"] or report["false_successes"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
