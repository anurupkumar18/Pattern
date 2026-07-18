"""Tests for the conversation-layer authority: approval binding, affirmative
gating, and the typed tool router that is the S2S voice layer's only
side-effect path into the task machine."""

from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.conversation import (
    ConversationError,
    approval_binding_for,
    classify_affirmative,
)
from voiceops_agent.workflows.order_rescue import (
    OrderRescueFixture,
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
TASK_ID = UUID("18420000-0000-4000-8000-000000000007")
INITIAL_REQUEST = "Take care of this delayed order"
CORRECTION = (
    "Actually, don't create the replacement yet. Ask whether she wants replacement "
    "or refund, add $20 credit, and notify Sarah in Slack."
)


def fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def version_one():
    return compile_order_rescue_task(TASK_ID, INITIAL_REQUEST, fixture())


def corrected_task():
    v1 = version_one()
    return apply_plan_patch(v1, build_customer_choice_patch(v1.version, CORRECTION))


class TestApprovalBinding:
    def test_binding_is_deterministic_and_names_every_consequential_action(self):
        task = corrected_task()
        a, b = approval_binding_for(task), approval_binding_for(task)
        assert a == b
        assert a.task_version == 2
        assert a.action_ids == [
            "ask_customer_preference",
            "issue_store_credit",
            "notify_operations",
        ]
        assert "confirm" in a.read_back.casefold()

    def test_binding_changes_when_the_action_set_changes(self):
        assert (
            approval_binding_for(corrected_task()).binding_hash
            != approval_binding_for(version_one()).binding_hash
        )

    def test_binding_requires_pending_consequential_actions(self):
        task = version_one()
        data = task.model_dump(mode="python")
        for action in data["actions"].values():
            if action["requires_confirmation"]:
                action["status"] = "cancelled"
        from voiceops_agent.schemas import VersionedTaskSpec

        neutered = VersionedTaskSpec.model_validate(data)
        with pytest.raises(ConversationError):
            approval_binding_for(neutered)


class TestAffirmativeGate:
    @pytest.mark.parametrize(
        "utterance",
        ["Yes", "yes, go ahead", "Confirmed.", "approve", "do it", "yes do it!"],
    )
    def test_clear_affirmatives_approve(self, utterance):
        assert classify_affirmative(utterance) is True

    @pytest.mark.parametrize(
        "utterance",
        [
            "yeah maybe",
            "yes but change the credit to fifty",
            "no",
            "hold on",
            "what will you send?",
            "",
            "don't",
            "yes and also refund her",
        ],
    )
    def test_anything_unclear_is_not_approval(self, utterance):
        assert classify_affirmative(utterance) is False
