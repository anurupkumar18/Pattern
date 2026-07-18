#!/usr/bin/env python3
"""Bridge stdin/stdout prompts to Cactus's OpenAI-compatible local server."""

from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request


def main() -> int:
    prompt = sys.stdin.read()
    if not prompt.strip():
        print("Cactus prompt must not be empty", file=sys.stderr)
        return 2

    endpoint = os.environ.get(
        "CACTUS_ENDPOINT",
        "http://127.0.0.1:8080/v1/chat/completions",
    )
    model = os.environ.get("CACTUS_MODEL", "google/gemma-4-E2B-it")
    timeout = float(os.environ.get("CACTUS_TIMEOUT_SECONDS", "120"))
    system_prompt = os.environ.get(
        "CACTUS_SYSTEM_PROMPT",
        (
            "Follow the routing contract in the user message exactly and return "
            "only its JSON object. For send or dictate, payload.text contains "
            "only the requested message, never the control phrase or target "
            "reference. Stopping or pausing an agent is interrupt; listen_ctl "
            "only changes global voice listening. Preserve every explicitly "
            "spoken spawn name and initial task."
        ),
    )
    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": prompt},
            ],
            "temperature": float(os.environ.get("CACTUS_TEMPERATURE", "0")),
            "max_tokens": int(os.environ.get("CACTUS_MAX_TOKENS", "200")),
            "stream": False,
        }
    ).encode("utf-8")
    request = urllib.request.Request(
        endpoint,
        data=payload,
        headers={"content-type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = json.load(response)
        completion = body["choices"][0]["message"]["content"]
        if not isinstance(completion, str):
            raise ValueError("Cactus response content is not a string")
        print(completion)
        return 0
    except (
        KeyError,
        IndexError,
        TypeError,
        ValueError,
        urllib.error.HTTPError,
        urllib.error.URLError,
    ) as error:
        print(f"Cactus completion failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
