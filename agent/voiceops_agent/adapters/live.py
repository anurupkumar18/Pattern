"""Live channel composition and credential-gated selection for Order Rescue.

Live execution is chosen only when every credential is present and both
provider probes succeed; anything else selects the deterministic fixture
adapters, and the reason travels with the selection so execution evidence
always states which channel the writes touched.

The customer-message outbox and follow-up reminder stay process-local by
design: outbound customer email is out of demo scope, and the reminder is
executed natively through EventKit by the macOS shell.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any, Mapping

from ..workflows.order_rescue import OrderRescueFixture
from ..workflows.order_rescue_adapters import (
    FixtureOrderRescueAdapters,
    OrderRescueChannelAdapters,
)
from .shopify import ShopifyAdapterError, ShopifyAdminAdapter, Transport
from .slack import SlackAdapter, SlackAdapterError

REQUIRED_ENV = (
    "VOICEOPS_SHOPIFY_SHOP",
    "VOICEOPS_SHOPIFY_TOKEN",
    "VOICEOPS_SHOPIFY_ORDER_ID",
    "VOICEOPS_SLACK_BOT_TOKEN",
    "VOICEOPS_SLACK_CHANNEL_ID",
)


@dataclass(frozen=True)
class AdapterSelection:
    adapters: OrderRescueChannelAdapters
    reason: str


class LiveOrderRescueAdapters:
    """Composes the live Shopify and Slack channels into the adapter protocol."""

    channel = "shopify.live+slack.live"

    def __init__(self, shopify, slack) -> None:
        self._shopify = shopify
        self._slack = slack
        self._customer_messages: list[str] = []
        self._reminders: list[str] = []

    def health_check(self) -> None:
        self._shopify.probe()
        self._slack.probe()

    def add_note_and_tag(self, note: str, tag: str) -> None:
        self._shopify.add_note_and_tag(note, tag)

    def issue_store_credit(self, amount_usd: int) -> None:
        self._shopify.issue_store_credit(amount_usd)

    def send_customer_choice_message(self, message: str, email: str) -> None:
        if message not in self._customer_messages:
            self._customer_messages.append(message)

    def post_operations_message(self, message: str) -> None:
        self._slack.post_operations_message(message)

    def create_followup_reminder(self, title: str) -> None:
        if title not in self._reminders:
            self._reminders.append(title)

    def fetch_shopify_state(self) -> dict[str, Any]:
        return self._shopify.fetch_state()

    def fetch_customer_messages(self) -> list[str]:
        return list(self._customer_messages)

    def fetch_operations_messages(self) -> list[str]:
        return self._slack.fetch_operations_messages()

    def fetch_reminders(self) -> list[str]:
        return list(self._reminders)


def build_order_rescue_adapters(
    fixture: OrderRescueFixture,
    env: Mapping[str, str] | None = None,
    shopify_transport: Transport | None = None,
    slack_transport: Transport | None = None,
) -> AdapterSelection:
    env = env if env is not None else os.environ
    missing = [key for key in REQUIRED_ENV if not env.get(key, "").strip()]
    if missing:
        return AdapterSelection(
            adapters=FixtureOrderRescueAdapters(fixture),
            reason="fixture (credentials absent: " + ", ".join(missing) + ")",
        )
    live = LiveOrderRescueAdapters(
        shopify=ShopifyAdminAdapter(
            shop=env["VOICEOPS_SHOPIFY_SHOP"].strip(),
            token=env["VOICEOPS_SHOPIFY_TOKEN"].strip(),
            order_id=env["VOICEOPS_SHOPIFY_ORDER_ID"].strip(),
            transport=shopify_transport,
        ),
        slack=SlackAdapter(
            token=env["VOICEOPS_SLACK_BOT_TOKEN"].strip(),
            channel_id=env["VOICEOPS_SLACK_CHANNEL_ID"].strip(),
            order_id=env["VOICEOPS_SHOPIFY_ORDER_ID"].strip(),
            transport=slack_transport,
        ),
    )
    try:
        live.health_check()
    except (ShopifyAdapterError, SlackAdapterError) as error:
        return AdapterSelection(
            adapters=FixtureOrderRescueAdapters(fixture),
            reason=f"fixture (live probe failed: {str(error)[:160]})",
        )
    return AdapterSelection(
        adapters=live,
        reason="live credentials present and healthy",
    )
