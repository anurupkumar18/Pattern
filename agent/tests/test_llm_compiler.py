"""Live LLM task compiler: strict schema validation, locally-owned identities,
and deterministic fallback that is always labeled and never silent."""

import json
from pathlib import Path
from uuid import UUID

import pytest

from voiceops_agent.llm_compiler import (
    DeterministicOrderRescueCompiler,
    FallbackOrderRescueCompiler,
    LiveOrderRescueCompiler,
    LLMCompilerError,
)
from voiceops_agent.workflows.order_rescue import (
    OrderRescueFixture,
    apply_plan_patch,
    compile_order_rescue_task,
)

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "order_rescue"
    / "golden_order_1842.json"
)
TASK_ID = UUID("18420000-0000-4000-8000-000000000010")
TRANSCRIPT = "Take care of this delayed order for Maya before Friday."


def fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def responses_reply(text: str):
    payload = {
        "output": [
            {
                "type": "message",
                "content": [{"type": "output_text", "text": text}],
            }
        ]
    }
    return 200, json.dumps(payload).encode()


VALID_COMPILE = {
    "objective": "Resolve delayed order #1842 for Maya Chen before Friday.",
    "evidence_to_collect": ["Latest carrier scan", "Replacement inventory"],
    "actions": [
        {
            "id": "review_tracking",
            "description": "Review the carrier timeline",
            "risk": "read",
            "requires_confirmation": False,
        },
        {
            "id": "create_replacement",
            "description": "Create an expedited replacement after approval",
            "risk": "consequential",
            "requires_confirmation": True,
        },
    ],
    "constraints": [
        {"key": "no_refund", "value": "Do not issue a refund."},
        {"key": "customer_deadline", "value": "Deliver before Friday."},
    ],
    "completion_criteria": [
        {"key": "tracking_reviewed", "value": "Carrier movement recorded."},
    ],
}

VALID_PATCH = {
    "operations": [
        {
            "operation": "remove",
            "target": "actions.create_replacement",
            "string_value": None,
            "action_value": None,
        },
        {
            "operation": "add",
            "target": "actions.issue_store_credit",
            "string_value": None,
            "action_value": {
                "id": "issue_store_credit",
                "description": "Issue a $20 store credit after approval",
                "risk": "consequential",
                "requires_confirmation": True,
            },
        },
        {
            "operation": "add",
            "target": "constraints.no_replacement_yet",
            "string_value": "Do not create a replacement before the customer confirms.",
            "action_value": None,
        },
    ]
}


def transport_returning(text: str):
    def transport(request):
        return responses_reply(text)

    return transport


def failing_transport(request):
    return 500, b'{"error": {"message": "backend down"}}'


def live(transport):
    return LiveOrderRescueCompiler(
        api_key="sk-test", model="gpt-5.6-sol", transport=transport
    )


class TestLiveCompile:
    def test_valid_output_becomes_validated_spec_with_local_identities(self):
        compiler = live(transport_returning(json.dumps(VALID_COMPILE)))
        spec = compiler.compile(TASK_ID, TRANSCRIPT, fixture())
        assert spec.task_id == TASK_ID and spec.version == 1
        assert spec.raw_request == TRANSCRIPT
        assert spec.objective == VALID_COMPILE["objective"]
        assert spec.actions["create_replacement"].requires_confirmation is True
        assert spec.entities["order"] == "#1842"  # trusted fixture, not model output
        assert spec.provenance["compiler"] == ["llm:gpt-5.6-sol"]

    def test_consequential_without_confirmation_is_rejected(self):
        bad = json.loads(json.dumps(VALID_COMPILE))
        bad["actions"][1]["requires_confirmation"] = False
        with pytest.raises(LLMCompilerError):
            live(transport_returning(json.dumps(bad))).compile(
                TASK_ID, TRANSCRIPT, fixture()
            )

    def test_malformed_json_is_rejected(self):
        with pytest.raises(LLMCompilerError):
            live(transport_returning("not json")).compile(TASK_ID, TRANSCRIPT, fixture())

    def test_http_error_is_rejected(self):
        with pytest.raises(LLMCompilerError):
            live(failing_transport).compile(TASK_ID, TRANSCRIPT, fixture())


class TestLivePatch:
    def test_valid_operations_become_a_plan_patch_that_applies(self):
        base = compile_order_rescue_task(TASK_ID, TRANSCRIPT, fixture())
        compiler = live(transport_returning(json.dumps(VALID_PATCH)))
        patch = compiler.patch(base, "Actually, credit her twenty dollars instead.")
        assert patch.base_version == 1
        updated = apply_plan_patch(base, patch)
        assert updated.version == 2
        assert "issue_store_credit" in updated.actions
        assert "create_replacement" not in updated.actions

    def test_invalid_target_is_rejected(self):
        bad = {
            "operations": [{
                "operation": "add",
                "target": "actions.DROP TABLE",
                "string_value": "x",
                "action_value": None,
            }]
        }
        base = compile_order_rescue_task(TASK_ID, TRANSCRIPT, fixture())
        with pytest.raises(LLMCompilerError):
            live(transport_returning(json.dumps(bad))).patch(base, "whatever")


class TestFallback:
    def test_live_failure_falls_back_and_is_labeled(self):
        compiler = FallbackOrderRescueCompiler(
            primary=live(failing_transport),
            fallback=DeterministicOrderRescueCompiler(),
        )
        spec = compiler.compile(TASK_ID, TRANSCRIPT, fixture())
        assert spec.provenance["compiler"] == ["deterministic:fallback"]
        assert compiler.last_outcome == "deterministic:fallback"
        assert "1842" in spec.objective

    def test_live_success_is_labeled_live(self):
        compiler = FallbackOrderRescueCompiler(
            primary=live(transport_returning(json.dumps(VALID_COMPILE))),
            fallback=DeterministicOrderRescueCompiler(),
        )
        spec = compiler.compile(TASK_ID, TRANSCRIPT, fixture())
        assert spec.provenance["compiler"] == ["llm:gpt-5.6-sol"]
        assert compiler.last_outcome == "llm:gpt-5.6-sol"

    def test_deterministic_primary_is_labeled(self):
        spec = DeterministicOrderRescueCompiler().compile(TASK_ID, TRANSCRIPT, fixture())
        assert spec.provenance["compiler"] == ["deterministic"]
        patch = DeterministicOrderRescueCompiler().patch(spec, "correction text")
        assert patch.base_version == 1
