"""Deterministic semantic executor and independent verifier for Order Rescue."""

from __future__ import annotations

from datetime import UTC, datetime, timedelta
from typing import Any, Literal

from pydantic import Field

from ..schemas import (
    ExecutionLedgerEvent,
    TaskActionDefinition,
    VerificationResult,
    VersionedTaskSpec,
    VoiceOpsModel,
)
from .order_rescue import OrderRescueFixture, OrderRescueState
from .order_rescue_adapters import FixtureOrderRescueAdapters, OrderRescueChannelAdapters


class OrderRescueExecutionError(ValueError):
    pass


class OrderRescueActionRecord(VoiceOpsModel):
    action_id: str
    status: Literal["executed", "no_op", "deferred"]
    evidence_ids: list[str] = Field(default_factory=list)
    observed: dict[str, Any] = Field(default_factory=dict)


class OrderRescueExecutionResult(VoiceOpsModel):
    status: Literal["completed", "stopped"]
    state: OrderRescueState
    actions: dict[str, OrderRescueActionRecord]
    ledger: list[ExecutionLedgerEvent]
    stopped_before_action: str | None = None


class OrderRescueVerificationReport(VoiceOpsModel):
    state: Literal["succeeded", "partial", "failed"]
    headline: str
    core_checks: list[VerificationResult]
    negative_checks: list[VerificationResult]
    ledger: list[ExecutionLedgerEvent]


ACTION_ORDER = (
    "review_tracking",
    "check_inventory",
    "add_shopify_note",
    "draft_customer_apology",
    "issue_store_credit",
    "ask_customer_preference",
    "notify_operations",
    "create_followup",
)


