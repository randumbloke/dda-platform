"""Generates the golden fixtures in tests/fixtures/. Run once after changing a scenario:

    uv run python tests/make_fixtures.py

The JSON files are committed; the tests read only the JSON.
"""

from __future__ import annotations

import json
from pathlib import Path

OWNER = "randumbloke"
REPO = "dda-customer"
P = f"/repos/{OWNER}/{REPO}"
M = "a0" * 20  # last dev marker
M_OLD = "9f" * 20  # an older marker
S = "b1" * 20  # built commit
X = "c2" * 20  # unreviewed direct push
B1 = "d3" * 20  # branch commit 1
B2 = "e4" * 20  # branch commit 2
PERSON = "randumbloke"

IDENTITIES = {
    "generated_by": "bootstrap",
    "groups": {
        "dda-platform-engineers": [{"github_login": PERSON, "google_account": "mikegyoung@google.com"}],
    },
    "machine_users": ["dda-scangen-bot", "dda-gate-bot"],
}


def ok(body, headers=None):
    return {"status": 200, "body": body, "headers": headers or {}}


def pr(number, merge_sha, merged_by=PERSON):
    return {
        "number": number,
        "base": {"ref": "main"},
        "head": {"sha": B2},
        "user": {"login": PERSON},
        "merged_at": "2026-11-09T01:00:00Z",
        "merge_commit_sha": merge_sha,
        "merged_by": {"login": merged_by},
    }


def run(status="completed", conclusion="success", slug="github-actions", run_id=1):
    return {
        "id": run_id,
        "name": "ci-checks",
        "status": status,
        "conclusion": conclusion if status == "completed" else None,
        "started_at": f"2026-11-09T01:0{run_id}:00Z",
        "app": {"slug": slug},
    }


def ci(*runs):
    return ok({"total_count": len(runs), "check_runs": list(runs)})


def compare(status, commits, headers=None):
    return ok({"status": status, "commits": [{"sha": c} for c in commits]}, headers)


def base_store(marker=M, identities=True):
    store = {f"promotions/{REPO}/dev/{marker}": {"time": "2026-11-08T00:00:00Z", "data": {"sha": marker}}}
    if identities:
        store["bootstrap/identities.json"] = {"data": IDENTITIES}
    return store


def scenario(description, responses, expected, sha=S, store=None, **extra):
    return {
        "description": description,
        "owner": OWNER,
        "repo": REPO,
        "mode": "apply",
        "env": "dev",
        "sha": sha,
        "store": store if store is not None else base_store(),
        "responses": responses,
        "expected": expected,
        **extra,
    }


def squash_responses(merged_by=PERSON):
    return {
        f"GET {P}/commits/{S}/pulls": [ok([pr(9, S, merged_by)])],
        f"GET {P}/compare/{M}...{S}": [compare("ahead", [S])],
        f"GET {P}/commits/{S}/check-runs": [ci(run())],
        f"GET {P}/pulls/9": [ok(pr(9, S, merged_by))],
    }


