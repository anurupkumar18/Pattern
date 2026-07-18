import json
from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.schemas import PlanPatch, PlanPatchOperation
from voiceops_agent.workflows.order_rescue import (
    OrderRescueFixture,
    OrderRescuePlanningError,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "order_rescue"
    / "golden_order_1842.json"
)
TASK_ID = UUID("18420000-0000-4000-8000-000000000001")
INITIAL_REQUEST = (
    "Take care of this delayed order. Check whether it has moved recently. "
    "She looks like a valuable customer, so if it has been stuck for more than "
    "three days, prepare an expedited replacement, apologize to her, update the "
    "order, and remind me tomorrow to verify the new tracking."
)
CORRECTION = (
    "Actually, don't create the replacement yet. Ask whether she would prefer "
    "the replacement or a full refund. Give her a twenty-dollar store credit "
    "either way, and tag Sarah in Slack because this is the third delayed package "
    "from this carrier."
)


def fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def initial_task():
    return compile_order_rescue_task(TASK_ID, INITIAL_REQUEST, fixture())


def test_fixture_compiles_grounded_version_one_without_claiming_execution():
    task = initial_task()

    assert task.version == 1
    assert task.task_id == TASK_ID
    assert task.entities["order"] == "#1842"
    assert task.entities["customer"] == "Maya Chen"
    assert task.entities["deadline"] == "2026-07-24"
    assert task.actions["create_replacement"].status == "pending"
    assert task.actions["create_replacement"].requires_confirmation is True
    assert task.constraints["no_refund"] == "Do not issue a refund."
    assert task.patch_history == []
    assert task.provenance["tracking"] == ["carrier.tracking"]


def test_voice_correction_applies_minimal_version_two_patch_and_retains_constraints():
    version_one = initial_task()
    version_one_wire = version_one.model_dump(mode="json")
    version_two = apply_plan_patch(
        version_one,
        build_customer_choice_patch(version_one.version, CORRECTION),
    )

    assert version_two.version == 2
    assert "create_replacement" not in version_two.actions
    assert {
        "ask_customer_preference", "issue_store_credit", "notify_operations"
    }.issubset(version_two.actions)
    assert version_two.constraints["no_replacement_without_confirmation"].startswith(
        "Do not create a replacement"
    )
    for key in ("no_refund", "preserve_address", "shipping_approval", "customer_deadline"):
        assert version_two.constraints[key] == version_one.constraints[key]
    for key in ("review_tracking", "check_inventory", "add_shopify_note", "create_followup"):
        assert version_two.actions[key] == version_one.actions[key]
    assert "replacement_ready" not in version_two.completion_criteria
    assert version_two.completion_criteria["no_replacement"].startswith(
        "No replacement order exists"
    )

    history = version_two.patch_history[0]
    assert history.base_version == 1 and history.new_version == 2
    assert "actions.create_replacement" in history.removed
    assert "actions.ask_customer_preference" in history.added
    assert "constraints.no_refund" in history.preserved
    assert "completion_criteria.customer_contacted" in history.replaced
    assert version_one.model_dump(mode="json") == version_one_wire


def test_stale_patch_is_rejected_without_changing_current_task():
    version_one = initial_task()
    version_two = apply_plan_patch(
        version_one,
        build_customer_choice_patch(version_one.version, CORRECTION),
    )

    with pytest.raises(OrderRescuePlanningError, match="stale patch"):
        apply_plan_patch(
            version_two,
            build_customer_choice_patch(version_one.version, CORRECTION),
        )

    assert version_two.version == 2
    assert len(version_two.patch_history) == 1


def test_completed_action_history_cannot_be_removed_or_rewritten():
    current = initial_task()
    actions = dict(current.actions)
    actions["create_replacement"] = actions["create_replacement"].model_copy(
        update={"status": "completed"}
    )
    current = current.model_copy(update={"actions": actions})
    removal = PlanPatch(
        base_version=1,
        transcript="Remove it",
        operations=[PlanPatchOperation(
            operation="remove", target="actions.create_replacement"
        )],
    )

    with pytest.raises(OrderRescuePlanningError, match="cannot remove completed action"):
        apply_plan_patch(current, removal)


def test_action_patch_value_must_match_its_target_identity():
    current = initial_task()
    invalid = PlanPatch(
        base_version=1,
        transcript="Add another step",
        operations=[PlanPatchOperation(
            operation="add",
            target="actions.notify_operations",
            value={
                "id": "wrong_identity",
                "description": "Notify operations",
                "risk": "consequential",
                "requires_confirmation": True,
            },
        )],
    )

    with pytest.raises(OrderRescuePlanningError, match="does not match target key"):
        apply_plan_patch(current, invalid)


def test_fixture_is_json_round_trip_stable_for_deterministic_rehearsal():
    loaded = fixture()
    assert json.loads(loaded.model_dump_json()) == json.loads(FIXTURE_PATH.read_text())
