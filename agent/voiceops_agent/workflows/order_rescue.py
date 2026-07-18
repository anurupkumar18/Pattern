"""Versioned intent compiler for the delayed-order rescue hero workflow.

This module is pure and fixture-first. It compiles trusted, typed order evidence
and the operator's spoken request into an immutable task snapshot, then applies
small validated patches without regenerating or forgetting the prior task.
Native/live adapters consume the resulting contract in later layers.
"""

from __future__ import annotations

from datetime import date, datetime
from typing import Any
from uuid import UUID

from pydantic import Field

from ..schemas import (
    AppliedPlanPatch,
    PlanPatch,
    PlanPatchOperation,
    TaskActionDefinition,
    VersionedTaskSpec,
    VoiceOpsModel,
)


class OrderRescuePlanningError(ValueError):
    """The task or patch could not be applied without losing safety or intent."""


class CustomerSnapshot(VoiceOpsModel):
    id: str
    name: str
    email: str
    lifetime_value_usd: float = Field(ge=0)
    order_count: int = Field(ge=0)


class TrackingSnapshot(VoiceOpsModel):
    carrier: str
    tracking_number: str
    promised_delivery: date
    last_scan_at: datetime
    stationary_hours: int = Field(ge=0)
    status: str


class InventorySnapshot(VoiceOpsModel):
    sku: str
    available_units: int = Field(ge=0)
    expedited_arrival: date


class PolicySnapshot(VoiceOpsModel):
    id: str
    version: str
    delayed_after_hours: int = Field(ge=1)
    vip_lifetime_value_usd: float = Field(ge=0)


class OrderRescueState(VoiceOpsModel):
    shopify_tags: list[str] = Field(default_factory=list)
    shopify_notes: list[str] = Field(default_factory=list)
    store_credit_usd: int = Field(default=0, ge=0)
    customer_messages: list[str] = Field(default_factory=list)
    operations_messages: list[str] = Field(default_factory=list)
    reminders: list[str] = Field(default_factory=list)
    refund_issued: bool = False
    replacement_order_id: str | None = None


class OrderRescueFixture(VoiceOpsModel):
    store: str
    order_id: str
    order_total_usd: float = Field(ge=0)
    customer_deadline: date
    shipping_address: str
    customer: CustomerSnapshot
    tracking: TrackingSnapshot
    inventory: InventorySnapshot
    policy: PolicySnapshot
    initial_state: OrderRescueState


def compile_order_rescue_task(
    task_id: UUID,
    raw_request: str,
    fixture: OrderRescueFixture,
) -> VersionedTaskSpec:
    """Compile the initial spoken request without pretending actions occurred."""
    actions = {
        "review_tracking": _action(
            "review_tracking",
            "Review the carrier timeline and calculate hours without movement",
            "read",
        ),
        "check_inventory": _action(
            "check_inventory",
            "Confirm replacement inventory and delivery feasibility before Friday",
            "read",
        ),
        "create_replacement": _action(
            "create_replacement",
            "Create an expedited replacement only after explicit approval",
            "consequential",
            confirmation=True,
        ),
        "add_shopify_note": _action(
            "add_shopify_note",
            "Add a Carrier Delay tag and internal evidence note to the order",
            "reversible_write",
        ),
        "draft_customer_apology": _action(
            "draft_customer_apology",
            "Draft an apology explaining the proposed expedited replacement",
            "reversible_write",
        ),
        "create_followup": _action(
            "create_followup",
            "Create a reminder for tomorrow morning to verify new tracking",
            "reversible_write",
        ),
    }
    constraints = {
        "no_refund": "Do not issue a refund.",
        "preserve_address": "Preserve the customer's original shipping address.",
        "shipping_approval": "Require approval before purchasing expedited shipping.",
        "customer_deadline": (
            f"The customer needs delivery by {fixture.customer_deadline.isoformat()}."
        ),
    }
    criteria = {
        "tracking_reviewed": "Latest carrier movement and stationary hours are recorded.",
        "shopify_updated": "Carrier Delay tag and internal note exist in Shopify.",
        "replacement_ready": "Approved expedited replacement exists in Shopify.",
        "customer_contacted": "Customer apology is prepared with the proposed resolution.",
        "followup_scheduled": "Tomorrow-morning tracking reminder exists.",
        "no_refund": "No refund exists for the original order.",
    }
    return VersionedTaskSpec(
        task_id=task_id,
        version=1,
        raw_request=raw_request,
        objective=(
            f"Resolve delayed order {fixture.order_id} for {fixture.customer.name} "
            f"before {fixture.customer_deadline.isoformat()}."
        ),
        entities={
            "order": fixture.order_id,
            "customer": fixture.customer.name,
            "customer_email": fixture.customer.email,
            "deadline": fixture.customer_deadline.isoformat(),
            "tracking_number": fixture.tracking.tracking_number,
            "policy_version": f"{fixture.policy.id}@{fixture.policy.version}",
        },
        evidence_to_collect=[
            "Latest carrier scan and hours without movement",
            "Original promised delivery date",
            "Customer order history and lifetime value",
            "Replacement inventory and expedited arrival estimate",
            "Applicable delayed-shipment policy version",
        ],
        actions=actions,
        constraints=constraints,
        completion_criteria=criteria,
        provenance={
            "order": ["shopify.order"],
            "customer": ["shopify.customer"],
            "tracking": ["carrier.tracking"],
            "policy": [f"policy:{fixture.policy.id}@{fixture.policy.version}"],
            "request": ["microphone.operator"],
        },
    )


