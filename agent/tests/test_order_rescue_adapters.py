"""The channel adapter seam: executors write through it, verifiers fetch back
through it, and fixture and live implementations are interchangeable."""

from pathlib import Path

from voiceops_agent.workflows.order_rescue import OrderRescueFixture
from voiceops_agent.workflows.order_rescue_adapters import FixtureOrderRescueAdapters

FIXTURE_PATH = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "order_rescue"
    / "golden_order_1842.json"
)


def adapters() -> FixtureOrderRescueAdapters:
    fixture = OrderRescueFixture.model_validate_json(FIXTURE_PATH.read_text())
    return FixtureOrderRescueAdapters(fixture)


def test_fixture_adapters_write_and_fetch_back():
    a = adapters()
    a.add_note_and_tag("Carrier delay: no movement for 91h.", "Carrier Delay")
    a.issue_store_credit(20)
    a.post_operations_message("@Sarah Order #1842 third delay")
    shopify = a.fetch_shopify_state()
    assert "Carrier Delay" in shopify["tags"]
    assert shopify["store_credit_usd"] == 20
    assert shopify["refund_issued"] is False
    assert shopify["replacement_order_id"] is None
    assert a.fetch_operations_messages() == ["@Sarah Order #1842 third delay"]
    assert a.channel == "fixture"


def test_fixture_adapters_are_idempotent():
    a = adapters()
    a.add_note_and_tag("note", "Carrier Delay")
    a.add_note_and_tag("note", "Carrier Delay")
    assert a.fetch_shopify_state()["tags"].count("Carrier Delay") == 1
    a.send_customer_choice_message("choose please", "maya@example.com")
    a.send_customer_choice_message("choose please", "maya@example.com")
    assert a.fetch_customer_messages() == ["choose please"]
    a.create_followup_reminder("Verify Order #1842 tracking")
    a.create_followup_reminder("Verify Order #1842 tracking")
    assert a.fetch_reminders() == ["Verify Order #1842 tracking"]
