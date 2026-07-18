"""Ground deictic speech against one task-scoped screen observation.

The adapter boundary is deliberately multimodal even though the default
implementation is deterministic: a provider receives both the ephemeral
screenshot path and the normalized accessibility candidates. A VLM adapter can
replace the fallback without changing orchestration or wire contracts.

Observed labels and values are data only. This module extracts references from
them; it never treats on-screen text as a goal, permission, or instruction.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Protocol

from .schemas import (
    GroundingResult,
    Observation,
    ResolvedReference,
    UIElementCandidate,
    VoiceRequest,
)


@dataclass(frozen=True)
class GroundingInput:
    request: VoiceRequest
    observation: Observation

    @property
    def screenshot_path(self) -> str | None:
        return self.observation.screenshot_path

    @property
    def candidates(self) -> tuple[UIElementCandidate, ...]:
        return tuple(self.observation.elements)


class MultimodalGroundingAdapter(Protocol):
    """Provider seam: implementations receive pixels plus semantic context."""

    def resolve(self, grounding_input: GroundingInput) -> GroundingResult: ...


_DATE_PATTERN = re.compile(
    r"(?:"
    r"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|"
    r"Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|"
    r"Dec(?:ember)?)\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?"
    r"|\d{1,2}[/-]\d{1,2}(?:[/-]\d{2,4})?"
    r"|\d{4}-\d{2}-\d{2}"
    r")",
    re.IGNORECASE,
)


class DeterministicMultimodalGroundingAdapter:
    """Offline-safe semantic fallback and golden-fixture implementation.

    It intentionally resolves only high-confidence MVP references. Ambiguous
    cases return no reference so later orchestration can ask one clarification
    instead of inventing screen state.
    """

    def resolve(self, grounding_input: GroundingInput) -> GroundingResult:
        transcript = grounding_input.request.transcript.casefold()
        observation = grounding_input.observation
        references: list[ResolvedReference] = []

        if "this email" in transcript:
            email = self._resolve_email(observation)
            if email is not None:
                references.append(
                    self._reference("this email", email, observation, confidence=0.99)
                )

        deadline_phrase = next(
            (phrase for phrase in ("that deadline", "the deadline") if phrase in transcript),
            None,
        )
        if deadline_phrase:
            deadline = self._resolve_deadline(observation)
            if deadline is not None:
                references.append(
                    self._reference(
                        deadline_phrase, deadline, observation, confidence=0.98,
                        resolved_text=self._visible_date(deadline),
                    )
                )

        return GroundingResult(references=references)

    @staticmethod
    def _resolve_email(observation: Observation) -> UIElementCandidate | None:
        if observation.active_app.bundle_id.casefold() != "com.apple.mail":
            return None
        subject = next(
            (
                candidate
                for candidate in observation.elements
                if "subject" in " ".join(
                    filter(
                        None,
                        (
                            candidate.label,
                            *candidate.stable_attributes.values(),
                        ),
                    )
                ).casefold()
            ),
            None,
        )
        if subject is not None:
            return subject
        if observation.focused_element_id:
            focused = next(
                (
                    candidate
                    for candidate in observation.elements
                    if candidate.id == observation.focused_element_id
                ),
                None,
            )
            if focused is not None:
                return focused
        return observation.elements[0] if observation.elements else None

    @staticmethod
    def _resolve_deadline(observation: Observation) -> UIElementCandidate | None:
        scored: list[tuple[int, UIElementCandidate]] = []
        for candidate in observation.elements:
            visible = " ".join(filter(None, (candidate.label, candidate.value)))
            stable = " ".join(candidate.stable_attributes.values())
            date = _DATE_PATTERN.search(visible)
            if date is None:
                continue
            score = 2
            if "deadline" in f"{visible} {stable}".casefold():
                score += 3
            if candidate.source in ("accessibility", "dom"):
                score += 1
            scored.append((score, candidate))
        if not scored:
            return None
        return max(scored, key=lambda item: item[0])[1]

    @staticmethod
    def _visible_date(candidate: UIElementCandidate) -> str:
        visible = " ".join(filter(None, (candidate.value, candidate.label)))
        match = _DATE_PATTERN.search(visible)
        return match.group(0) if match else visible

    @staticmethod
    def _reference(
        phrase: str,
        candidate: UIElementCandidate,
        observation: Observation,
        *,
        confidence: float,
        resolved_text: str | None = None,
    ) -> ResolvedReference:
        text = resolved_text or candidate.label or candidate.value or observation.window.title
        return ResolvedReference(
            phrase=phrase,
            candidate_id=candidate.id,
            resolved_text=text,
            confidence=min(confidence, candidate.confidence),
            provenance={
                "capture_id": str(observation.capture_id),
                "candidate_id": candidate.id,
                "source": candidate.source,
                "bounds": list(candidate.bounds),
                "active_app_bundle_id": observation.active_app.bundle_id,
            },
        )