SCENARIOS = {
    "reviewed_squash_merge": scenario(
        "Squash merge of pull request 9: the squash commit is the merge commit. Passes.",
        squash_responses(),
        {"passed": True, "failed_checks": []},
    ),
    "reviewed_merge_commit": scenario(
        "Merge commit of pull request 7 with two branch commits; every commit maps to PR 7. Passes.",
        {
            f"GET {P}/commits/{S}/pulls": [ok([pr(7, S)])],
            f"GET {P}/compare/{M}...{S}": [compare("ahead", [B1, B2, S])],
            f"GET {P}/commits/{B1}/pulls": [ok([pr(7, S)])],
            f"GET {P}/commits/{B2}/pulls": [ok([pr(7, S)])],
            f"GET {P}/commits/{S}/check-runs": [ci(run())],
            f"GET {P}/pulls/7": [ok(pr(7, S))],
        },
        {"passed": True, "failed_checks": []},
    ),
    "unreviewed_commit_behind_merge": scenario(
        "A direct push X is hidden behind the later merge of PR 12. Check 2 fails.",
        {
            f"GET {P}/commits/{S}/pulls": [ok([pr(12, S)])],
            f"GET {P}/compare/{M}...{S}": [compare("ahead", [X, S])],
            f"GET {P}/commits/{X}/pulls": [ok([])],
            f"GET {P}/commits/{S}/check-runs": [ci(run())],
            f"GET {P}/pulls/12": [ok(pr(12, S))],
        },
        {"passed": False, "failed_checks": [2], "detail_contains": X[:12]},
    ),
    "unreviewed_commit_built": scenario(
        "The built commit X is a direct push to main: checks 1 and 2 fail.",
        {
            f"GET {P}/commits/{X}/pulls": [ok([])],
            f"GET {P}/compare/{M}...{X}": [compare("ahead", [X])],
            f"GET {P}/commits/{X}/check-runs": [ci(run())],
        },
        {"passed": False, "failed_checks": [1, 2]},
        sha=X,
    ),
    "unreviewed_commit_accepted_range": scenario(
        "As unreviewed_commit_behind_merge, but X..X is an accepted range (gate override). Passes.",
        {
            f"GET {P}/commits/{S}/pulls": [ok([pr(12, S)])],
            f"GET {P}/compare/{M}...{S}": [compare("ahead", [X, S])],
            f"GET {P}/commits/{S}/check-runs": [ci(run())],
            f"GET {P}/pulls/12": [ok(pr(12, S))],
        },
        {"passed": True, "failed_checks": []},
        store={**base_store(), f"gate/accepted/{REPO}/{X}..{X}": {"data": {"reason": "reverted"}}},
    ),
    "machine_user_merge": scenario(
        "PR 9 was merged by dda-scangen-bot (P6-16): check 6 fails.",
        squash_responses(merged_by="dda-scangen-bot"),
        {"passed": False, "failed_checks": [6], "detail_contains": "dda-scangen-bot"},
    ),
    "retry_then_success": scenario(
        "Associated pulls: 502, then 429 with Retry-After 3, then a timeout, then 200. Waits 2, 3, 8 s.",
        {
            **squash_responses(),
            f"GET {P}/commits/{S}/pulls": [
                {"status": 502},
                {"status": 429, "headers": {"Retry-After": "3"}},
                {"error": "timed out"},
                ok([pr(9, S)]),
            ],
        },
        {"passed": True, "failed_checks": [], "sleeps": [2, 3, 8]},
    ),
    "retries_exhausted": scenario(
        "Associated pulls return 503 four times: waits 2, 4, 8 s then fails closed.",
        {**squash_responses(), f"GET {P}/commits/{S}/pulls": [{"status": 503}]},
        {"passed": False, "failed_checks": [0], "sleeps": [2, 4, 8], "detail_contains": "retries exhausted"},
    ),
    "retry_after_too_long": scenario(
        "Secondary rate limit with Retry-After 120 s (over 60 s): fails closed without waiting.",
        {**squash_responses(), f"GET {P}/commits/{S}/pulls": [{"status": 403, "headers": {"Retry-After": "120"}}]},
        {"passed": False, "failed_checks": [0], "sleeps": [], "detail_contains": "Retry-After"},
    ),
    "primary_rate_limit_reset": scenario(
        "403 with X-RateLimit-Remaining 0 and a reset 5 s away: waits 5 s, then passes.",
        {
            **squash_responses(),
            f"GET {P}/commits/{S}/pulls": [
                {"status": 403, "headers": {"X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1000005"}},
                ok([pr(9, S)]),
            ],
        },
        {"passed": True, "failed_checks": [], "sleeps": [5]},
    ),
    "not_found_fails_closed": scenario(
        "A 404 from compare is not retryable: fails closed at once.",
        {**squash_responses(), f"GET {P}/compare/{M}...{S}": [{"status": 404}]},
        {"passed": False, "failed_checks": [0], "sleeps": []},
    ),
    "ci_from_other_app": scenario(
        "The latest ci-checks run was posted by another app: check 3 fails.",
        {**squash_responses(), f"GET {P}/commits/{S}/check-runs": [ci(run(run_id=1), run(slug="impostor", run_id=2))]},
        {"passed": False, "failed_checks": [3], "detail_contains": "impostor"},
    ),
    "ci_failed": scenario(
        "ci-checks concluded failure: check 3 fails.",
        {**squash_responses(), f"GET {P}/commits/{S}/check-runs": [ci(run(conclusion="failure"))]},
        {"passed": False, "failed_checks": [3]},
    ),
    "ci_pending_then_success": scenario(
        "ci-checks in progress, then success: the gate polls once (30 s).",
        {**squash_responses(), f"GET {P}/commits/{S}/check-runs": [ci(run(status="in_progress")), ci(run())]},
        {"passed": True, "failed_checks": [], "sleeps": [30]},
    ),
    "ci_timeout": scenario(
        "ci-checks never completes within ci_wait_minutes (1 here): check 3 fails.",
        {**squash_responses(), f"GET {P}/commits/{S}/check-runs": [ci(run(status="in_progress"))]},
        {"passed": False, "failed_checks": [3], "sleeps": [30, 30]},
        ci_wait_minutes=1,
    ),
    "rollback_behind_marker": scenario(
        "The built commit is older than the dev marker (compare status behind): check 2 fails.",
        {**squash_responses(), f"GET {P}/compare/{M}...{S}": [compare("behind", [])]},
        {"passed": False, "failed_checks": [2], "detail_contains": "behind"},
    ),
    "no_marker": scenario(
        "No dev marker yet (stage 2 not applied): check 2 fails.",
        squash_responses(),
        {"passed": False, "failed_checks": [2]},
        store={"bootstrap/identities.json": {"data": IDENTITIES}},
    ),
    "newest_marker_used": scenario(
        "Two markers; the gate compares from the most recently created one.",
        squash_responses(),
        {"passed": True, "failed_checks": []},
        store={
            **base_store(),
            f"promotions/{REPO}/dev/{M_OLD}": {"time": "2026-11-01T00:00:00Z", "data": {"sha": M_OLD}},
        },
    ),
    "compare_paginated": scenario(
        "Compare over two pages (Link rel=next); all commits map to PR 7. Passes.",
        {
            f"GET {P}/commits/{S}/pulls": [ok([pr(7, S)])],
            f"GET {P}/compare/{M}...{S}": [
                compare("ahead", [B1], {"Link": f'<https://api.github.com{P}/compare/{M}...{S}?per_page=100&page=2>; rel="next"'}),
                compare("ahead", [S]),
            ],
            f"GET {P}/commits/{B1}/pulls": [ok([pr(7, S)])],
            f"GET {P}/commits/{S}/check-runs": [ci(run())],
            f"GET {P}/pulls/7": [ok(pr(7, S))],
        },
        {"passed": True, "failed_checks": []},
    ),
    "identities_missing": scenario(
        "bootstrap/identities.json cannot be read: fails closed.",
        squash_responses(),
        {"passed": False, "failed_checks": [0], "detail_contains": "identities.json"},
        store=base_store(identities=False),
    ),
}


def main() -> None:
    out = Path(__file__).parent / "fixtures"
    out.mkdir(exist_ok=True)
    for name, data in SCENARIOS.items():
        (out / f"{name}.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(SCENARIOS)} fixtures to {out}")


if __name__ == "__main__":
    main()