class FixtureOrderRescueExecutor:
    """Applies semantic fixture state changes with approval and stop barriers."""

    def execute(
        self,
        task: VersionedTaskSpec,
        fixture: OrderRescueFixture,
        *,
        approved_action_ids: set[str],
        stop_before_action: str | None = None,
        adapters: OrderRescueChannelAdapters | None = None,
        channel_reason: str | None = None,
        defer_native_reminder: bool = False,
    ) -> OrderRescueExecutionResult:
        adapters = adapters if adapters is not None else FixtureOrderRescueAdapters(fixture)
        _require_corrected_task(task)
        required = {
            action_id
            for action_id, action in task.actions.items()
            if action.requires_confirmation and action.status == "pending"
        }
        missing = sorted(required - approved_action_ids)
        if missing:
            raise OrderRescueExecutionError(
                "approval required before any write: " + ", ".join(missing)
            )

        applied = list(fixture.initial_state.applied_action_ids)
        actions: dict[str, OrderRescueActionRecord] = {}
        ledger: list[ExecutionLedgerEvent] = []
        clock = _LedgerClock()
        ledger.append(clock.event(
            "decided",
            where="VoiceOps channel selector",
            what="Selected the execution channel for all writes.",
            found=(
                f"channel={adapters.channel}"
                + (f" — {channel_reason}" if channel_reason else "")
            ),
            source="sidecar.configuration",
            why="Evidence must state whether writes touched live systems or fixtures.",
            confidence=1,
            next="Execute only approved actions through this channel.",
        ))
        if required:
            ledger.append(clock.event(
                "decided",
                where="VoiceOps authorization gate",
                what="Bound explicit operator approval to the corrected action set.",
                found=(
                    "Approved action IDs: " + ", ".join(sorted(required))
                ),
                source="microphone.operator",
                why="Consequential actions must be traceable to the user's latest instruction.",
                confidence=1,
                next="Execute only the approved version-two actions.",
            ))

        for action_id in ACTION_ORDER:
            action = task.actions.get(action_id)
            if action is None or action.status != "pending":
                continue
            if defer_native_reminder and action_id == "create_followup":
                actions[action_id] = OrderRescueActionRecord(
                    action_id=action_id,
                    status="deferred",
                    evidence_ids=["eventkit:pending"],
                )
                ledger.append(clock.event(
                    "decided",
                    where="VoiceOps native action bridge",
                    what="Deferred the follow-up reminder to macOS EventKit.",
                    found="No in-memory reminder write was performed.",
                    source="eventkit:pending",
                    why="Live mode must prove the reminder through native fetch-back.",
                    confidence=1,
                    next="Wait for one native action result and five verifier results.",
                ))
                continue
            if stop_before_action == action_id:
                ledger.append(clock.event(
                    "decided",
                    where="VoiceOps safety controller",
                    what=f"Stopped before {action.description}",
                    found="Emergency stop barrier is active; no later action may start.",
                    source="operator.stop",
                    why="User control outranks completion speed.",
                    confidence=1,
                    next="Report completed work and unstarted actions.",
                ))
                return OrderRescueExecutionResult(
                    status="stopped",
                    state=_snapshot(adapters, applied),
                    actions=actions,
                    ledger=ledger,
                    stopped_before_action=action_id,
                )

            if action_id in applied:
                actions[action_id] = OrderRescueActionRecord(
                    action_id=action_id,
                    status="no_op",
                    evidence_ids=[f"idempotency:{action_id}"],
                )
                ledger.append(clock.event(
                    "acted",
                    where="VoiceOps idempotency ledger",
                    what=f"Skipped replay of {action.description}",
                    found="The action idempotency key was already committed.",
                    source=f"idempotency:{action_id}",
                    why="A replay must never duplicate customer or operational side effects.",
                    confidence=1,
                    next="Continue with the next uncommitted action.",
                ))
                continue

            record = self._apply(action_id, action, adapters, fixture, clock, ledger)
            applied.append(action_id)
            actions[action_id] = record

        return OrderRescueExecutionResult(
            status="completed",
            state=_snapshot(adapters, applied),
            actions=actions,
            ledger=ledger,
        )

    def _apply(
        self,
        action_id: str,
        action: TaskActionDefinition,
        adapters: OrderRescueChannelAdapters,
        fixture: OrderRescueFixture,
        clock: "_LedgerClock",
        ledger: list[ExecutionLedgerEvent],
    ) -> OrderRescueActionRecord:
        if action_id == "review_tracking":
            observed = {
                "last_scan_at": fixture.tracking.last_scan_at.isoformat(),
                "stationary_hours": fixture.tracking.stationary_hours,
            }
            ledger.extend([
                clock.event(
                    "observed", where=f"Carrier → {fixture.tracking.carrier}",
                    what="Read the latest tracking event.",
                    found=(
                        f"No carrier movement for {fixture.tracking.stationary_hours} hours; "
                        f"last scan {fixture.tracking.last_scan_at.isoformat()}."
                    ),
                    source="carrier.tracking",
                    why="The delay duration determines whether policy permits intervention.",
                    confidence=1, next="Compare the delay with store policy.",
                ),
                clock.event(
                    "interpreted", where="VoiceOps policy engine",
                    what="Compared tracking evidence with the delayed-shipment policy.",
                    found=(
                        f"{fixture.tracking.stationary_hours} hours exceeds the "
                        f"{fixture.policy.delayed_after_hours}-hour threshold."
                    ),
                    source=f"policy:{fixture.policy.id}@{fixture.policy.version}",
                    why="The exception qualifies for proactive resolution.",
                    confidence=1, next="Confirm inventory and delivery feasibility.",
                ),
            ])
            return _record(action_id, observed, "carrier:latest-scan")

        if action_id == "check_inventory":
            observed = {
                "available_units": fixture.inventory.available_units,
                "expedited_arrival": fixture.inventory.expedited_arrival.isoformat(),
            }
            ledger.append(clock.event(
                "observed", where="Shopify → Inventory",
                what="Checked replacement inventory and expedited arrival.",
                found=(
                    f"{fixture.inventory.available_units} units available; earliest arrival "
                    f"{fixture.inventory.expedited_arrival.isoformat()}."
                ),
                source="shopify.inventory",
                why="Resolution options must be feasible before contacting the customer.",
                confidence=1, next="Apply the corrected plan without creating a replacement.",
            ))
            return _record(action_id, observed, "shopify:inventory")

        if action_id == "add_shopify_note":
            note = (
                f"Carrier delay: no movement for {fixture.tracking.stationary_hours}h. "
                "Awaiting customer choice; do not replace or refund yet."
            )
            adapters.add_note_and_tag(note, "Carrier Delay")
            return self._acted(clock, ledger, action_id, action, "Shopify → Order #1842", "shopify:order-note")

        if action_id == "draft_customer_apology":
            return self._acted(clock, ledger, action_id, action, "VoiceOps draft workspace", "draft:customer-apology")

        if action_id == "issue_store_credit":
            adapters.issue_store_credit(20)
            return self._acted(clock, ledger, action_id, action, "Shopify → Customer credit", "shopify:credit-20")

        if action_id == "ask_customer_preference":
            message = (
                "Hi Maya — I’m sorry your order is delayed. Would you prefer an "
                "expedited replacement or a full refund? We added a $20 store credit "
                "either way and will wait for your choice."
            )
            adapters.send_customer_choice_message(message, fixture.customer.email)
            return self._acted(clock, ledger, action_id, action, "Customer inbox → Sent", "mail:maya-choice")

        if action_id == "notify_operations":
            message = (
                "@Sarah Order #1842 is the third delayed package from this carrier; "
                "customer choice is pending."
            )
            adapters.post_operations_message(message)
            return self._acted(clock, ledger, action_id, action, "Slack → #shipping-escalations", "slack:carrier-escalation")

        if action_id == "create_followup":
            adapters.create_followup_reminder(
                "Verify Order #1842 tracking — 2026-07-19 09:00"
            )
            return self._acted(clock, ledger, action_id, action, "Reminders → VoiceOps", "reminder:order-1842")

        raise OrderRescueExecutionError(f"unsupported fixture action {action_id}")

    def _acted(
        self,
        clock: "_LedgerClock",
        ledger: list[ExecutionLedgerEvent],
        action_id: str,
        action: TaskActionDefinition,
        where: str,
        evidence_id: str,
    ) -> OrderRescueActionRecord:
        ledger.append(clock.event(
            "acted", where=where, what=action.description,
            found="The semantic adapter committed one idempotent state change.",
            source=evidence_id,
            why="This action is required by the corrected, approved plan.",
            confidence=1, next="Re-read the resulting state before claiming success.",
        ))
        return _record(action_id, {}, evidence_id)


