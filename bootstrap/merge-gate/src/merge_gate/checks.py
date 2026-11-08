"""The merge gate checks (design §6.5.1) and the gate override (§6.5.3).

Deterministic (D-01): every decision is a pure function of GitHub REST responses, state bucket
objects and the build's approval record. The gate never writes to GitHub. Any error, timeout,
exhausted retry, unreadable object or unknown identity fails the gate (§6.5.2).
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

from merge_gate.github import GitHub
from merge_gate.http import GateError
from merge_gate.store import (
    CloudBuild,
    Identities,
    Store,
    accepted_ranges,
    latest_marker,
    load_identities,
    marker_exists,
)

MAIN = "main"
CI_CHECK_NAME = "ci-checks"
CI_APP_SLUG = "github-actions"
CI_POLL_SECONDS = 30
RULE_TABLE_PATH = "classification/infotype_rules.yaml"
GOVERNANCE_ADMINS = "dda-governance-admins"
PLATFORM_ENGINEERS = "dda-platform-engineers"
PREVIOUS_ENV = {"uat": "test", "prod": "uat"}


@dataclass
class CheckResult:
    number: int
    name: str
    passed: bool
    detail: str
    evidence: dict[str, Any] = field(default_factory=dict)


@dataclass
class GateReport:
    mode: str
    repo: str
    sha: str
    results: list[CheckResult] = field(default_factory=list)

    @property
    def passed(self) -> bool:
        return bool(self.results) and all(r.passed for r in self.results)

    def to_json(self) -> str:
        return json.dumps(
            {
                "mode": self.mode,
                "repo": self.repo,
                "sha": self.sha,
                "passed": self.passed,
                "results": [r.__dict__ for r in self.results],
            },
            indent=2,
            sort_keys=True,
        )


def _merged_into_main(pr: dict[str, Any]) -> bool:
    return (pr.get("base") or {}).get("ref") == MAIN and bool(pr.get("merged_at"))


@dataclass
class Gate:
    github: GitHub
    store: Store
    owner_type: str = "user"
    ci_wait_minutes: int = 20
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.monotonic
    cloud_build: CloudBuild | None = None
    log: Callable[[str], None] = lambda _m: None

    # --- check 1 ----------------------------------------------------------------------------

    def check_merge_commit(self, sha: str) -> tuple[CheckResult, list[int]]:
        pulls = self.github.pulls_for_commit(sha)
        matching = [p for p in pulls if _merged_into_main(p) and p.get("merge_commit_sha") == sha]
        if not matching:
            return (
                CheckResult(
                    1,
                    "merge commit of a merged pull request into main",
                    False,
                    f"{sha} is not the merge commit of a pull request merged into main (direct push?)",
                    {"associated_pulls": [p.get("number") for p in pulls]},
                ),
                [],
            )
        numbers = sorted({int(p["number"]) for p in matching})
        return (
            CheckResult(1, "merge commit of a merged pull request into main", True,
                        f"merge commit of pull request(s) {numbers}", {"pulls": numbers}),
            numbers,
        )

    # --- check 2 ----------------------------------------------------------------------------

    def check_range(self, sha: str, env: str) -> tuple[CheckResult, list[int]]:
        name = "every commit since the last marker came through a merged pull request"
        marker = latest_marker(self.store, self.github.repo, env)
        if marker is None:
            return CheckResult(2, name, False, f"no marker for {env}; stage 2 writes the first markers"), []
        status, commits = self.github.compare(marker, sha)
        if status not in ("ahead", "identical"):
            return (
                CheckResult(2, name, False,
                            f"compare {marker[:12]}...{sha[:12]} is {status!r}; an older or diverged commit cannot deploy (a rollback is a revert pull request)",
                            {"marker": marker, "status": status}),
                [],
            )
        shas = [c["sha"] for c in commits]
        accepted = _accepted_shas(shas, accepted_ranges(self.store, self.github.repo))
        unreviewed: list[str] = []
        pulls_in_range: set[int] = set()
        for c in shas:
            if c in accepted:
                continue
            merged = [p for p in self.github.pulls_for_commit(c) if _merged_into_main(p)]
            if not merged:
                unreviewed.append(c)
            pulls_in_range.update(int(p["number"]) for p in merged)
        evidence = {"marker": marker, "status": status, "commits": len(shas),
                    "accepted": sorted(accepted), "pulls": sorted(pulls_in_range)}
        if unreviewed:
            evidence["unreviewed"] = unreviewed
            return (
                CheckResult(2, name, False,
                            f"{len(unreviewed)} commit(s) on main did not come through a merged pull request: {', '.join(u[:12] for u in unreviewed)}",
                            evidence),
                sorted(pulls_in_range),
            )
        return CheckResult(2, name, True, f"{len(shas)} commit(s) since marker {marker[:12]}", evidence), sorted(pulls_in_range)

    # --- check 3 ----------------------------------------------------------------------------

    def check_ci(self, sha: str) -> CheckResult:
        name = "ci-checks passed, reported by GitHub Actions"
        deadline = self.clock() + self.ci_wait_minutes * 60
        while True:
            runs = self.github.check_runs(sha, CI_CHECK_NAME)
            runs = [r for r in runs if r.get("name") == CI_CHECK_NAME]
            if runs:
                latest = max(runs, key=lambda r: (r.get("started_at") or "", int(r.get("id") or 0)))
                app = (latest.get("app") or {}).get("slug")
                ev = {"check_run": latest.get("id"), "app": app, "status": latest.get("status"),
                      "conclusion": latest.get("conclusion")}
                if app != CI_APP_SLUG:
                    return CheckResult(3, name, False, f"latest ci-checks run is from app {app!r}, not {CI_APP_SLUG}", ev)
                if latest.get("status") == "completed":
                    if latest.get("conclusion") == "success":
                        return CheckResult(3, name, True, "ci-checks succeeded", ev)
                    return CheckResult(3, name, False, f"ci-checks concluded {latest.get('conclusion')!r}", ev)
            if self.clock() >= deadline:
                return CheckResult(3, name, False, f"ci-checks did not complete within {self.ci_wait_minutes} minutes")
            self.log("waiting for ci-checks")
            self.sleep(CI_POLL_SECONDS)

    # --- check 4 (promotion) ------------------------------------------------------------------

    def check_independent_approval(self, build_id: str, pulls: list[int], identities: Identities) -> CheckResult:
        name = "independent approver; two governance approvals for a rule table change"
        if self.cloud_build is None:
            raise GateError("check 4 needs the Cloud Build approval record")
        approver_account = self.cloud_build.approver(build_id)
        if not approver_account:
            return CheckResult(4, name, False, "the build has no approver")
        approver = identities.login_for_account(approver_account)
        if not approver:
            return CheckResult(4, name, False, f"approver {approver_account} has no entry in identities.json")
        admins = identities.group_logins(GOVERNANCE_ADMINS)
        for number in pulls:
            pr = self.github.pull(number)
            author = ((pr.get("user") or {}).get("login") or "").lower()
            if author == approver.lower():
                return CheckResult(4, name, False, f"approver {approver} authored pull request {number}")
            files = [f.get("filename") for f in self.github.pull_files(number)]
            if RULE_TABLE_PATH in files:
                head = (pr.get("head") or {}).get("sha")
                approvers: set[str] = set()
                for review in self.github.pull_reviews(number):
                    login = ((review.get("user") or {}).get("login") or "").lower()
                    if review.get("state") != "APPROVED" or review.get("commit_id") != head or login == author:
                        continue
                    if login not in admins:
                        continue
                    if self.owner_type == "organization":
                        org = self.github.owner
                        if not self.github.team_member(org, GOVERNANCE_ADMINS, login):
                            return CheckResult(4, name, False, f"{login} is in identities.json but not in team {GOVERNANCE_ADMINS}")
                    approvers.add(login)
                if len(approvers) < 2:
                    return CheckResult(4, name, False, f"pull request {number} changes {RULE_TABLE_PATH} with {len(approvers)} independent governance approval(s); 2 needed")
        return CheckResult(4, name, True, f"approver {approver} is independent of {len(pulls)} pull request(s)")

    # --- check 5 (promotion) ------------------------------------------------------------------

    def check_previous_marker(self, sha: str, env: str) -> CheckResult:
        name = "previous environment's marker exists"
        prev = PREVIOUS_ENV.get(env)
        if prev is None:
            return CheckResult(5, name, False, f"no previous environment defined for {env}")
        if marker_exists(self.store, self.github.repo, prev, sha):
            return CheckResult(5, name, True, f"{prev} marker present for {sha[:12]}")
        return CheckResult(5, name, False, f"no {prev} marker for {sha[:12]}; environments cannot be skipped")

    # --- check 6 ----------------------------------------------------------------------------

    def check_machine_merges(self, pulls: list[int], identities: Identities) -> CheckResult:
        name = "no pull request in the range merged by a machine user"
        offenders = []
        for number in pulls:
            pr = self.github.pull(number)
            merged_by = ((pr.get("merged_by") or {}).get("login") or "").lower()
            if not merged_by:
                return CheckResult(6, name, False, f"pull request {number} has no merged_by")
            if merged_by in identities.machine_users:
                offenders.append({"pull": number, "merged_by": merged_by})
        if offenders:
            return CheckResult(6, name, False,
                               "merged by a machine user: " + ", ".join(f"#{o['pull']} by {o['merged_by']}" for o in offenders),
                               {"offenders": offenders})
        return CheckResult(6, name, True, f"{len(pulls)} pull request(s) merged by people")

    # --- orchestration ----------------------------------------------------------------------

    def run(self, mode: str, sha: str, env: str, build_id: str | None = None) -> GateReport:
        """mode: apply | image | promotion. Fails closed on any exception."""
        report = GateReport(mode=mode, repo=self.github.repo, sha=sha)
        try:
            if mode not in ("apply", "image", "promotion"):
                raise GateError(f"unknown mode {mode!r}")
            identities = load_identities(self.store)
            r1, pulls1 = self.check_merge_commit(sha)
            report.results.append(r1)
            if mode == "promotion":
                report.results.append(self.check_previous_marker(sha, env))
            r2, pulls2 = self.check_range(sha, env)
            report.results.append(r2)
            pulls = sorted(set(pulls1) | set(pulls2))
            report.results.append(self.check_ci(sha))
            if mode == "promotion":
                if not build_id:
                    raise GateError("promotion needs the build ID")
                report.results.append(self.check_independent_approval(build_id, pulls, identities))
            report.results.append(self.check_machine_merges(pulls, identities))
        except GateError as exc:
            report.results.append(CheckResult(0, "gate error", False, str(exc)))
        except Exception as exc:  # noqa: BLE001 - fail closed on anything unexpected
            report.results.append(CheckResult(0, "unexpected error", False, f"{type(exc).__name__}: {exc}"))
        return report


def _accepted_shas(shas: list[str], ranges: list[tuple[str, str]]) -> set[str]:
    """Commits that lie inside an accepted range (inclusive, in compare order)."""
    accepted: set[str] = set()
    index = {s: i for i, s in enumerate(shas)}
    for first, last in ranges:
        if first in index and last in index and index[first] <= index[last]:
            accepted.update(shas[index[first]: index[last] + 1])
    return accepted


# --- gate override (§6.5.3) -------------------------------------------------------------------


@dataclass
class Override:
    github: GitHub
    store: Store
    cloud_build: CloudBuild

    def run(self, first: str, last: str, revert_pr: int, reason: str, build_id: str) -> tuple[bool, str]:
        try:
            identities = load_identities(self.store)
            if not reason.strip():
                return False, "a reason is required"
            approver_account = self.cloud_build.approver(build_id)
            if not approver_account:
                return False, "the build has no approver"
            approver = identities.login_for_account(approver_account)
            if not approver:
                return False, f"approver {approver_account} has no entry in identities.json"
            if approver.lower() not in identities.group_logins(PLATFORM_ENGINEERS):
                return False, f"approver {approver} is not in {PLATFORM_ENGINEERS}"
            parents = self.github.commit(first).get("parents") or []
            if not parents:
                return False, f"{first} has no parent"
            status, commits = self.github.compare(parents[0]["sha"], last)
            if status != "ahead" or not commits or commits[-1]["sha"] != last:
                return False, f"{first}..{last} is not a range on main"
            shas = {c["sha"] for c in commits}
            for c in commits:
                for role in ("author", "committer"):
                    login = ((c.get(role) or {}).get("login") or "").lower()
                    if login == approver.lower():
                        return False, f"approver {approver} is the {role} of {c['sha'][:12]}"
            for event in self.github.push_activity():
                if event.get("after") in shas and ((event.get("actor") or {}).get("login") or "").lower() == approver.lower():
                    return False, f"approver {approver} pushed {event.get('after', '')[:12]}"
            pr = self.github.pull(revert_pr)
            if not _merged_into_main(pr) or not pr.get("merge_commit_sha"):
                return False, f"revert pull request {revert_pr} is not merged into main"
            status_after, _ = self.github.compare(last, pr["merge_commit_sha"])
            if status_after != "ahead":
                return False, f"revert pull request {revert_pr} is not merged after the range"
            record = json.dumps({"first": first, "last": last, "approver": approver_account,
                                 "reason": reason, "revert_pr": revert_pr, "build_id": build_id},
                                sort_keys=True).encode()
            name = f"gate/accepted/{self.github.repo}/{first}..{last}"
            if not self.store.create(name, record):
                return False, f"{name} already exists"
            return True, f"accepted {name}"
        except GateError as exc:
            return False, str(exc)
