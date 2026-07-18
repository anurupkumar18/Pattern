import json
from pathlib import Path

from voiceops_agent.evaluation import render_markdown, run_evaluation, write_report


REPO = Path(__file__).resolve().parents[2]


def native_results():
    return {
        "native_bounded_recovery": {
            "passed": True,
            "detail": "bounded retry",
            "recovery_attempted": True,
            "recovery_succeeded": True,
            "duplicate_count": 0,
        },
        "native_uncertain_never_retries": {
            "passed": True,
            "detail": "uncertain stopped",
            "recovery_attempted": False,
            "recovery_succeeded": False,
            "duplicate_count": 0,
        },
        "native_completed_duplicate_suppressed": {
            "passed": True,
            "detail": "duplicate suppressed",
            "recovery_attempted": False,
            "recovery_succeeded": False,
            "duplicate_count": 0,
        },
        "native_panic_stop_policy": {
            "passed": True,
            "detail": "panic policy",
            "recovery_attempted": False,
            "recovery_succeeded": False,
            "duplicate_count": 0,
        },
        "native_trace_evidence": {
            "passed": True,
            "detail": "trace evidence",
            "recovery_attempted": True,
            "recovery_succeeded": True,
            "duplicate_count": 0,
        },
        "native_conversation_panic_stop": {
            "passed": True,
            "detail": "conversation cancelled before sidecar teardown",
            "recovery_attempted": False,
            "recovery_succeeded": False,
            "duplicate_count": 0,
        },
    }


def test_cross_runtime_report_has_twenty_seven_cases_and_all_safety_gates():
    report = run_evaluation(
        REPO, run_id="unit-fixture", native_results=native_results())

    assert report["cases"] == 27
    assert report["passed"] == 27
    assert report["false_successes"] == 0
    assert report["duplicate_side_effects"] == 0
    assert report["provenance_coverage_rate"] == 1
    assert report["status"] == "passed"
    assert all(report["gates"].values())
    assert report["median_task_latency_ms"] is None


def test_writes_machine_and_human_readable_reports(tmp_path):
    report = run_evaluation(
        REPO, run_id="unit-fixture", native_results=native_results())

    json_path, markdown_path = write_report(report, tmp_path)

    assert json.loads(json_path.read_text())["status"] == "passed"
    markdown = markdown_path.read_text()
    assert "27/27" in markdown
    assert "False successes | 0" in markdown
    assert "not a claim of completed live acceptance testing" in markdown
    assert render_markdown(report) == markdown