def build_customer_choice_patch(base_version: int, transcript: str) -> PlanPatch:
    """Compile the exact mid-flight demo correction into a minimal patch."""
    return PlanPatch(
        base_version=base_version,
        transcript=transcript,
        operations=[
            PlanPatchOperation(operation="remove", target="actions.create_replacement"),
            PlanPatchOperation(
                operation="add",
                target="actions.ask_customer_preference",
                value=_action(
                    "ask_customer_preference",
                    "Send a message asking the customer to choose replacement or refund",
                    "consequential",
                    confirmation=True,
                ).model_dump(mode="python"),
            ),
            PlanPatchOperation(
                operation="add",
                target="actions.issue_store_credit",
                value=_action(
                    "issue_store_credit",
                    "Issue a $20 store credit after explicit approval",
                    "consequential",
                    confirmation=True,
                ).model_dump(mode="python"),
            ),
            PlanPatchOperation(
                operation="add",
                target="actions.notify_operations",
                value=_action(
                    "notify_operations",
                    "Notify Sarah in #shipping-escalations about the third carrier delay",
                    "consequential",
                    confirmation=True,
                ).model_dump(mode="python"),
            ),
            PlanPatchOperation(
                operation="add",
                target="constraints.no_replacement_without_confirmation",
                value="Do not create a replacement before the customer confirms.",
            ),
            PlanPatchOperation(
                operation="remove",
                target="completion_criteria.replacement_ready",
            ),
            PlanPatchOperation(
                operation="replace",
                target="completion_criteria.customer_contacted",
                value="Customer choice message was sent after approval.",
            ),
            PlanPatchOperation(
                operation="add",
                target="completion_criteria.store_credit_issued",
                value="$20 store credit exists for the customer.",
            ),
            PlanPatchOperation(
                operation="add",
                target="completion_criteria.operations_notified",
                value="Slack escalation exists in #shipping-escalations.",
            ),
            PlanPatchOperation(
                operation="add",
                target="completion_criteria.no_replacement",
                value="No replacement order exists before customer confirmation.",
            ),
        ],
    )


def apply_plan_patch(current: VersionedTaskSpec, patch: PlanPatch) -> VersionedTaskSpec:
    """Return a new task snapshot; reject stale or unsafe mutations."""
    if patch.base_version != current.version:
        raise OrderRescuePlanningError(
            f"stale patch: base version {patch.base_version}, current version {current.version}"
        )

    data = current.model_dump(mode="python")
    before_targets = _all_targets(data)
    replaced: list[str] = []
    for operation in patch.operations:
        section_name, key = operation.target.split(".", 1)
        section: dict[str, Any] = data[section_name]
        exists = key in section
        if operation.operation == "add":
            if exists:
                raise OrderRescuePlanningError(f"cannot add existing target {operation.target}")
            section[key] = _validated_value(section_name, key, operation.value)
        elif operation.operation == "remove":
            if not exists:
                raise OrderRescuePlanningError(f"cannot remove missing target {operation.target}")
            if section_name == "actions" and _action_status(section[key]) == "completed":
                raise OrderRescuePlanningError(
                    f"cannot remove completed action {operation.target}"
                )
            del section[key]
        else:
            if not exists:
                raise OrderRescuePlanningError(f"cannot replace missing target {operation.target}")
            if section_name == "actions" and _action_status(section[key]) == "completed":
                raise OrderRescuePlanningError(
                    f"cannot replace completed action {operation.target}"
                )
            section[key] = _validated_value(section_name, key, operation.value)
            replaced.append(operation.target)

    after_targets = _all_targets(data)
    history = list(current.patch_history)
    history.append(AppliedPlanPatch(
        base_version=current.version,
        new_version=current.version + 1,
        transcript=patch.transcript,
        operations=patch.operations,
        added=sorted(after_targets - before_targets),
        removed=sorted(before_targets - after_targets),
        replaced=sorted(replaced),
        preserved=sorted((before_targets & after_targets) - set(replaced)),
    ))
    data["version"] = current.version + 1
    data["patch_history"] = history
    return VersionedTaskSpec.model_validate(data)


def _action(
    identifier: str,
    description: str,
    risk: str,
    *,
    confirmation: bool = False,
) -> TaskActionDefinition:
    return TaskActionDefinition(
        id=identifier,
        description=description,
        risk=risk,
        requires_confirmation=confirmation,
    )


def _all_targets(data: dict[str, Any]) -> set[str]:
    return {
        f"{section}.{key}"
        for section in ("actions", "constraints", "entities", "completion_criteria")
        for key in data[section]
    }


def _validated_value(section: str, key: str, value: Any) -> Any:
    if section == "actions":
        action = TaskActionDefinition.model_validate(value)
        if action.id != key:
            raise OrderRescuePlanningError(
                f"action value ID {action.id!r} does not match target key {key!r}"
            )
        return action
    if not isinstance(value, str) or not value.strip():
        raise OrderRescuePlanningError(f"{section} patch values must be non-empty strings")
    return value


def _action_status(value: Any) -> str | None:
    if isinstance(value, TaskActionDefinition):
        return value.status
    if isinstance(value, dict):
        return value.get("status")
    return None
