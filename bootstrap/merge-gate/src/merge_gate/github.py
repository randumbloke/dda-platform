"""Read-only GitHub REST client for the merge gate (design §6.5.1).

Only GET requests. In ``user`` mode the token is the dda-gate-bot classic token with no scopes,
which reads public repositories only and cannot write (VERIFY IN BUILD (VA-103), (VA-102)).
VERIFY IN BUILD (VA-89): the endpoints below return associated pull requests, merge state, the
merging user, check runs with their app, and reviews, with that token, including squash merges.
"""

from __future__ import annotations

import re
import urllib.parse
from dataclasses import dataclass
from typing import Any

from merge_gate.http import GateError, RetryingHttp

API = "https://api.github.com"
_NEXT_LINK = re.compile(r'<([^>]+)>;\s*rel="next"')
MAX_PAGES = 50


@dataclass
class GitHub:
    owner: str
    repo: str
    token: str | None
    http: RetryingHttp

    def _headers(self) -> dict[str, str]:
        headers = {
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "dda-merge-gate",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        return headers

    def _url(self, path: str, params: dict[str, Any] | None = None) -> str:
        url = f"{API}{path}"
        if params:
            url += "?" + urllib.parse.urlencode(params)
        return url

    def get(self, path: str, params: dict[str, Any] | None = None) -> Any:
        return self.http.request("GET", self._url(path, params), self._headers()).json()

    def get_paginated(self, path: str, params: dict[str, Any] | None = None) -> list[Any]:
        """Follow ``Link: rel="next"``; lists are concatenated."""
        params = dict(params or {})
        params.setdefault("per_page", 100)
        url: str | None = self._url(path, params)
        items: list[Any] = []
        pages = 0
        while url:
            pages += 1
            if pages > MAX_PAGES:
                raise GateError(f"pagination over {MAX_PAGES} pages for {path}; failing closed")
            resp = self.http.request("GET", url, self._headers())
            data = resp.json()
            if not isinstance(data, list):
                raise GateError(f"expected a list from {path}")
            items.extend(data)
            url = _next_link(resp.header("Link"))
        return items

    # --- endpoints -------------------------------------------------------------------------

    def repo_path(self) -> str:
        return f"/repos/{self.owner}/{self.repo}"

    def pulls_for_commit(self, sha: str) -> list[dict[str, Any]]:
        return self.get_paginated(f"{self.repo_path()}/commits/{sha}/pulls")

    def compare(self, base: str, head: str) -> tuple[str, list[dict[str, Any]]]:
        """Return (status, commits) for base...head, following compare pagination."""
        path = f"{self.repo_path()}/compare/{base}...{head}"
        url: str | None = self._url(path, {"per_page": 100})
        status = ""
        commits: list[dict[str, Any]] = []
        pages = 0
        while url:
            pages += 1
            if pages > MAX_PAGES:
                raise GateError("compare pagination too long; failing closed")
            resp = self.http.request("GET", url, self._headers())
            data = resp.json() or {}
            status = status or str(data.get("status", ""))
            commits.extend(data.get("commits") or [])
            url = _next_link(resp.header("Link"))
        return status, commits

    def check_runs(self, sha: str, name: str) -> list[dict[str, Any]]:
        data = self.get(
            f"{self.repo_path()}/commits/{sha}/check-runs",
            {"check_name": name, "filter": "all", "per_page": 100},
        )
        return list((data or {}).get("check_runs") or [])

    def pull(self, number: int) -> dict[str, Any]:
        return self.get(f"{self.repo_path()}/pulls/{number}")

    def pull_reviews(self, number: int) -> list[dict[str, Any]]:
        return self.get_paginated(f"{self.repo_path()}/pulls/{number}/reviews")

    def pull_files(self, number: int) -> list[dict[str, Any]]:
        return self.get_paginated(f"{self.repo_path()}/pulls/{number}/files")

    def commit(self, sha: str) -> dict[str, Any]:
        return self.get(f"{self.repo_path()}/commits/{sha}")

    def push_activity(self, ref: str = "refs/heads/main") -> list[dict[str, Any]]:
        return self.get_paginated(
            f"{self.repo_path()}/activity", {"activity_type": "push", "ref": ref}
        )

    def team_member(self, org: str, team_slug: str, username: str) -> bool:
        """organization mode only."""
        resp = self.http.request(
            "GET",
            self._url(f"/orgs/{org}/teams/{team_slug}/memberships/{username}"),
            self._headers(),
            ok_statuses=(200, 404),
        )
        if resp.status == 404:
            return False
        return (resp.json() or {}).get("state") == "active"


def _next_link(link_header: str | None) -> str | None:
    if not link_header:
        return None
    match = _NEXT_LINK.search(link_header)
    return match.group(1) if match else None
