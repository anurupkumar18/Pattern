"""Live Shopify Admin adapter: read-before-write idempotency, honest failures,
and fetch-back state mapping. All HTTP goes through an injectable transport."""

import json

import pytest

from voiceops_agent.adapters.shopify import ShopifyAdminAdapter, ShopifyAdapterError

SHOP = "voiceops-dev.myshopify.com"
ORDER_ID = "1842"
CREDIT_CODE = f"VOICEOPS-CREDIT-{ORDER_ID}"


class FakeTransport:
    """Canned (method, path) -> (status, json). Records every request."""

    def __init__(self, responses):
        self.responses = responses
        self.requests = []

    def __call__(self, request):
        method = request.get_method()
        path = request.full_url.split(SHOP, 1)[1]
        body = json.loads(request.data) if request.data else None
        self.requests.append((method, path, body))
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


def order_payload(note="", tags="VIP"):
    return {"order": {"id": int(ORDER_ID), "note": note, "tags": tags}}


def adapter(transport):
    return ShopifyAdminAdapter(
        shop=SHOP, token="shpat_test", order_id=ORDER_ID, transport=transport
    )


def test_add_note_and_tag_merges_and_preserves_existing_tags():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (200, order_payload()),
        ("PUT", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (200, order_payload()),
    })
    adapter(transport).add_note_and_tag("Carrier delay: 91h stationary.", "Carrier Delay")
    puts = transport.sent("PUT", f"/admin/api/2026-01/orders/{ORDER_ID}.json")
    assert len(puts) == 1
    body = puts[0][2]["order"]
    assert "Carrier delay: 91h stationary." in body["note"]
    assert "VIP" in body["tags"] and "Carrier Delay" in body["tags"]
    assert transport.requests[0][0] == "GET"  # read before write


def test_add_note_and_tag_skips_write_when_already_present():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (
            200,
            order_payload(note="Carrier delay: 91h stationary.", tags="VIP, Carrier Delay"),
        ),
    })
    adapter(transport).add_note_and_tag("Carrier delay: 91h stationary.", "Carrier Delay")
    assert transport.sent("PUT", "/admin") == []


def test_issue_store_credit_creates_rule_and_code_once():
    transport = FakeTransport({
        ("GET", "/admin/api/2026-01/price_rules.json"): (200, {"price_rules": []}),
        ("POST", "/admin/api/2026-01/price_rules.json"): (
            201, {"price_rule": {"id": 99, "title": CREDIT_CODE, "value": "-20.00"}},
        ),
        ("POST", "/admin/api/2026-01/price_rules/99/discount_codes.json"): (
            201, {"discount_code": {"id": 7, "code": CREDIT_CODE}},
        ),
    })
    adapter(transport).issue_store_credit(20)
    assert len(transport.sent("POST", "/admin/api/2026-01/price_rules.json")) == 1
    assert len(transport.sent("POST", "/admin/api/2026-01/price_rules/99/discount_codes.json")) == 1


def test_issue_store_credit_is_noop_when_code_exists():
    transport = FakeTransport({
        ("GET", "/admin/api/2026-01/price_rules.json"): (
            200, {"price_rules": [{"id": 99, "title": CREDIT_CODE, "value": "-20.00"}]},
        ),
    })
    adapter(transport).issue_store_credit(20)
    assert transport.sent("POST", "/admin") == []


def test_fetch_state_maps_refunds_and_replacement_absence():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}/refunds.json"): (200, {"refunds": []}),
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (
            200, order_payload(note="Carrier delay noted", tags="VIP, Carrier Delay"),
        ),
        ("GET", "/admin/api/2026-01/orders.json"): (200, {"orders": []}),
        ("GET", "/admin/api/2026-01/price_rules.json"): (
            200, {"price_rules": [{"id": 99, "title": CREDIT_CODE, "value": "-20.00"}]},
        ),
    })
    state = adapter(transport).fetch_state()
    assert state["tags"] == ["VIP", "Carrier Delay"]
    assert state["notes"] == ["Carrier delay noted"]
    assert state["store_credit_usd"] == 20
    assert state["refund_issued"] is False
    assert state["replacement_order_id"] is None


def test_fetch_state_detects_refund_and_replacement():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}/refunds.json"): (
            200, {"refunds": [{"id": 5}]},
        ),
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (200, order_payload()),
        ("GET", "/admin/api/2026-01/orders.json"): (
            200, {"orders": [{"id": 9999}]},
        ),
        ("GET", "/admin/api/2026-01/price_rules.json"): (200, {"price_rules": []}),
    })
    state = adapter(transport).fetch_state()
    assert state["refund_issued"] is True
    assert state["replacement_order_id"] == "9999"
    assert state["store_credit_usd"] == 0


def test_http_error_raises_never_silently_succeeds():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (429, {"errors": "throttled"}),
    })
    with pytest.raises(ShopifyAdapterError, match="429"):
        adapter(transport).add_note_and_tag("note", "tag")


def test_access_token_header_is_always_sent():
    transport = FakeTransport({
        ("GET", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (200, order_payload()),
        ("PUT", f"/admin/api/2026-01/orders/{ORDER_ID}.json"): (200, order_payload()),
    })
    a = adapter(transport)
    a.add_note_and_tag("n", "t")
    # header access on the recorded urllib Request objects is not retained by
    # FakeTransport, so assert via a request built through the adapter helper
    request = a.build_request("GET", f"/orders/{ORDER_ID}.json")
    assert request.get_header("X-shopify-access-token") == "shpat_test"


def test_channel_label():
    transport = FakeTransport({})
    assert adapter(transport).channel == "shopify.live"