def verify_order_rescue(
    task: VersionedTaskSpec,
    fixture: OrderRescueFixture,
    execution: OrderRescueExecutionResult,
    adapters: OrderRescueChannelAdapters | None = None,
    native_reminder: VerificationResult | None = None,
) -> OrderRescueVerificationReport:
    """Evaluate freshly fetched channel state; executor status never implies success."""
    if adapters is None:
        adapters = FixtureOrderRescueAdapters.wrapping(execution.state)
    channel = adapters.channel
    shopify = adapters.fetch_shopify_state()
    customer_messages = adapters.fetch_customer_messages()
    operations_messages = adapters.fetch_operations_messages()
    reminders = adapters.fetch_reminders()
    tracking = execution.actions.get("review_tracking")
    core = [
        _check(
            "tracking-reviewed",
            tracking is not None
            and tracking.observed.get("stationary_hours") == fixture.tracking.stationary_hours
            and tracking.observed.get("last_scan_at") == fixture.tracking.last_scan_at.isoformat(),
            f"carrier_snapshot_refetch@{channel}",
            {"stationary_hours": fixture.tracking.stationary_hours},
            tracking.observed if tracking else {},
            tracking.evidence_ids if tracking else [],
        ),
        _check(
            "shopify-updated",
            "Carrier Delay" in shopify["tags"]
            and any("Awaiting customer choice" in note for note in shopify["notes"])
            and shopify["store_credit_usd"] == 20,
            f"shopify_state_refetch@{channel}",
            {"tag": "Carrier Delay", "credit_usd": 20},
            {"tags": shopify["tags"], "credit_usd": shopify["store_credit_usd"]},
            ["shopify:order-note", "shopify:credit-20"],
        ),
        _check(
            "customer-contacted",
            any(
                "expedited replacement or a full refund" in item
                for item in customer_messages
            ),
            f"sent_message_refetch@{channel}",
            {"recipient": fixture.customer.email, "choice_requested": True},
            {"sent_count": len(customer_messages)},
            ["mail:maya-choice"],
        ),
        _check(
            "operations-notified",
            any(
                "@Sarah" in item and "third delayed package" in item
                for item in operations_messages
            ),
            f"slack_channel_refetch@{channel}",
            {"channel": "#shipping-escalations", "mentions": "Sarah"},
            {"message_count": len(operations_messages)},
            ["slack:carrier-escalation"],
        ),
        native_reminder or _check(
            "followup-scheduled",
            "Verify Order #1842 tracking — 2026-07-19 09:00" in reminders,
            f"reminders_refetch@{channel}",
            {"title": "Verify Order #1842 tracking", "date": "2026-07-19 09:00"},
            {"reminders": reminders},
            ["reminder:order-1842"],
        ),
    ]
    negative = [
        _check(
            "no-refund-issued", not shopify["refund_issued"],
            f"shopify_transaction_refetch@{channel}", {"refund_issued": False},
            {"refund_issued": shopify["refund_issued"]}, ["shopify:transactions"],
        ),
        _check(
            "no-replacement-created", shopify["replacement_order_id"] is None,
            f"shopify_order_refetch@{channel}", {"replacement_order_id": None},
            {"replacement_order_id": shopify["replacement_order_id"]}, ["shopify:orders"],
        ),
    ]
    passed = sum(item.passed for item in core)
    all_pass = passed == len(core) and all(item.passed for item in negative)
    if all_pass:
        result_state: Literal["succeeded", "partial", "failed"] = "succeeded"
    elif passed:
        result_state = "partial"
    else:
        result_state = "failed"
    ledger = list(execution.ledger)
    clock = _LedgerClock(start_after=ledger[-1].timestamp if ledger else None, sequence=len(ledger))
    for item in core + negative:
        ledger.append(clock.event(
            "verified", where="Independent Order Rescue verifier",
            what=f"Checked {item.predicate_id}",
            found="Passed" if item.passed else f"Failed: {item.failure_reason}",
            source=item.method,
            why="Only fresh predicate evidence may contribute to completion.",
            confidence=item.confidence,
            next="Continue verification." if item is not negative[-1] else "Report the verified outcome.",
        ))
    headline = (
        f"ORDER RESCUE COMPLETED — {passed}/{len(core)} CHECKS PASSED"
        if all_pass
        else f"ORDER RESCUE NOT VERIFIED — {passed}/{len(core)} CHECKS PASSED"
    )
    return OrderRescueVerificationReport(
        state=result_state, headline=headline,
        core_checks=core, negative_checks=negative, ledger=ledger,
    )


