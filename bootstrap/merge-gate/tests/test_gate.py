"""Golden-fixture tests of the merge gate (design §6.5.1, §6.5.2; D-01).

Each fixture in tests/fixtures/ scripts every GitHub response and state bucket object; the test
asserts the gate's verdict, which checks failed, the exact retry waits, and that the gate made
only GET requests and no unscripted ones.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from fakes import FIXTURES, build_gate, load_fixture

from merge_gate.checks import _accepted_shas
from merge_gate.store import MemoryStore, latest_marker

FIXTURE_NAMES = sorted(p.name for p in FIXTURES.glob("*.json"))


def test_fixtures_present() -> None:
    required = {
        "unreviewed_commit_behind_merge.json",
        "unreviewed_commit_built.json",
        "reviewed_merge_commit.json",
        "reviewed_squash_merge.json",
        "retry_then_success.json",
        "retries_exhausted.json",
        "retry_after_too_long.json",
        "machine_user_merge.json",
    }
    assert required <= set(FIXTURE_NAMES)


@pytest.mark.parametrize("name", FIXTURE_NAMES)
def test_golden_fixture(name: str) -> None:
    fixture = load_fixture(name)
    gate, transport, clock = build_gate(fixture)

    report = gate.run(fixture["mode"], fixture["sha"], fixture["env"])
    expected = fixture["expected"]

    assert transport.unscripted == [], f"unscripted requests: {transport.unscripted}"
    assert all(call.startswith("GET ") for call in transport.calls), "the gate must only read GitHub"
    assert report.passed is expected["passed"], report.to_json()
    failed = sorted(r.number for r in report.results if not r.passed)
    assert failed == expected["failed_checks"], report.to_json()
    if "sleeps" in expected:
        assert clock.sleeps == expected["sleeps"]
    if "detail_contains" in expected:
        details = " ".join(r.detail for r in report.results if not r.passed)
        assert expected["detail_contains"] in details, details
    # Deterministic report: serialises and round-trips.
    assert json.loads(report.to_json())["passed"] is expected["passed"]


def test_gate_is_deterministic() -> None:
    fixture = load_fixture("reviewed_merge_commit.json")
    first = build_gate(fixture)[0].run("apply", fixture["sha"], "dev").to_json()
    second = build_gate(fixture)[0].run("apply", fixture["sha"], "dev").to_json()
    assert first == second


def test_unknown_mode_fails_closed() -> None:
    fixture = load_fixture("reviewed_squash_merge.json")
    gate, _t, _c = build_gate(fixture)
    report = gate.run("deploy-anyway", fixture["sha"], "dev")
    assert not report.passed


def test_accepted_range_is_inclusive_and_ordered() -> None:
    shas = ["a", "b", "c", "d"]
    assert _accepted_shas(shas, [("b", "c")]) == {"b", "c"}
    assert _accepted_shas(shas, [("c", "b")]) == set()
    assert _accepted_shas(shas, [("x", "c")]) == set()


def test_marker_store_never_overwrites() -> None:
    store = MemoryStore()
    assert store.create("promotions/r/dev/abc", b"{}") is True
    assert store.create("promotions/r/dev/abc", b"{\"other\": 1}") is False
    assert store.read("promotions/r/dev/abc") == b"{}"
    assert latest_marker(store, "r", "dev") == "abc"


def test_fixture_generator_matches_committed_fixtures() -> None:
    """The committed JSON is the golden source; the generator must agree with it."""
    import make_fixtures

    for name, data in make_fixtures.SCENARIOS.items():
        committed = json.loads((Path(FIXTURES) / f"{name}.json").read_text())
        assert committed == json.loads(json.dumps(data)), name
