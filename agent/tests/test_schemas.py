"""Contract tests for the versioned NDJSON IPC envelope and task object schemas.

The fixture in fixtures/ipc/ is the shared wire contract: the Swift test suite
round-trips the same file, so any change here is a cross-runtime protocol change.
"""

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from voiceops_agent import schemas
from voiceops_agent.schemas import (
    EVENT_PAYLOADS,
    Envelope,
    EventType,
    TaskPlan,
    TaskStep,
    VoiceRequest,
    parse_envelope,
)

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures" / "ipc"


def load_fixture(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


def make_step(**overrides) -> dict:
    step = {
        "id": "step-1",
        "description": "Create the reminder via EventKit",
        "tool": "reminders.create",
        "arguments": {"title": "Submit hackathon project", "due": "2026-07-20T09:00:00Z"},
        "preconditions": [],
        "postconditions": [
            {
                "id": "pred-1",
                "description": "Reminder exists with normalized title",
                "expected": {"title": "Submit hackathon project"},
            }
        ],
        "risk": "reversible_write",
        "requires_confirmation": False,
        "fallback_tools": ["applescript.reminders"],
        "verifier": {"kind": "structured", "description": "Fetch reminder back through EventKit"},
    }
    step.update(overrides)
    return step


class TestEnvelopeParsing:
    def test_parses_voice_final_fixture_into_typed_payload(self):
        envelope = parse_envelope((FIXTURES / "voice_final.json").read_text())
        assert envelope.type == EventType.VOICE_FINAL
        assert isinstance(envelope.payload, VoiceRequest)
        assert envelope.payload.transcript.startswith("Using this email")
        assert len(envelope.payload.segments) == 3

    def test_roundtrip_preserves_wire_format(self):
        original = load_fixture("voice_final.json")
        envelope = parse_envelope(original)
        assert envelope.to_wire_dict() == original

    def test_rejects_unknown_event_type(self):
        message = load_fixture("voice_final.json")
        message["type"] = "voice.telepathy"
        with pytest.raises(ValidationError):
            parse_envelope(message)

    def test_rejects_unsupported_version(self):
        message = load_fixture("voice_final.json")
        message["version"] = "2.0"
        with pytest.raises(ValidationError):
            parse_envelope(message)

    def test_rejects_payload_missing_required_field(self):
        message = load_fixture("voice_final.json")
        del message["payload"]["transcript"]
        with pytest.raises(ValidationError):
            parse_envelope(message)

    def test_rejects_non_json_input(self):
        with pytest.raises(ValueError):
            parse_envelope("not json at all")


class TestTaskObjects:
    def test_task_step_applies_bounded_defaults(self):
        step = TaskStep.model_validate(make_step())
        assert step.max_attempts == 2
        assert step.timeout_seconds == 30

    def test_task_step_rejects_unknown_risk(self):
        with pytest.raises(ValidationError):
            TaskStep.model_validate(make_step(risk="yolo"))

    def test_consequential_step_must_require_confirmation(self):
        with pytest.raises(ValidationError):
            TaskStep.model_validate(make_step(risk="consequential", requires_confirmation=False))
        step = TaskStep.model_validate(
            make_step(risk="consequential", requires_confirmation=True)
        )
        assert step.requires_confirmation is True

    def test_plan_rejects_invalid_step(self):
        with pytest.raises(ValidationError):
            TaskPlan.model_validate(
                {
                    "goal": "Create a reminder from the visible email",
                    "summary": "One EventKit write with fetch-back verification",
                    "steps": [make_step(risk="yolo")],
                }
            )


class TestWireTimestamps:
    def test_generated_envelopes_use_second_precision_utc_z(self):
        """Swift's ISO8601 decoding is strict; the wire contract is whole seconds + Z."""
        from uuid import uuid4

        envelope = schemas.make_envelope(
            EventType.TASK_CANCELLED, uuid4(), schemas.TaskCancelled(reason=None)
        )
        timestamp = envelope.to_wire_dict()["timestamp"]
        assert timestamp.endswith("Z")
        assert "." not in timestamp


class TestEventRegistry:
    def test_every_protocol_event_has_a_payload_model(self):
        assert set(EVENT_PAYLOADS) == set(EventType)

    def test_export_writes_one_json_schema_per_model(self, tmp_path):
        written = schemas.export_json_schemas(tmp_path)
        assert (tmp_path / "Envelope.json").exists()
        assert (tmp_path / "TaskStep.json").exists()
        exported = json.loads((tmp_path / "Envelope.json").read_text())
        assert exported["title"] == "Envelope"
        assert len(written) >= len(EVENT_PAYLOADS)
