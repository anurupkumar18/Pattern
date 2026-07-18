"""Tests for the conversation-layer authority: approval binding, affirmative
gating, and the typed tool router that is the S2S voice layer's only
side-effect path into the task machine."""

from datetime import UTC, datetime
from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.conversation import (
    ConversationError,
    ConversationToolRouter,
    approval_binding_for,
    classify_affirmative,
)
from voiceops_agent.schemas import (
    ActionResult,
    ConversationToolCall,
    EventType,
    VerificationResult,
    make_envelope,
)
from voiceops_agent.main import SidecarRuntime
from voiceops_agent.adapters.live import AdapterSelection
from voiceops_agent.workflows.order_rescue_adapters import FixtureOrderRescueAdapters
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


def compiled_and_patched_router() -> ConversationToolRouter:
    r = router()
    r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
    r.handle(TASK_ID, call("apply_patch", transcript=CORRECTION))
    return r


class TestApprovalAndExecution:
    def test_request_approval_returns_read_back_and_emits_ui_event(self):
        r = compiled_and_patched_router()
        events = r.handle(TASK_ID, call("request_approval"))
        assert [e.type for e in events] == [
            EventType.APPROVAL_REQUESTED,
            EventType.CONVERSATION_TOOL_RESULT,
        ]
        result = events[-1].payload
        assert result.status == "ok"
        assert len(result.result["binding_hash"]) == 64
        assert "confirm" in result.result["read_back"].casefold()
        assert result.result["action_ids"] == [
            "ask_customer_preference",
            "issue_store_credit",
            "notify_operations",
        ]

    def test_execute_without_confirmed_approval_is_rejected(self):
        r = compiled_and_patched_router()
        r.handle(TASK_ID, call("request_approval"))
        events = r.handle(TASK_ID, call("execute_plan"))
        assert events[-1].payload.status == "rejected"

    def test_mishear_cannot_authorize(self):
        r = compiled_and_patched_router()
        binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
        events = r.handle(TASK_ID, call(
            "confirm_approval",
            binding_hash=binding["binding_hash"],
            utterance="yeah maybe fine",
        ))
        assert events[-1].payload.status == "rejected"
        assert r.handle(TASK_ID, call("execute_plan"))[-1].payload.status == "rejected"


class NativeReminderLiveAdapters(FixtureOrderRescueAdapters):
    channel = "shopify.live+slack.live"

    def create_followup_reminder(self, title: str) -> None:
        raise AssertionError("live mode must defer the reminder to native EventKit")


def live_router() -> ConversationToolRouter:
    live = NativeReminderLiveAdapters(fixture())
    return ConversationToolRouter(
        fixture=fixture(),
        adapters_factory=lambda: AdapterSelection(
            adapters=live, reason="test live channel"),
    )


def approved_live_router() -> ConversationToolRouter:
    r = live_router()
    r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
    r.handle(TASK_ID, call("apply_patch", transcript=CORRECTION))
    binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
    r.handle(TASK_ID, call(
        "confirm_approval",
        binding_hash=binding["binding_hash"], utterance="yes",
    ))
    return r


