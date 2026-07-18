"""Channel adapter seam for Order Rescue execution and verification.

One protocol serves both fixture and live implementations. The executor calls
only write methods; the verifier calls only fetch_* methods, so completion
evidence is always a fetch-back and never an executor echo. Implementations
must be idempotent per (method, payload).
"""

from __future__ import annotations

from typing import Any, Protocol

from .order_rescue import OrderRescueFixture, OrderRescueState


class OrderRescueChannelAdapters(Protocol):
    channel: str

    def add_note_and_tag(self, note: str, tag: str) -> None: ...
    def issue_store_credit(self, amount_usd: int) -> None: ...
    def send_customer_choice_message(self, message: str, email: str) -> None: ...
    def post_operations_message(self, message: str) -> None: ...
    def create_followup_reminder(self, title: str) -> None: ...
    def fetch_shopify_state(self) -> dict[str, Any]: ...
    def fetch_customer_messages(self) -> list[str]: ...
    def fetch_operations_messages(self) -> list[str]: ...
    def fetch_reminders(self) -> list[str]: ...


class FixtureOrderRescueAdapters:
    """Deterministic semantic state, identical to the ADR-020 demo behavior."""

    channel = "fixture"

    def __init__(self, fixture: OrderRescueFixture) -> None:
        self._state = OrderRescueState.model_validate(
            fixture.initial_state.model_dump(mode="python")
        )

    @classmethod
    def wrapping(cls, state: OrderRescueState) -> "FixtureOrderRescueAdapters":
        """Adapter view over an existing state snapshot (verifier fetch-back)."""
        instance = cls.__new__(cls)
        instance._state = state
        return instance

    def add_note_and_tag(self, note: str, tag: str) -> None:
        if tag not in self._state.shopify_tags:
            self._state.shopify_tags.append(tag)
        if note not in self._state.shopify_notes:
            self._state.shopify_notes.append(note)

    def issue_store_credit(self, amount_usd: int) -> None:
        self._state.store_credit_usd = amount_usd

    def send_customer_choice_message(self, message: str, email: str) -> None:
        if message not in self._state.customer_messages:
            self._state.customer_messages.append(message)

    def post_operations_message(self, message: str) -> None:
        if message not in self._state.operations_messages:
            self._state.operations_messages.append(message)

    def create_followup_reminder(self, title: str) -> None:
        if title not in self._state.reminders:
            self._state.reminders.append(title)

    def fetch_shopify_state(self) -> dict[str, Any]:
        return {
            "tags": list(self._state.shopify_tags),
            "notes": list(self._state.shopify_notes),
            "store_credit_usd": self._state.store_credit_usd,
            "refund_issued": self._state.refund_issued,
            "replacement_order_id": self._state.replacement_order_id,
        }

    def fetch_customer_messages(self) -> list[str]:
        return list(self._state.customer_messages)

    def fetch_operations_messages(self) -> list[str]:
        return list(self._state.operations_messages)

    def fetch_reminders(self) -> list[str]:
        return list(self._state.reminders)

    # The execution result's state snapshot in fixture mode.
    @property
    def state(self) -> OrderRescueState:
        return self._state
