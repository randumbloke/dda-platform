"""State bucket access (markers, accepted ranges, identities) and Google API helpers.

Markers: ``promotions/<repo>/<env>/<sha>``; accepted ranges: ``gate/accepted/<repo>/<a>..<b>``;
identities: ``bootstrap/identities.json`` (design §6.8). Tokens come from the metadata server of
the build's service account; nothing is stored in the image.
"""

from __future__ import annotations

import json
import urllib.parse
from dataclasses import dataclass, field
from typing import Any, Protocol

from merge_gate.http import GateError, RetryingHttp

METADATA_TOKEN_URL = (
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token"
)
GCS = "https://storage.googleapis.com/storage/v1"
GCS_UPLOAD = "https://storage.googleapis.com/upload/storage/v1"


@dataclass(frozen=True)
class StoredObject:
    name: str
    time_created: str


class Store(Protocol):
    def list(self, prefix: str) -> list[StoredObject]: ...  # pragma: no cover

    def read(self, name: str) -> bytes | None: ...  # pragma: no cover

    def create(self, name: str, data: bytes) -> bool:  # pragma: no cover
        """Create only if absent. Returns False if the object already exists."""
        ...


@dataclass
class MemoryStore:
    """In-memory store for tests."""

    objects: dict[str, tuple[str, bytes]] = field(default_factory=dict)

    def put(self, name: str, data: bytes, time_created: str = "2026-11-09T00:00:00Z") -> None:
        self.objects[name] = (time_created, data)

    def list(self, prefix: str) -> list[StoredObject]:
        return sorted(
            (StoredObject(n, t) for n, (t, _d) in self.objects.items() if n.startswith(prefix)),
            key=lambda o: o.name,
        )

    def read(self, name: str) -> bytes | None:
        item = self.objects.get(name)
        return item[1] if item else None

    def create(self, name: str, data: bytes) -> bool:
        if name in self.objects:
            return False
        self.put(name, data)
        return True


@dataclass
class MetadataToken:
    http: RetryingHttp
    _token: str | None = None

    def __call__(self) -> str:
        if self._token is None:
            resp = self.http.request(
                "GET", METADATA_TOKEN_URL, {"Metadata-Flavor": "Google"}
            )
            token = (resp.json() or {}).get("access_token")
            if not token:
                raise GateError("metadata server returned no access token")
            self._token = token
        return self._token


@dataclass
class GcsStore:
    bucket: str
    http: RetryingHttp
    token: MetadataToken

    def _auth(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token()}"}

    def list(self, prefix: str) -> list[StoredObject]:
        out: list[StoredObject] = []
        page_token: str | None = None
        while True:
            params = {"prefix": prefix, "fields": "items(name,timeCreated),nextPageToken"}
            if page_token:
                params["pageToken"] = page_token
            url = f"{GCS}/b/{self.bucket}/o?{urllib.parse.urlencode(params)}"
            data = self.http.request("GET", url, self._auth()).json() or {}
            out.extend(
                StoredObject(i["name"], i.get("timeCreated", "")) for i in data.get("items", [])
            )
            page_token = data.get("nextPageToken")
            if not page_token:
                return out

    def read(self, name: str) -> bytes | None:
        url = f"{GCS}/b/{self.bucket}/o/{urllib.parse.quote(name, safe='')}?alt=media"
        resp = self.http.request("GET", url, self._auth(), ok_statuses=(200, 404))
        return None if resp.status == 404 else resp.body

    def create(self, name: str, data: bytes) -> bool:
        params = urllib.parse.urlencode(
            {"uploadType": "media", "name": name, "ifGenerationMatch": "0"}
        )
        url = f"{GCS_UPLOAD}/b/{self.bucket}/o?{params}"
        headers = {**self._auth(), "Content-Type": "application/json"}
        resp = self.http.request("POST", url, headers, data, ok_statuses=(200, 412))
        return resp.status == 200


# --- domain helpers ---------------------------------------------------------------------------


def latest_marker(store: Store, repo: str, env: str) -> str | None:
    """SHA of the most recently created marker for repo/env, or None."""
    prefix = f"promotions/{repo}/{env}/"
    markers = [o for o in store.list(prefix) if o.name != prefix]
    if not markers:
        return None
    newest = max(markers, key=lambda o: (o.time_created, o.name))
    return newest.name.rsplit("/", 1)[-1]


def marker_exists(store: Store, repo: str, env: str, sha: str) -> bool:
    return store.read(f"promotions/{repo}/{env}/{sha}") is not None


def accepted_ranges(store: Store, repo: str) -> list[tuple[str, str]]:
    prefix = f"gate/accepted/{repo}/"
    ranges = []
    for obj in store.list(prefix):
        tail = obj.name[len(prefix):]
        if ".." in tail:
            first, last = tail.split("..", 1)
            if first and last:
                ranges.append((first, last))
    return ranges


@dataclass(frozen=True)
class Identities:
    groups: dict[str, list[dict[str, str]]]
    machine_users: frozenset[str]

    def login_for_account(self, account: str) -> str | None:
        account = account.lower()
        for members in self.groups.values():
            for m in members:
                if m.get("google_account", "").lower() == account:
                    return m.get("github_login")
        return None

    def group_logins(self, group: str) -> set[str]:
        return {m["github_login"].lower() for m in self.groups.get(group, []) if "github_login" in m}


def load_identities(store: Store) -> Identities:
    raw = store.read("bootstrap/identities.json")
    if raw is None:
        raise GateError("bootstrap/identities.json cannot be read")
    try:
        data: Any = json.loads(raw)
        groups = data["groups"]
        machine = data["machine_users"]
        if not isinstance(groups, dict) or not isinstance(machine, list):
            raise TypeError("bad shape")
    except (ValueError, KeyError, TypeError) as exc:
        raise GateError(f"bootstrap/identities.json cannot be parsed: {exc}") from exc
    return Identities(groups=groups, machine_users=frozenset(m.lower() for m in machine))


@dataclass
class CloudBuild:
    """Reads the build's approval record (roles/cloudbuild.builds.viewer)."""

    project: str
    region: str
    http: RetryingHttp
    token: MetadataToken

    def approver(self, build_id: str) -> str | None:
        url = (
            f"https://cloudbuild.googleapis.com/v1/projects/{self.project}/locations/"
            f"{self.region}/builds/{build_id}"
        )
        data = self.http.request("GET", url, {"Authorization": f"Bearer {self.token()}"}).json()
        return (((data or {}).get("approval") or {}).get("result") or {}).get("approverAccount")


@dataclass
class PubSub:
    http: RetryingHttp
    token: MetadataToken

    def publish(self, topic: str, attributes: dict[str, str]) -> None:
        url = f"https://pubsub.googleapis.com/v1/{topic}:publish"
        body = json.dumps({"messages": [{"attributes": attributes, "data": ""}]}).encode()
        headers = {"Authorization": f"Bearer {self.token()}", "Content-Type": "application/json"}
        self.http.request("POST", url, headers, body)
