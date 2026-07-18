"""Credential-gated adapter selection: live only when every credential exists
and both probes pass; anything else is the fixture channel with the reason
recorded. The live composition routes writes to the right channel and the
verifier fetches back through the same live surfaces."""

import json
from pathlib import Path
from uuid import UUID

from voiceops_agent.adapters.live import (
    AdapterSelection,
    LiveOrderRescueAdapters,
    build_order_rescue_adapters,
)
from voiceops_agent.conversation import ConversationToolRouter
from voiceops_agent.schemas import ConversationToolCall, EventType
from voiceops_agent.workflows.order_rescue import OrderRescueFixture

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "order_rescue"
    / "golden_order_1842.json"
)
TASK_ID = UUID("18420000-0000-4000-8000-000000000009")
FULL_ENV = {
    "VOICEOPS_SHOPIFY_SHOP": "voiceops-dev.myshopify.com",
    "VOICEOPS_SHOPIFY_TOKEN": "shpat_test",
    "VOICEOPS_SHOPIFY_ORDER_ID": "1842",
    "VOICEOPS_SLACK_BOT_TOKEN": "xoxb-test",
    "VOICEOPS_SLACK_CHANNEL_ID": "C0912ESCAL",
}


def fixture() -> OrderRescueFixture:
    return OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())


def ok_transport(request):
    return 200, json.dumps({"ok": True, "shop": {"name": "voiceops-dev"}}).encode()


def failing_transport(request):
    return 503, json.dumps({"ok": False, "errors": "down"}).encode()


class FakeShopifyChannel:
    channel = "shopify.live"

    def __init__(self):
        self.tags, self.notes = ["VIP"], []
        self.credit = 0

    def probe(self):
        pass

    def add_note_and_tag(self, note, tag):
        if tag not in self.tags:
            self.tags.append(tag)
        if note not in self.notes:
            self.notes.append(note)

    def issue_store_credit(self, amount_usd):
        self.credit = amount_usd

    def fetch_state(self):
        return {
            "tags": list(self.tags),
            "notes": list(self.notes),
            "store_credit_usd": self.credit,
            "refund_issued": False,
            "replacement_order_id": None,
        }


class FakeSlackChannel:
    channel = "slack.live"

    def __init__(self):
        self.messages = []

    def probe(self):
        pass

    def post_operations_message(self, message):
        if message not in self.messages:
            self.messages.append(message)

    def fetch_operations_messages(self):
        return list(self.messages)


def live_adapters() -> LiveOrderRescueAdapters:
    return LiveOrderRescueAdapters(FakeShopifyChannel(), FakeSlackChannel())


class TestSelection:
    def test_missing_credentials_select_fixture_with_reason(self):
        selection = build_order_rescue_adapters(fixture(), env={})
        assert selection.adapters.channel == "fixture"
        assert "credentials absent" in selection.reason

    def test_full_credentials_and_healthy_probes_select_live(self):
        selection = build_order_rescue_adapters(
            fixture(), env=FULL_ENV,
            shopify_transport=ok_transport, slack_transport=ok_transport,
        )
        assert selection.adapters.channel == "shopify.live+slack.live"
        assert "healthy" in selection.reason

    def test_failing_probe_falls_back_to_fixture_with_reason(self):
        selection = build_order_rescue_adapters(
            fixture(), env=FULL_ENV,
            shopify_transport=failing_transport, slack_transport=ok_transport,
        )
        assert selection.adapters.channel == "fixture"
        assert "probe failed" in selection.reason


class TestLiveComposition:
    def test_writes_route_to_channels_and_fetch_back_through_them(self):
        adapters = live_adapters()
        adapters.add_note_and_tag("Carrier delay noted", "Carrier Delay")
        adapters.issue_store_credit(20)
        adapters.post_operations_message("@Sarah escalation")
        adapters.send_customer_choice_message("choose", "maya@example.com")
        adapters.create_followup_reminder("Verify tracking")
        state = adapters.fetch_shopify_state()
        assert "Carrier Delay" in state["tags"] and "VIP" in state["tags"]
        assert state["store_credit_usd"] == 20
        assert adapters.fetch_operations_messages() == ["@Sarah escalation"]
        assert adapters.fetch_customer_messages() == ["choose"]
        assert adapters.fetch_reminders() == ["Verify tracking"]


class TestRouterUsesSelectedChannel:
    def call(self, tool, **arguments):
        return ConversationToolCall(
            call_id=f"call_{tool}", tool=tool, arguments=arguments
        )

    def test_execution_labels_channel_in_verification_and_ledger(self):
        selection = AdapterSelection(
            adapters=live_adapters(), reason="test live channel"
        )
        r = ConversationToolRouter(
            fixture=fixture(), adapters_factory=lambda: selection
        )
        r.handle(TASK_ID, self.call("compile_task", transcript="Take care of this delayed order"))
        r.handle(TASK_ID, self.call(
            "apply_patch",
            transcript=(
                "Actually, don't create the replacement yet. Ask replacement or "
                "refund, $20 credit, notify Sarah in Slack."
            ),
        ))
        binding = r.handle(TASK_ID, self.call("request_approval"))[-1].payload.result
        r.handle(TASK_ID, self.call(
            "confirm_approval",
            binding_hash=binding["binding_hash"], utterance="yes",
        ))
        events = r.handle(TASK_ID, self.call("execute_plan"))
        completed = next(e for e in events if e.type == EventType.TASK_COMPLETED)
        assert completed.payload.state == "succeeded"
        assert all(
            check.method.endswith("@shopify.live+slack.live")
            for check in completed.payload.verification
        )
        ledger_texts = [
            e.payload.found for e in events if e.type == EventType.LEDGER_EVENT
        ]
        assert any(
            found and "channel=shopify.live+slack.live" in found
            for found in ledger_texts
        )
        assert events[-1].payload.result["channel"] == "shopify.live+slack.live"
