"""Live Slack Web API adapter for the operations-escalation channel.

Posts carry an invisible-to-humans idempotency marker; the adapter checks the
channel history before posting so a retry can never duplicate an escalation.
Slack's ok:false envelope and HTTP errors both raise — a failed post is never
reported as sent.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Callable

Transport = Callable[[urllib.request.Request], tuple[int, bytes]]


class SlackAdapterError(RuntimeError):
    pass


def _urlopen_transport(request: urllib.request.Request) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        raise SlackAdapterError(
            f"Slack was unreachable: {str(error.reason)[:240]}"
        ) from error


class SlackAdapter:
    channel = "slack.live"

    def __init__(
        self,
        token: str,
        channel_id: str,
        order_id: str,
        transport: Transport | None = None,
    ) -> None:
        self._token = token
        self._channel_id = channel_id
        self._marker = f"[voiceops:{order_id}]"
        self._transport = transport or _urlopen_transport

    def probe(self) -> None:
        """Cheap credential check; raises on any failure."""
        self._call("POST", "/api/auth.test", {})

    def post_operations_message(self, message: str) -> None:
        marked = f"{message} {self._marker}"
        for existing in self._history():
            if self._marker in existing and message in existing:
                return
        self._call("POST", "/api/chat.postMessage", {
            "channel": self._channel_id,
            "text": marked,
        })

    def fetch_operations_messages(self) -> list[str]:
        return [
            text.replace(self._marker, "").strip()
            for text in self._history()
        ]

    def _history(self) -> list[str]:
        payload = self._call(
            "GET",
            f"/api/conversations.history?channel={self._channel_id}&limit=20",
        )
        return [
            message.get("text", "")
            for message in payload.get("messages", [])
        ]

    def _call(self, method: str, path: str, body: dict | None = None) -> dict:
        request = urllib.request.Request(
            f"https://slack.com{path}",
            data=json.dumps(body).encode("utf-8") if body is not None else None,
            headers={
                "Authorization": f"Bearer {self._token}",
                "Content-Type": "application/json; charset=utf-8",
            },
            method=method,
        )
        status, payload = self._transport(request)
        if status >= 400:
            raise SlackAdapterError(
                f"Slack returned HTTP {status} for {method} {path}"
            )
        try:
            decoded = json.loads(payload)
        except json.JSONDecodeError as error:
            raise SlackAdapterError("Slack returned invalid JSON") from error
        if not decoded.get("ok", False):
            raise SlackAdapterError(
                f"Slack rejected {method} {path}: {decoded.get('error', 'unknown')}"
            )
        return decoded
