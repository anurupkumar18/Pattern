import json
from pathlib import Path

import pytest

from voiceops_agent.grounding import (
    DeterministicMultimodalGroundingAdapter,
    FallbackGroundingAdapter,
    GroundingInput,
    GroundingProviderError,
    OpenAIMultimodalGroundingAdapter,
)
from voiceops_agent.schemas import Observation, VoiceRequest


FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "fixtures"
    / "screen"
    / "mail_deadline_observation.json"
)


def mail_observation() -> Observation:
    return Observation.model_validate_json(FIXTURE.read_text())


def request(text: str) -> VoiceRequest:
    return VoiceRequest(transcript=text, locale="en-US", confidence=1, segments=[])


def test_this_email_resolves_to_focused_active_mail_candidate():
    result = DeterministicMultimodalGroundingAdapter().resolve(
        GroundingInput(
            request=request("Using this email, create a reminder"),
            observation=mail_observation(),
        )
    )

    reference = next(ref for ref in result.references if ref.phrase == "this email")
    assert reference.candidate_id == "email-subject"
    assert reference.resolved_text == "Hackathon deadline details"
    assert reference.provenance["active_app_bundle_id"] == "com.apple.mail"
    assert reference.provenance["source"] == "accessibility"


def test_that_deadline_returns_visible_date_with_candidate_provenance():
    observation = mail_observation()
    result = DeterministicMultimodalGroundingAdapter().resolve(
        GroundingInput(
            request=request("Remind me two days before that deadline"),
            observation=observation,
        )
    )

    reference = next(ref for ref in result.references if ref.phrase == "that deadline")
    assert reference.candidate_id == "deadline-date"
    assert reference.resolved_text == "July 31, 2026"
    assert reference.provenance == {
        "capture_id": str(observation.capture_id),
        "candidate_id": "deadline-date",
        "source": "accessibility",
        "bounds": [140.0, 220.0, 240.0, 24.0],
        "active_app_bundle_id": "com.apple.mail",
    }


def test_adapter_input_carries_screenshot_and_structured_context():
    grounding_input = GroundingInput(
        request=request("What is on screen?"), observation=mail_observation()
    )

    assert grounding_input.screenshot_path == "file:///tmp/voiceops-fixture.png"
    assert len(grounding_input.candidates) == 2


def test_openai_adapter_sends_pixels_and_candidates_and_rebuilds_provenance(tmp_path):
    screenshot = tmp_path / "active-window.png"
    screenshot.write_bytes(b"test-png-bytes")
    observation = mail_observation().model_copy(
        update={"screenshot_path": screenshot.as_uri()}
    )
    captured: dict = {}

    def transport(payload: dict) -> dict:
        captured.update(payload)
        return {
            "output": [{
                "type": "message",
                "content": [{
                    "type": "output_text",
                    "text": json.dumps({
                        "references": [{
                            "phrase": "that deadline",
                            "candidate_id": "deadline-date",
                            "resolved_text": "July 31, 2026",
                            "confidence": 0.94,
                        }]
                    }),
                }],
            }]
        }

    result = OpenAIMultimodalGroundingAdapter(
        api_key="test-key", model="gpt-5.6-terra", transport=transport
    ).resolve(GroundingInput(
        request=request("Remind me two days before that deadline"),
        observation=observation,
    ))

    assert captured["model"] == "gpt-5.6-terra"
    content = captured["input"][0]["content"]
    assert content[1]["type"] == "input_image"
    assert content[1]["image_url"].startswith("data:image/png;base64,")
    assert "deadline-date" in content[0]["text"]
    assert captured["text"]["format"]["type"] == "json_schema"
    assert captured["text"]["format"]["strict"] is True
    assert result.adapter == "openai"
    assert result.references[0].provenance["candidate_id"] == "deadline-date"
    assert result.references[0].provenance["source"] == "accessibility"


def test_openai_adapter_rejects_model_invented_candidate(tmp_path):
    screenshot = tmp_path / "active-window.png"
    screenshot.write_bytes(b"test-png-bytes")
    observation = mail_observation().model_copy(
        update={"screenshot_path": screenshot.as_uri()}
    )

    adapter = OpenAIMultimodalGroundingAdapter(
        api_key="test-key",
        transport=lambda _: {
            "output": [{"type": "message", "content": [{
                "type": "output_text",
                "text": json.dumps({"references": [{
                    "phrase": "this email",
                    "candidate_id": "invented-id",
                    "resolved_text": "fake",
                    "confidence": 1,
                }]}),
            }]}]
        },
    )

    with pytest.raises(GroundingProviderError, match="unknown candidate"):
        adapter.resolve(GroundingInput(
            request=request("Using this email"), observation=observation
        ))


def test_fallback_adapter_surfaces_provider_failure_without_crashing():
    class BrokenPrimary:
        def resolve(self, grounding_input):
            raise GroundingProviderError("network unavailable")

    result = FallbackGroundingAdapter(
        primary=BrokenPrimary(), fallback=DeterministicMultimodalGroundingAdapter()
    ).resolve(GroundingInput(
        request=request("Using this email"), observation=mail_observation()
    ))

    assert result.adapter == "deterministic"
    assert result.references[0].phrase == "this email"
    assert result.warnings == ["Live VLM grounding unavailable; deterministic fallback used."]
