from html.parser import HTMLParser
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SURFACE = REPO_ROOT / "fixtures" / "web" / "order_rescue.html"


class SurfaceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.text: list[str] = []
        self.remote_resources: list[str] = []
        self.attributes: list[dict[str, str | None]] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        values = dict(attrs)
        self.attributes.append(values)
        for key in ("src", "href"):
            value = values.get(key)
            if value and value.startswith(("http://", "https://", "//")):
                self.remote_resources.append(value)

    def handle_data(self, data: str) -> None:
        normalized = " ".join(data.split())
        if normalized:
            self.text.append(normalized)


def test_order_rescue_surface_contains_complete_grounding_evidence() -> None:
    parser = SurfaceParser()
    parser.feed(SURFACE.read_text())
    visible = " ".join(parser.text)

    for expected in (
        "Order #1842",
        "Maya Chen",
        "maya@example.com",
        "daughter’s birthday this Friday",
        "91 hours",
        "July 14 at 8:42 PM",
        "$1,840",
        "12",
        "7 units available",
        "Thursday, July 23",
        "Proactive intervention eligible",
        "No exception note or Carrier Delay tag yet",
    ):
        assert expected in visible

    assert any(attrs.get("data-order-id") == "1842" for attrs in parser.attributes)
    assert any(
        attrs.get("data-customer-id") == "cus_maya_chen"
        for attrs in parser.attributes
    )


def test_order_rescue_surface_is_credential_free_and_offline() -> None:
    parser = SurfaceParser()
    parser.feed(SURFACE.read_text())
    assert parser.remote_resources == []
