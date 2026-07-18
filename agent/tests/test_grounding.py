from pathlib import Path

from voiceops_agent.grounding import DeterministicMultimodalGroundingAdapter, GroundingInput
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