class TestNativeReminderHandoff:
    def test_live_execute_emits_native_plan_and_defers_completion(self):
        events = approved_live_router().handle(TASK_ID, call("execute_plan"))
        types = [event.type for event in events]
        assert EventType.PLAN_READY in types
        assert EventType.TASK_COMPLETED not in types
        assert EventType.CONVERSATION_TOOL_RESULT not in types
        plan = next(event.payload for event in events if event.type is EventType.PLAN_READY)
        step = plan.steps[0]
        assert step.tool == "reminders.create"
        assert step.arguments["title"] == "Verify Order 1842 tracking"
        assert step.arguments["due_time"] == "09:00"
        assert len(step.postconditions) == 5

    def test_native_success_finishes_only_after_all_five_verifications(self):
        r = approved_live_router()
        events = r.handle(TASK_ID, call("execute_plan"))
        plan = next(event.payload for event in events if event.type is EventType.PLAN_READY)
        verifications = [
            VerificationResult(
                predicate_id=predicate.id,
                passed=True,
                method="eventkit_fetch_back",
                confidence=1,
                expected=predicate.expected,
                observed={"verified": True},
                evidence_ids=["eventkit:test"],
            )
            for predicate in plan.steps[0].postconditions
        ]
        completed = r.complete_native_reminder(TASK_ID, verifications)
        task = next(e.payload for e in completed if e.type is EventType.TASK_COMPLETED)
        assert task.state == "succeeded"
        assert task.summary == "ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED"
        assert completed[-1].type is EventType.CONVERSATION_TOOL_RESULT

    def test_failed_native_verification_is_partial_never_succeeded(self):
        r = approved_live_router()
        events = r.handle(TASK_ID, call("execute_plan"))
        plan = next(event.payload for event in events if event.type is EventType.PLAN_READY)
        verifications = [
            VerificationResult(
                predicate_id=predicate.id,
                passed=predicate.id != "reminder-visible",
                method="eventkit_fetch_back",
                confidence=1,
                expected=predicate.expected,
                observed={"verified": predicate.id != "reminder-visible"},
                evidence_ids=["eventkit:test"],
                failure_reason=(
                    None if predicate.id != "reminder-visible" else "not visible"
                ),
            )
            for predicate in plan.steps[0].postconditions
        ]
        completed = r.complete_native_reminder(TASK_ID, verifications)
        task = next(e.payload for e in completed if e.type is EventType.TASK_COMPLETED)
        assert task.state == "partial"
        assert "NOT VERIFIED" in task.summary

    def test_runtime_registers_plan_and_waits_for_native_action_and_checks(self):
        r = approved_live_router()
        runtime = SidecarRuntime(
            order_rescue_fixture=fixture(), conversation_router=r)
        execute = make_envelope(
            EventType.CONVERSATION_TOOL_CALL,
            TASK_ID,
            call("execute_plan"),
        )
        events = runtime.handle_line(execute.to_ndjson())
        plan = next(event.payload for event in events if event.type is EventType.PLAN_READY)
        step = plan.steps[0]
        now = datetime.now(UTC)
        action = ActionResult(
            step_id=step.id,
            status="executed",
            started_at=now,
            ended_at=now,
            channel="eventkit",
        )
        assert runtime.handle_line(make_envelope(
            EventType.ACTION_FINISHED, TASK_ID, action
        ).to_ndjson()) == []

        terminal = []
        for predicate in step.postconditions:
            terminal = runtime.handle_line(make_envelope(
                EventType.VERIFICATION_FINISHED,
                TASK_ID,
                VerificationResult(
                    predicate_id=predicate.id,
                    passed=True,
                    method="eventkit_fetch_back",
                    confidence=1,
                    expected=predicate.expected,
                    observed={"verified": True},
                    evidence_ids=["eventkit:test"],
                ),
            ).to_ndjson())
        assert any(event.type is EventType.TASK_COMPLETED for event in terminal)
        assert terminal[-1].type is EventType.CONVERSATION_TOOL_RESULT


class TestApprovalAndExecutionContinued:

    def test_corrupted_hash_is_rejected(self):
        r = compiled_and_patched_router()
        r.handle(TASK_ID, call("request_approval"))
        events = r.handle(TASK_ID, call(
            "confirm_approval", binding_hash="0" * 64, utterance="yes"
        ))
        assert events[-1].payload.status == "rejected"

    def test_patch_after_read_back_invalidates_the_binding(self):
        r = router()
        r.handle(TASK_ID, call("compile_task", transcript=INITIAL_REQUEST))
        stale = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
        r.handle(TASK_ID, call("apply_patch", transcript=CORRECTION))
        events = r.handle(TASK_ID, call(
            "confirm_approval",
            binding_hash=stale["binding_hash"],
            utterance="yes",
        ))
        assert events[-1].payload.status == "rejected"

    def test_confirmed_approval_allows_execution_and_verifier_owns_success(self):
        r = compiled_and_patched_router()
        binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
        confirm = r.handle(TASK_ID, call(
            "confirm_approval",
            binding_hash=binding["binding_hash"],
            utterance="Yes, go ahead.",
        ))
        assert confirm[-1].payload.status == "ok"
        events = r.handle(TASK_ID, call("execute_plan"))
        types = [e.type for e in events]
        assert types[-1] == EventType.CONVERSATION_TOOL_RESULT
        assert EventType.TASK_COMPLETED in types
        assert EventType.LEDGER_EVENT in types
        completed = next(e for e in events if e.type == EventType.TASK_COMPLETED)
        assert completed.payload.state == "succeeded"
        result = events[-1].payload
        assert result.result["checks_passed"] == 5
        assert result.result["confirmed_not_performed"] == [
            "no-refund-issued",
            "no-replacement-created",
        ]
        ledger = r.handle(TASK_ID, call("get_ledger"))[-1].payload
        assert ledger.result["events"]

    def test_execute_twice_is_rejected_not_duplicated(self):
        r = compiled_and_patched_router()
        binding = r.handle(TASK_ID, call("request_approval"))[-1].payload.result
        r.handle(TASK_ID, call(
            "confirm_approval",
            binding_hash=binding["binding_hash"],
            utterance="yes",
        ))
        first = r.handle(TASK_ID, call("execute_plan"))
        assert first[-1].payload.status == "ok"
        assert r.handle(TASK_ID, call("execute_plan"))[-1].payload.status == "rejected"


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
