"""Read-only pre-demo health probe for credential-gated commerce adapters.

Run from agent/: uv run python -m tests.live_shopify_probe
The command never writes and never prints credentials. A fixture selection is
reported as a failed live-readiness result so it cannot be mistaken for a
successful sandbox check.
"""

from __future__ import annotations

import json

from voiceops_agent.adapters.live import build_order_rescue_adapters
from voiceops_agent.main import load_order_rescue_fixture


def main() -> None:
    selection = build_order_rescue_adapters(load_order_rescue_fixture())
    payload = {
        "channel": selection.adapters.channel,
        "reason": selection.reason,
        "shopify": selection.adapters.fetch_shopify_state(),
        "slack_message_count": len(selection.adapters.fetch_operations_messages()),
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    if selection.adapters.channel == "fixture":
        raise SystemExit(
            "live commerce is not ready; fix the labeled credential/health reason above"
        )


if __name__ == "__main__":
    main()
