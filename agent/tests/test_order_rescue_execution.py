from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.workflows.order_rescue import (
    OrderRescueFixture,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)
from voiceops_agent.workflows.order_rescue_execution import (
    FixtureOrderRescueExecutor,
    OrderRescueExecutionError,
    verify_order_rescue,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "order_rescue"
    / "golden_order_1842.json"
)
TASK_ID = UUID("18420000-0000-4000-8000-000000000002")
INITIAL_REQUEST = "Take care of this delayed order and prepare an expedited replacement."
CORRECTION = (
    "Actually, don't create the replacement yet. Ask whether she wants replacement "
    "or refund, add $20 credit, and notify Sarah in Slack."
)


def fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def corrected_task():
    version_one = compile_order_rescue_task(TASK_ID, INITIAL_REQUEST, fixture())
    return apply_plan_patch(
        version_one,
        build_customer_choice_patch(version_one.version, CORRECTION),
    )


def approvals(task) -> set[str]:
    return {
        action_id
        for action_id, action in task.actions.items()
        if action.requires_confirmation
    }


def test_corrected_plan_executes_and_independent_verifier_proves_positive_and_negative_state():
    task = corrected_task()
    execution = FixtureOrderRescueExecutor().execute(
        task, fixture(), approved_action_ids=approvals(task)
    )
    report = verify_order_rescue(task, fixture(), execution)

    assert execution.status == "completed"
    assert report.state == "succeeded"
    assert report.headline == "ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED"
    assert len(report.core_checks) == 5 and all(item.passed for item in report.core_checks)
    assert len(report.negative_checks) == 2 and all(
        item.passed for item in report.negative_checks
    )
    assert execution.state.refund_issued is False
    assert execution.state.replacement_order_id is None
    assert execution.state.store_credit_usd == 20
    assert {event.event_type for event in report.ledger} == {
        "observed", "interpreted", "acted", "verified"
    }
    assert [event.sequence for event in report.ledger] == list(
        range(1, len(report.ledger) + 1)
    )


def test_missing_approval_fails_before_any_write():
    task = corrected_task()
    original = fixture()
    original_state = original.initial_state.model_dump(mode="json")

    with pytest.raises(OrderRescueExecutionError, match="approval required before any write"):
        FixtureOrderRescueExecutor().execute(
            task, original, approved_action_ids={"ask_customer_preference"}
        )

    assert original.initial_state.model_dump(mode="json") == original_state


def test_stop_barrier_prevents_every_later_consequential_action():
    task = corrected_task()
    execution = FixtureOrderRescueExecutor().execute(
        task,
        fixture(),
        approved_action_ids=approvals(task),
        stop_before_action="issue_store_credit",
    )

    assert execution.status == "stopped"
    assert execution.stopped_before_action == "issue_store_credit"
    assert execution.state.store_credit_usd == 0
    assert execution.state.customer_messages == []
    assert execution.state.operations_messages == []
    assert execution.state.reminders == []
    assert not {
        "issue_store_credit", "ask_customer_preference",
        "notify_operations", "create_followup",
    }.intersection(execution.state.applied_action_ids)
    assert execution.ledger[-1].event_type == "decided"
    assert "Emergency stop barrier" in (execution.ledger[-1].found or "")


def test_idempotency_keys_make_a_full_replay_a_no_op():
    task = corrected_task()
    executor = FixtureOrderRescueExecutor()
    first = executor.execute(task, fixture(), approved_action_ids=approvals(task))
    replay_fixture = fixture().model_copy(update={"initial_state": first.state})

    replay = executor.execute(
        task, replay_fixture, approved_action_ids=approvals(task)
    )

    assert replay.status == "completed"
    assert replay.state.model_dump(mode="json") == first.state.model_dump(mode="json")
    assert replay.actions and all(record.status == "no_op" for record in replay.actions.values())
    assert len(replay.state.customer_messages) == 1
    assert len(replay.state.operations_messages) == 1
    assert len(replay.state.reminders) == 1


def test_verifier_detects_prohibited_replacement_and_never_reports_false_success():
    task = corrected_task()
    execution = FixtureOrderRescueExecutor().execute(
        task, fixture(), approved_action_ids=approvals(task)
    )
    tampered_state = execution.state.model_copy(
        update={"replacement_order_id": "#1842-R"}
    )
    tampered = execution.model_copy(update={"state": tampered_state})

    report = verify_order_rescue(task, fixture(), tampered)

    assert report.state != "succeeded"
    assert report.headline == "ORDER RESCUE NOT VERIFIED — 5/5 CHECKS PASSED"
    replacement_check = next(
        item for item in report.negative_checks
        if item.predicate_id == "no-replacement-created"
    )
    assert replacement_check.passed is False
    assert replacement_check.observed["replacement_order_id"] == "#1842-R"
