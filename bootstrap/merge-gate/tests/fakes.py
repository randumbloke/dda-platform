"""Test doubles: a scripted HTTP transport and helpers to load golden fixtures.

No network: every URL the gate requests must be scripted in the fixture, otherwise the fake
raises and the test fails.
"""

from __future__ import annotations

import json
import urllib.parse
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from merge_gate.checks import Gate
from merge_gate.github import GitHub
from merge_gate.http import Response, RetryingHttp, TransportError
from merge_gate.store import MemoryStore

FIXTURES = Path(__file__).parent / "fixtures"


class UnscriptedRequest(AssertionError):
    pass


@dataclass
class ScriptedTransport:
    """Maps "METHOD /path" (query ignored) to a list of responses served in order; the last
    response repeats. A response {"error": "..."} raises a transport error."""

    script: dict[str, list[dict[str, Any]]]
    calls: list[str] = field(default_factory=list)
    unscripted: list[str] = field(default_factory=list)
    _served: dict[str, int] = field(default_factory=dict)

    def __call__(
        self, method: str, url: str, headers: Mapping[str, str], body: bytes | None
    ) -> Response:
        path = urllib.parse.urlsplit(url).path
        key = f"{method} {path}"
        self.calls.append(key)
        if key not in self.script:
            self.unscripted.append(key)
            raise UnscriptedRequest(key)
        seq = self.script[key]
        i = self._served.get(key, 0)
        self._served[key] = i + 1
        item = seq[min(i, len(seq) - 1)]
        if "error" in item:
            raise TransportError(item["error"])
        body_obj = item.get("body")
        raw = b"" if body_obj is None else json.dumps(body_obj).encode()
        return Response(item.get("status", 200), item.get("headers", {}), raw)


@dataclass
class FakeClock:
    now: float = 1_000_000.0
    sleeps: list[float] = field(default_factory=list)

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds

    def __call__(self) -> float:
        return self.now


def load_fixture(name: str) -> dict[str, Any]:
    return json.loads((FIXTURES / name).read_text())


def build_gate(fixture: dict[str, Any]) -> tuple[Gate, ScriptedTransport, FakeClock]:
    transport = ScriptedTransport(fixture["responses"])
    clock = FakeClock()
    http = RetryingHttp(transport=transport, sleep=clock.sleep, clock=clock)
    store = MemoryStore()
    for name, obj in fixture.get("store", {}).items():
        data = obj["data"]
        raw = data.encode() if isinstance(data, str) else json.dumps(data).encode()
        store.put(name, raw, obj.get("time", "2026-11-09T00:00:00Z"))
    gh = GitHub(fixture["owner"], fixture["repo"], "test-token", http)
    gate = Gate(
        github=gh,
        store=store,
        owner_type=fixture.get("owner_type", "user"),
        ci_wait_minutes=fixture.get("ci_wait_minutes", 20),
        sleep=clock.sleep,
        clock=clock,
    )
    return gate, transport, clock
