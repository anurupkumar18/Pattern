"""Tests for the conversation-layer authority: approval binding, affirmative
gating, and the typed tool router that is the S2S voice layer's only
side-effect path into the task machine."""

from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.conversation import (
    ConversationError,
    ConversationToolRouter,
    approval_binding_for,
    classify_affirmative,
)
from voiceops_agent.schemas import ConversationToolCall, EventType
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


def router() -> ConversationToolRouter:
    return ConversationToolRouter(fixture=fixture())


def call(tool: str, **arguments) -> ConversationToolCall:
    return ConversationToolCall(
        call_id=f"call_{tool}", tool=tool, arguments=arguments
    )


class TestRouterCompileAndPatch:
    def test_compile_task_emits_spec_and_ok_result(self):
        events = router().handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
        assert [e.type for e in events] == [
            EventType.TASK_SPEC_READY,
            EventType.CONVERSATION_TOOL_RESULT,
        ]
        result = events[-1].payload
        assert result.status == "ok"
        assert result.result["version"] == 1
        assert "1842" in result.result["objective"]
        assert result.result["speech_summary"]

    def test_apply_patch_emits_diff_and_preserves_task_id(self):
        r = router()
        r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
        events = r.handle(TASK_ID, call("apply_patch", transcript=CORRECTION))
        assert [e.type for e in events] == [
            EventType.PLAN_PATCH_APPLIED,
            EventType.TASK_SPEC_READY,
            EventType.CONVERSATION_TOOL_RESULT,
        ]
        assert all(e.task_id == TASK_ID for e in events)
        result = events[-1].payload
        assert result.status == "ok"
        assert result.result["new_version"] == 2
        assert "actions.create_replacement" in result.result["removed"]

    def test_apply_patch_without_task_is_rejected_not_crashed(self):
        events = router().handle(TASK_ID, call("apply_patch", transcript="whatever"))
        assert events[-1].type == EventType.CONVERSATION_TOOL_RESULT
        assert events[-1].payload.status == "rejected"
        assert events[-1].payload.error is not None

    def test_get_task_state_reports_version_and_constraints(self):
        r = router()
        r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
        events = r.handle(TASK_ID, call("get_task_state"))
        result = events[-1].payload
        assert result.status == "ok"
        assert result.result["version"] == 1
        assert "no_refund" in result.result["constraints"]
        assert result.result["completed"] is False

    def test_missing_required_argument_is_rejected(self):
        events = router().handle(TASK_ID, call("compile_task"))
        assert events[-1].payload.status == "rejected"

    def test_get_ledger_is_empty_before_execution(self):
        r = router()
        r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
        events = r.handle(TASK_ID, call("get_ledger"))
        assert events[-1].payload.status == "ok"
        assert events[-1].payload.result["events"] == []


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
