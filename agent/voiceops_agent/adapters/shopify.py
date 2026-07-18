"""Live Shopify Admin REST adapter for the Order Rescue channels.

Read-before-write on every mutation keeps retries idempotent; every non-2xx
response raises so a failed write can never be mistaken for success. All HTTP
flows through an injectable transport returning (status, body) so the adapter
is fully testable offline.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from datetime import UTC, datetime
from typing import Any, Callable

API_VERSION = "2026-01"

Transport = Callable[[urllib.request.Request], tuple[int, bytes]]


class ShopifyAdapterError(RuntimeError):
    pass


def _urlopen_transport(request: urllib.request.Request) -> tuple[int, bytes]:
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()
    except urllib.error.URLError as error:
        raise ShopifyAdapterError(
            f"Shopify was unreachable: {str(error.reason)[:240]}"
        ) from error


class ShopifyAdminAdapter:
    channel = "shopify.live"

    def __init__(
        self,
        shop: str,
        token: str,
        order_id: str,
        transport: Transport | None = None,
    ) -> None:
        self._shop = shop
        self._token = token
        self._order_id = order_id
        self._transport = transport or _urlopen_transport

    # -- writes --------------------------------------------------------------

    def add_note_and_tag(self, note: str, tag: str) -> None:
        order = self._get(f"/orders/{self._order_id}.json")["order"]
        existing_note = order.get("note") or ""
        tags = [item.strip() for item in (order.get("tags") or "").split(",") if item.strip()]
        note_present = note in existing_note
        tag_present = tag in tags
        if note_present and tag_present:
            return
        if not tag_present:
            tags.append(tag)
        merged_note = existing_note if note_present else (
            f"{existing_note}\n{note}".strip() if existing_note else note
        )
        self._request("PUT", f"/orders/{self._order_id}.json", {
            "order": {
                "id": int(self._order_id),
                "note": merged_note,
                "tags": ", ".join(tags),
            },
        })

    def issue_store_credit(self, amount_usd: int) -> None:
        code = self._credit_code()
        if self._find_credit_rule() is not None:
            return
        rule = self._request("POST", "/price_rules.json", {
            "price_rule": {
                "title": code,
                "target_type": "line_item",
                "target_selection": "all",
                "allocation_method": "across",
                "value_type": "fixed_amount",
                "value": f"-{amount_usd}.00",
                "customer_selection": "all",
                "starts_at": datetime.now(UTC).replace(microsecond=0).isoformat(),
            },
        })["price_rule"]
        self._request(
            "POST",
            f"/price_rules/{rule['id']}/discount_codes.json",
            {"discount_code": {"code": code}},
        )

    # -- fetch-back ----------------------------------------------------------

    def fetch_state(self) -> dict[str, Any]:
        order = self._get(f"/orders/{self._order_id}.json")["order"]
        refunds = self._get(f"/orders/{self._order_id}/refunds.json")["refunds"]
        replacements = self._get(
            "/orders.json",
            query=f"status=any&tag=VoiceOps-Replacement-{self._order_id}",
        )["orders"]
        rule = self._find_credit_rule()
        note = order.get("note") or ""
        return {
            "tags": [
                item.strip()
                for item in (order.get("tags") or "").split(",")
                if item.strip()
            ],
            "notes": [note] if note else [],
            "store_credit_usd": (
                abs(int(float(rule["value"]))) if rule is not None else 0
            ),
            "refund_issued": bool(refunds),
            "replacement_order_id": (
                str(replacements[0]["id"]) if replacements else None
            ),
        }

    # -- plumbing ------------------------------------------------------------

    def build_request(
        self, method: str, path: str, body: dict[str, Any] | None = None,
        query: str | None = None,
    ) -> urllib.request.Request:
        url = f"https://{self._shop}/admin/api/{API_VERSION}{path}"
        if query:
            url += f"?{query}"
        return urllib.request.Request(
            url,
            data=json.dumps(body).encode("utf-8") if body is not None else None,
            headers={
                "X-Shopify-Access-Token": self._token,
                "Content-Type": "application/json",
            },
            method=method,
        )

    def _credit_code(self) -> str:
        return f"VOICEOPS-CREDIT-{self._order_id}"

    def _find_credit_rule(self) -> dict[str, Any] | None:
        rules = self._get("/price_rules.json", query="limit=250")["price_rules"]
        code = self._credit_code()
        return next((rule for rule in rules if rule.get("title") == code), None)

    def _get(self, path: str, query: str | None = None) -> dict[str, Any]:
        return self._request("GET", path, query=query)

    def _request(
        self, method: str, path: str, body: dict[str, Any] | None = None,
        query: str | None = None,
    ) -> dict[str, Any]:
        status, payload = self._transport(self.build_request(method, path, body, query))
        if status >= 400:
            raise ShopifyAdapterError(
                f"Shopify returned HTTP {status} for {method} {path}: "
                f"{payload[:200]!r}"
            )
        try:
            return json.loads(payload) if payload else {}
        except json.JSONDecodeError as error:
            raise ShopifyAdapterError(
                f"Shopify returned invalid JSON for {method} {path}"
            ) from error
