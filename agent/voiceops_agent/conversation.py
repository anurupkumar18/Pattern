"""Conversation-layer authority helpers: approval binding and affirmative gating.

The S2S voice layer proposes; this module decides. A spoken approval authorizes
exactly one hash over the pending consequential action set at one task version.
Any change to the set or version produces a different hash, so a stale or
misheard yes can never authorize new work.
"""

from __future__ import annotations

import hashlib
import json

from .schemas import ApprovalBinding, VersionedTaskSpec


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