def _require_corrected_task(task: VersionedTaskSpec) -> None:
    required = {
        "ask_customer_preference", "issue_store_credit", "notify_operations",
        "add_shopify_note", "create_followup", "review_tracking",
    }
    if task.version < 2 or not required.issubset(task.actions):
        raise OrderRescueExecutionError("the corrected version-two task is required")
    if "create_replacement" in task.actions:
        raise OrderRescueExecutionError("replacement creation must be removed before execution")


def _snapshot(
    adapters: OrderRescueChannelAdapters, applied: list[str]
) -> OrderRescueState:
    shopify = adapters.fetch_shopify_state()
    return OrderRescueState(
        shopify_tags=shopify["tags"],
        shopify_notes=shopify["notes"],
        store_credit_usd=shopify["store_credit_usd"],
        customer_messages=adapters.fetch_customer_messages(),
        operations_messages=adapters.fetch_operations_messages(),
        reminders=adapters.fetch_reminders(),
        refund_issued=shopify["refund_issued"],
        replacement_order_id=shopify["replacement_order_id"],
        applied_action_ids=list(applied),
    )


def _record(action_id: str, observed: dict[str, Any], *evidence: str) -> OrderRescueActionRecord:
    return OrderRescueActionRecord(
        action_id=action_id, status="executed",
        evidence_ids=list(evidence), observed=observed,
    )


def _check(
    predicate_id: str,
    passed: bool,
    method: str,
    expected: dict[str, Any],
    observed: dict[str, Any],
    evidence_ids: list[str],
) -> VerificationResult:
    return VerificationResult(
        predicate_id=predicate_id, passed=passed, method=method,
        confidence=1, expected=expected, observed=observed,
        evidence_ids=evidence_ids,
        failure_reason=None if passed else "Fresh state did not match the required predicate",
    )


class _LedgerClock:
    def __init__(self, *, start_after: datetime | None = None, sequence: int = 0) -> None:
        self._time = (start_after or datetime(2026, 7, 18, 22, 34, 11, tzinfo=UTC))
        self._sequence = sequence

    def event(
        self, event_type: str, *, where: str, what: str, found: str | None,
        source: str, why: str, confidence: float, next: str | None,
    ) -> ExecutionLedgerEvent:
        self._sequence += 1
        self._time += timedelta(seconds=1)
        return ExecutionLedgerEvent(
            sequence=self._sequence, timestamp=self._time,
            event_type=event_type, where=where, what=what, found=found,
            source=source, why_it_matters=why,
            confidence=confidence, next=next,
        )
