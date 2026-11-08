"""Promotion checks 4 and 5 and the gate override (design §6.5.1, §6.5.3).

Phase 1 has no promotion builds, but the gate image is the same in every phase, so these paths
are tested now. No network: a scripted transport and a fake Cloud Build approval record.
"""

from __future__ import annotations

import json
from dataclasses import dataclass

from fakes import FakeClock, ScriptedTransport

from merge_gate.checks import Gate, Override
from merge_gate.github import GitHub
from merge_gate.http import RetryingHttp
from merge_gate.store import MemoryStore

OWNER = "randumbloke"
REPO = "cdmc-governance"
P = f"/repos/{OWNER}/{REPO}"
S = "b1" * 20
M = "a0" * 20
X = "c2" * 20
R = "f5" * 20  # revert merge commit
HEAD = "e4" * 20

IDENTITIES = {
    "groups": {
        "dda-release-approvers": [{"github_login": "approver", "google_account": "approver@example.com"}],
        "dda-governance-admins": [
            {"github_login": "gov1", "google_account": "gov1@example.com"},
            {"github_login": "gov2", "google_account": "gov2@example.com"},
            {"github_login": "author", "google_account": "author@example.com"},
        ],
        "dda-platform-engineers": [{"github_login": "approver", "google_account": "approver@example.com"}],
    },
    "machine_users": ["dda-scangen-bot", "dda-gate-bot"],
}


@dataclass
class FakeCloudBuild:
    account: str | None

    def approver(self, build_id: str) -> str | None:
        return self.account


def ok(body):
    return [{"status": 200, "body": body}]


def pr(number, merge_sha, author="author"):
    return {
        "number": number,
        "base": {"ref": "main"},
        "head": {"sha": HEAD},
        "user": {"login": author},
        "merged_at": "2026-11-09T01:00:00Z",
        "merge_commit_sha": merge_sha,
        "merged_by": {"login": author},
    }


def review(login, state="APPROVED", commit=HEAD):
    return {"user": {"login": login}, "state": state, "commit_id": commit}


def promotion_script(files, reviews, author="author"):
    return {
        f"GET {P}/commits/{S}/pulls": ok([pr(4, S, author)]),
        f"GET {P}/compare/{M}...{S}": ok({"status": "ahead", "commits": [{"sha": S}]}),
        f"GET {P}/commits/{S}/check-runs": ok(
            {"check_runs": [{"id": 1, "name": "ci-checks", "status": "completed", "conclusion": "success",
                             "started_at": "2026-11-09T01:00:00Z", "app": {"slug": "github-actions"}}]}
        ),
        f"GET {P}/pulls/4": ok(pr(4, S, author)),
        f"GET {P}/pulls/4/files": ok([{"filename": f} for f in files]),
        f"GET {P}/pulls/4/reviews": ok(reviews),
    }


def make_gate(script, approver, markers=("test",)):
    transport = ScriptedTransport(script)
    clock = FakeClock()
    http = RetryingHttp(transport=transport, sleep=clock.sleep, clock=clock)
    store = MemoryStore()
    store.put("bootstrap/identities.json", json.dumps(IDENTITIES).encode())
    store.put(f"promotions/{REPO}/uat/{M}", b"{}")
    for env in markers:
        store.put(f"promotions/{REPO}/{env}/{S}", b"{}")
    gate = Gate(GitHub(OWNER, REPO, "t", http), store, sleep=clock.sleep, clock=clock,
                cloud_build=FakeCloudBuild(approver))
    return gate, transport


def failed(report):
    return sorted(r.number for r in report.results if not r.passed)


def test_promotion_passes_with_independent_approver() -> None:
    gate, t = make_gate(promotion_script(["envs/uat/uat.tfvars"], []), "approver@example.com")
    report = gate.run("promotion", S, "uat", build_id="b-1")
    assert t.unscripted == []
    assert report.passed, report.to_json()


def test_promotion_fails_on_self_approval() -> None:
    gate, _ = make_gate(promotion_script(["x"], [], author="approver"), "approver@example.com")
    report = gate.run("promotion", S, "uat", build_id="b-1")
    assert 4 in failed(report)


def test_promotion_fails_for_unknown_approver() -> None:
    gate, _ = make_gate(promotion_script(["x"], []), "stranger@example.com")
    report = gate.run("promotion", S, "uat", build_id="b-1")
    assert failed(report) == [4]


def test_promotion_fails_without_previous_marker() -> None:
    gate, _ = make_gate(promotion_script(["x"], []), "approver@example.com", markers=())
    report = gate.run("promotion", S, "uat", build_id="b-1")
    assert failed(report) == [5]


def test_rule_table_needs_two_independent_governance_approvals() -> None:
    files = ["classification/infotype_rules.yaml"]
    # The author's own approval and a stale approval do not count: only gov1 counts.
    reviews = [review("author"), review("gov1"), review("gov2", commit="0" * 40)]
    gate, _ = make_gate(promotion_script(files, reviews), "approver@example.com")
    assert failed(gate.run("promotion", S, "uat", build_id="b-1")) == [4]

    reviews = [review("gov1"), review("gov2")]
    gate, _ = make_gate(promotion_script(files, reviews), "approver@example.com")
    assert gate.run("promotion", S, "uat", build_id="b-1").passed


# --- gate override -----------------------------------------------------------------------------


def override_script(author="someone", pusher="someone", revert_merged=True):
    return {
        f"GET {P}/commits/{X}": ok({"sha": X, "parents": [{"sha": M}]}),
        f"GET {P}/compare/{M}...{X}": ok(
            {"status": "ahead", "commits": [{"sha": X, "author": {"login": author}, "committer": {"login": author}}]}
        ),
        f"GET {P}/activity": ok([{"after": X, "actor": {"login": pusher}}]),
        f"GET {P}/pulls/21": ok(
            {**pr(21, R), "merged_at": "2026-11-09T02:00:00Z" if revert_merged else None}
        ),
        f"GET {P}/compare/{X}...{R}": ok({"status": "ahead", "commits": [{"sha": R}]}),
    }


def make_override(script, approver):
    transport = ScriptedTransport(script)
    clock = FakeClock()
    http = RetryingHttp(transport=transport, sleep=clock.sleep, clock=clock)
    store = MemoryStore()
    store.put("bootstrap/identities.json", json.dumps(IDENTITIES).encode())
    return Override(GitHub(OWNER, REPO, "t", http), store, FakeCloudBuild(approver)), store


def test_override_accepts_and_records_range() -> None:
    override, store = make_override(override_script(), "approver@example.com")
    ok_, detail = override.run(X, X, 21, "reverted in #21", "b-9")
    assert ok_, detail
    record = json.loads(store.read(f"gate/accepted/{REPO}/{X}..{X}"))
    assert record["revert_pr"] == 21 and record["approver"] == "approver@example.com"


def test_override_refuses_author_as_approver() -> None:
    override, _ = make_override(override_script(author="approver"), "approver@example.com")
    assert override.run(X, X, 21, "r", "b-9")[0] is False


def test_override_refuses_pusher_as_approver() -> None:
    override, _ = make_override(override_script(pusher="approver"), "approver@example.com")
    assert override.run(X, X, 21, "r", "b-9")[0] is False


def test_override_refuses_unmerged_revert() -> None:
    override, _ = make_override(override_script(revert_merged=False), "approver@example.com")
    assert override.run(X, X, 21, "r", "b-9")[0] is False


def test_override_refuses_non_platform_engineer() -> None:
    override, _ = make_override(override_script(), "gov1@example.com")
    assert override.run(X, X, 21, "r", "b-9")[0] is False
