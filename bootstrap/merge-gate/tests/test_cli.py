"""The CLI fails closed on missing configuration, before any network call (design §6.5.2)."""

from __future__ import annotations

import pytest

from merge_gate.cli import main

ENV = ["GITHUB_OWNER", "GITHUB_OWNER_TYPE", "STATE_BUCKET", "GATE_PROJECT", "GATE_REGION", "GATE_TOKEN", "BUILD_ID"]


@pytest.fixture(autouse=True)
def clean_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in ENV:
        monkeypatch.delenv(name, raising=False)


def test_check_without_state_bucket_fails_closed() -> None:
    assert main(["check", "--mode", "apply", "--repo", "dda-customer", "--sha", "b1" * 20, "--env", "dev"]) == 1


def test_check_without_gate_token_fails_closed(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("STATE_BUCKET", "tfstate-pltfrm-ngnrng")
    monkeypatch.setenv("GITHUB_OWNER", "randumbloke")
    assert main(["check", "--mode", "apply", "--repo", "dda-customer", "--sha", "b1" * 20, "--env", "dev"]) == 1


def test_override_rejects_malformed_range(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("STATE_BUCKET", "tfstate-pltfrm-ngnrng")
    assert main(["override", "--repo", "r", "--range", "abc", "--revert-pr", "1", "--reason", "x"]) == 1
