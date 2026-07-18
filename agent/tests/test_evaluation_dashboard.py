from html.parser import HTMLParser
import json
from pathlib import Path

from voiceops_agent.evaluation_dashboard import render_dashboard, write_dashboard


REPO = Path(__file__).resolve().parents[2]


class ResourceParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.remote_resources: list[str] = []
        self.text: list[str] = []

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        values = dict(attrs)
        for key in ("src", "href"):
            value = values.get(key)
            if value and value.startswith(("http://", "https://", "//")):
                self.remote_resources.append(value)

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.text.append(" ".join(data.split()))


def reports() -> tuple[dict, dict]:
    cross = json.loads((REPO / "evals/reports/latest.json").read_text())
    order = json.loads((REPO / "evals/order_rescue/report.json").read_text())
    return cross, order


def test_dashboard_contains_judge_metrics_and_no_remote_resources() -> None:
    html = render_dashboard(*reports())
    parser = ResourceParser()
    parser.feed(html)
    visible = " ".join(parser.text)

    assert parser.remote_resources == []
    assert 'data-gate-status="passed"' in html
    assert "40 of 40 checks passed" in visible
    assert "False successes 0 zero tolerated" in visible
    assert "Stop leakage 0 post-stop side effects" in visible
    assert "Patch accuracy 100%" in visible
    assert "Golden 2/2 ORDER RESCUE COMPLETED — 5/5 CHECKS PASSED" in visible
    assert "Offline and replayable" in visible


def test_dashboard_escapes_report_evidence_and_writes_output(tmp_path: Path) -> None:
    cross, order = reports()
    order["results"][0]["evidence"] = "<script>alert('no')</script>"
    cross_path = tmp_path / "cross.json"
    order_path = tmp_path / "order.json"
    output = tmp_path / "dashboard.html"
    cross_path.write_text(json.dumps(cross))
    order_path.write_text(json.dumps(order))

    assert write_dashboard(cross_path, order_path, output) == output
    html = output.read_text()
    assert "<script>alert" not in html
    assert "&lt;script&gt;alert" in html
