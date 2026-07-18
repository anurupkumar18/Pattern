"""Live Slack adapter: marker-based idempotency and honest ok:false failures."""

import json

import pytest

from voiceops_agent.adapters.slack import SlackAdapter, SlackAdapterError

CHANNEL_ID = "C0912ESCAL"
ORDER_ID = "1842"
MARKER = f"[voiceops:{ORDER_ID}]"


class FakeTransport:
    def __init__(self, responses):
        self.responses = responses
        self.requests = []

    def __call__(self, request):
        method = request.get_method()
        path = request.full_url.split("slack.com", 1)[1]
        body = json.loads(request.data) if request.data else None
        self.requests.append((method, path, body, dict(request.header_items())))
        for (m, prefix), reply in self.responses.items():
            if m == method and path.startswith(prefix):
                status, payload = reply
                return status, json.dumps(payload).encode()
        raise AssertionError(f"unexpected request {method} {path}")

    def sent(self, method, prefix):
        return [
            item for item in self.requests
            if item[0] == method and item[1].startswith(prefix)
        ]


def history(texts):
    return {"ok": True, "messages": [{"text": text} for text in texts]}


def adapter(transport):
    return SlackAdapter(
        token="xoxb-test", channel_id=CHANNEL_ID, order_id=ORDER_ID,
        transport=transport,
    )


def test_post_sends_bearer_token_and_channel_and_marker():
    transport = FakeTransport({
        ("GET", "/api/conversations.history"): (200, history([])),
        ("POST", "/api/chat.postMessage"): (200, {"ok": True, "ts": "1.2"}),
    })
    adapter(transport).post_operations_message("@Sarah third carrier delay")
    posts = transport.sent("POST", "/api/chat.postMessage")
    assert len(posts) == 1
    _, _, body, headers = posts[0]
    assert body["channel"] == CHANNEL_ID
    assert "@Sarah third carrier delay" in body["text"]
    assert MARKER in body["text"]
    assert headers.get("Authorization") == "Bearer xoxb-test"


def test_duplicate_post_is_skipped_when_marker_message_exists():
    transport = FakeTransport({
        ("GET", "/api/conversations.history"): (
            200, history([f"@Sarah third carrier delay {MARKER}"]),
        ),
    })
    adapter(transport).post_operations_message("@Sarah third carrier delay")
    assert transport.sent("POST", "/api/chat.postMessage") == []


def test_ok_false_raises_never_silently_succeeds():
    transport = FakeTransport({
        ("GET", "/api/conversations.history"): (200, history([])),
        ("POST", "/api/chat.postMessage"): (
            200, {"ok": False, "error": "channel_not_found"},
        ),
    })
    with pytest.raises(SlackAdapterError, match="channel_not_found"):
        adapter(transport).post_operations_message("@Sarah escalation")


def test_fetch_returns_message_texts_without_markers():
    transport = FakeTransport({
        ("GET", "/api/conversations.history"): (
            200, history([f"@Sarah escalation {MARKER}", "unrelated chatter"]),
        ),
    })
    messages = adapter(transport).fetch_operations_messages()
    assert messages == ["@Sarah escalation", "unrelated chatter"]


def test_http_error_raises():
    transport = FakeTransport({
        ("GET", "/api/conversations.history"): (500, {"ok": False}),
    })
    with pytest.raises(SlackAdapterError, match="500"):
        adapter(transport).fetch_operations_messages()


def test_channel_label():
    assert adapter(FakeTransport({})).channel == "slack.live"
