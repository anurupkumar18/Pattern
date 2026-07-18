"""Conversation-layer authority helpers: approval binding and affirmative gating.

The S2S voice layer proposes; this module decides. A spoken approval authorizes
exactly one hash over the pending consequential action set at one task version.
Any change to the set or version produces a different hash, so a stale or
misheard yes can never authorize new work.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from typing import Any
from uuid import UUID

from .schemas import (
    ApprovalBinding,
    ConversationToolCall,
    ConversationToolResult,
    Envelope,
    EventType,
    ExecutionLedgerEvent,
    FailureCode,
    StructuredError,
    VersionedTaskSpec,
    make_envelope,
)
from .workflows.order_rescue import (
    OrderRescueFixture,
    OrderRescuePlanningError,
    apply_plan_patch,
    build_customer_choice_patch,
    compile_order_rescue_task,
)


class ConversationError(ValueError):
    pass


_AFFIRMATIVES = frozenset({
    "yes", "yes go ahead", "yes do it", "yes confirm", "yes approved",
    "confirm", "confirmed", "approve", "approved", "go ahead", "do it",
    "yes please", "confirm it", "yes send it", "send it",
})


def classify_affirmative(utterance: str) -> bool:
    """Only an unambiguous, standalone yes approves. Everything else does not."""
    normalized = " ".join(
        utterance.casefold()
        .replace(",", " ")
        .replace(".", " ")
        .replace("!", " ")
        .split()
    )
    return normalized in _AFFIRMATIVES


def approval_binding_for(task: VersionedTaskSpec) -> ApprovalBinding:
    pending = sorted(
        (
            action
            for action in task.actions.values()
            if action.requires_confirmation and action.status == "pending"
        ),
        key=lambda action: action.id,
    )
    if not pending:
        raise ConversationError("no pending consequential actions to approve")
    canonical = json.dumps(
        {
            "task_id": str(task.task_id),
            "version": task.version,
            "actions": [
                {"id": action.id, "description": action.description, "risk": action.risk}
                for action in pending
            ],
        },
        separators=(",", ":"),
        sort_keys=True,
    )
    read_back = (
        "I will "
        + "; ".join(action.description.rstrip(".") for action in pending)
        + ". Nothing else. Confirm?"
    )
    return ApprovalBinding(
        binding_hash=hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
        task_version=task.version,
        read_back=read_back,
        action_ids=[action.id for action in pending],
    )


@dataclass
class _ConversationTaskState:
    spec: VersionedTaskSpec | None = None
    binding: ApprovalBinding | None = None
    confirmed_hash: str | None = None
    ledger: list[ExecutionLedgerEvent] = field(default_factory=list)
    completed: bool = False


class ConversationToolRouter:
    """Typed tool surface: the only path from speech to task-machine effects.

    Every handler returns UI side-events first and exactly one
    conversation.tool_result last, so the Swift bridge can hand the final
    element back to the model while the companion renders the rest.
    """

    def __init__(
        self,
        fixture: OrderRescueFixture,
        compiler: Any | None = None,
    ) -> None:
        self._fixture = fixture
        self._compiler = compiler  # live/fallback compiler injected later
        self._tasks: dict[UUID, _ConversationTaskState] = {}

    def handle(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        handler = getattr(self, f"_tool_{call.tool}")
        try:
            return handler(task_id, call)
        except (OrderRescuePlanningError, ConversationError) as error:
            return [self._result(
                task_id, call, "rejected",
                error=StructuredError(
                    code=FailureCode.AMBIGUOUS_STATE, message=str(error)[:500]
                ),
            )]

    # -- tools ---------------------------------------------------------------

    def _tool_compile_task(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        transcript = self._required_str(call, "transcript")
        spec = self._compile(task_id, transcript)
        state = self._tasks.setdefault(task_id, _ConversationTaskState())
        state.spec = spec
        state.binding = None
        state.confirmed_hash = None
        return [
            make_envelope(EventType.TASK_SPEC_READY, task_id, spec),
            self._result(task_id, call, "ok", result={
                "version": spec.version,
                "objective": spec.objective,
                "action_count": len(spec.actions),
                "constraints": sorted(spec.constraints),
                "speech_summary": self._speech_summary(spec),
            }),
        ]

    def _tool_apply_patch(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        transcript = self._required_str(call, "transcript")
        state = self._require_spec(task_id)
        patch = self._patch(state.spec, transcript)
        updated = apply_plan_patch(state.spec, patch)
        state.spec = updated
        state.binding = None  # any plan change invalidates a pending approval
        state.confirmed_hash = None
        applied = updated.patch_history[-1]
        return [
            make_envelope(EventType.PLAN_PATCH_APPLIED, task_id, applied),
            make_envelope(EventType.TASK_SPEC_READY, task_id, updated),
            self._result(task_id, call, "ok", result={
                "new_version": applied.new_version,
                "added": applied.added,
                "removed": applied.removed,
                "replaced": applied.replaced,
                "preserved_count": len(applied.preserved),
                "speech_summary": (
                    f"Plan updated to version {applied.new_version}: "
                    f"{len(applied.added)} added, {len(applied.removed)} removed, "
                    f"{len(applied.preserved)} preserved."
                ),
            }),
        ]

    def _tool_get_task_state(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        state = self._require_spec(task_id)
        spec = state.spec
        return [self._result(task_id, call, "ok", result={
            "version": spec.version,
            "objective": spec.objective,
            "actions": {
                action.id: action.status for action in spec.actions.values()
            },
            "constraints": sorted(spec.constraints),
            "awaiting_approval": (
                state.binding is not None and state.confirmed_hash is None
            ),
            "completed": state.completed,
        })]

    def _tool_get_ledger(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        state = self._tasks.get(task_id)
        events = state.ledger[-10:] if state else []
        return [self._result(task_id, call, "ok", result={
            "events": [
                {
                    "type": event.event_type,
                    "where": event.where,
                    "what": event.what,
                    "found": event.found,
                }
                for event in events
            ],
        })]

    # -- helpers -------------------------------------------------------------

    def _compile(self, task_id: UUID, transcript: str) -> VersionedTaskSpec:
        if self._compiler is not None:
            return self._compiler.compile(task_id, transcript, self._fixture)
        return compile_order_rescue_task(task_id, transcript, self._fixture)

    def _patch(self, spec: VersionedTaskSpec, transcript: str):
        if self._compiler is not None:
            return self._compiler.patch(spec, transcript)
        return build_customer_choice_patch(spec.version, transcript)

    def _require_spec(self, task_id: UUID) -> _ConversationTaskState:
        state = self._tasks.get(task_id)
        if state is None or state.spec is None:
            raise ConversationError("no compiled task exists for this conversation")
        return state

    @staticmethod
    def _required_str(call: ConversationToolCall, key: str) -> str:
        value = call.arguments.get(key)
        if not isinstance(value, str) or not value.strip():
            raise ConversationError(
                f"tool {call.tool} requires a non-empty {key!r} argument"
            )
        return value

    @staticmethod
    def _speech_summary(spec: VersionedTaskSpec) -> str:
        pending = [a for a in spec.actions.values() if a.status == "pending"]
        gated = [a for a in pending if a.requires_confirmation]
        return (
            f"{spec.objective} {len(pending)} actions planned, "
            f"{len(gated)} need your approval."
        )

    def _result(
        self,
        task_id: UUID,
        call: ConversationToolCall,
        status: str,
        *,
        result: dict[str, Any] | None = None,
        error: StructuredError | None = None,
    ) -> Envelope:
        return make_envelope(
            EventType.CONVERSATION_TOOL_RESULT,
            task_id,
            ConversationToolResult(
                call_id=call.call_id,
                tool=call.tool,
                status=status,
                result=result or {},
                error=error,
            ),
        )
