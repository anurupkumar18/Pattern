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
    ApprovalRequest,
    ConversationToolCall,
    ConversationToolResult,
    Envelope,
    EventType,
    ExecutionLedgerEvent,
    FailureCode,
    StructuredError,
    TaskCompleted,
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
from .workflows.order_rescue_execution import (
    FixtureOrderRescueExecutor,
    OrderRescueExecutionError,
    verify_order_rescue,
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
        adapters_factory: Any | None = None,
    ) -> None:
        self._fixture = fixture
        self._compiler = compiler  # live/fallback compiler injected later
        self._adapters_factory = adapters_factory
        self._tasks: dict[UUID, _ConversationTaskState] = {}

    def handle(self, task_id: UUID, call: ConversationToolCall) -> list[Envelope]:
        handler = getattr(self, f"_tool_{call.tool}")
        try:
            return handler(task_id, call)
        except (
            OrderRescuePlanningError,
            OrderRescueExecutionError,
            ConversationError,
        ) as error:
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
                "compiler": spec.provenance.get("compiler", ["deterministic"])[0],
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
                "compiler": getattr(self._compiler, "last_outcome", "deterministic"),
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

    def _tool_request_approval(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        state = self._require_spec(task_id)
        binding = approval_binding_for(state.spec)
        state.binding = binding
        state.confirmed_hash = None
        request = ApprovalRequest(
            step_id="conversation-approval",
            description=binding.read_back,
            risk="consequential",
            data_preview={
                "action_ids": binding.action_ids,
                "binding_hash": binding.binding_hash,
            },
        )
        return [
            make_envelope(EventType.APPROVAL_REQUESTED, task_id, request),
            self._result(task_id, call, "ok", result={
                "binding_hash": binding.binding_hash,
                "read_back": binding.read_back,
                "action_ids": binding.action_ids,
            }),
        ]

    def _tool_confirm_approval(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        state = self._require_spec(task_id)
        provided = self._required_str(call, "binding_hash")
        utterance = self._required_str(call, "utterance")
        if state.binding is None:
            raise ConversationError(
                "no approval is pending; the plan may have changed — request approval again"
            )
        current = approval_binding_for(state.spec)
        if provided != state.binding.binding_hash or provided != current.binding_hash:
            state.binding = None
            raise ConversationError(
                "approval hash is stale: the plan changed after the read-back; "
                "request approval again"
            )
        if not classify_affirmative(utterance):
            raise ConversationError(
                f"utterance {utterance!r} is not an unambiguous approval; "
                "nothing was authorized"
            )
        state.confirmed_hash = provided
        return [self._result(task_id, call, "ok", result={
            "approved_action_ids": state.binding.action_ids,
            "speech_summary": "Approved. Executing now.",
        })]

    def _tool_execute_plan(
        self, task_id: UUID, call: ConversationToolCall
    ) -> list[Envelope]:
        state = self._require_spec(task_id)
        if state.completed:
            raise ConversationError(
                "this task already executed; a replay cannot be authorized"
            )
        current = approval_binding_for(state.spec)
        if state.confirmed_hash is None or state.confirmed_hash != current.binding_hash:
            raise ConversationError(
                "execution requires a confirmed, current approval"
            )
        selection = self._select_adapters()
        execution = FixtureOrderRescueExecutor().execute(
            state.spec,
            self._fixture,
            approved_action_ids=set(state.binding.action_ids),
            adapters=selection.adapters,
            channel_reason=selection.reason,
        )
        report = verify_order_rescue(
            state.spec, self._fixture, execution, adapters=selection.adapters
        )
        state.ledger = report.ledger
        state.completed = True
        events = [
            make_envelope(EventType.LEDGER_EVENT, task_id, item)
            for item in report.ledger
        ]
        events.append(make_envelope(
            EventType.TASK_COMPLETED,
            task_id,
            TaskCompleted(
                state=report.state,
                summary=report.headline,
                verification=report.core_checks + report.negative_checks,
            ),
        ))
        events.append(self._result(task_id, call, "ok", result={
            "headline": report.headline,
            "state": report.state,
            "channel": selection.adapters.channel,
            "channel_reason": selection.reason,
            "checks_passed": sum(check.passed for check in report.core_checks),
            "checks_total": len(report.core_checks),
            "confirmed_not_performed": [
                check.predicate_id
                for check in report.negative_checks
                if check.passed
            ],
        }))
        return events

    # -- helpers -------------------------------------------------------------

    def _select_adapters(self):
        if self._adapters_factory is not None:
            return self._adapters_factory()
        from .adapters.live import build_order_rescue_adapters

        return build_order_rescue_adapters(self._fixture)

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
