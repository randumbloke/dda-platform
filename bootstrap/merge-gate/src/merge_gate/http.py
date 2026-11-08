"""HTTP transport with the merge gate's bounded retries (design §6.5.2, §6.16.3).

Retry budget: 3 retries per call, waiting 2, 4 and 8 seconds, honouring ``Retry-After`` up to
60 seconds, then failing closed. Everything time-related is injected so tests are deterministic
and make no network calls.
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any, Protocol

BACKOFF_SECONDS: tuple[int, ...] = (2, 4, 8)
MAX_RETRY_AFTER_SECONDS = 60
DEFAULT_TIMEOUT_SECONDS = 30


class GateError(Exception):
    """A failure that must stop the build (fail closed)."""


@dataclass(frozen=True)
class Response:
    status: int
    headers: Mapping[str, str] = field(default_factory=dict)
    body: bytes = b""

    def header(self, name: str) -> str | None:
        lname = name.lower()
        for key, value in self.headers.items():
            if key.lower() == lname:
                return value
        return None

    def json(self) -> Any:
        if not self.body:
            return None
        try:
            return json.loads(self.body)
        except ValueError as exc:  # pragma: no cover - defensive
            raise GateError(f"invalid JSON in response: {exc}") from exc


class Transport(Protocol):
    def __call__(
        self, method: str, url: str, headers: Mapping[str, str], body: bytes | None
    ) -> Response:  # pragma: no cover - protocol
        ...


class TransportError(Exception):
    """Network-level failure (connection refused, timeout, DNS)."""


def urllib_transport(
    method: str, url: str, headers: Mapping[str, str], body: bytes | None
) -> Response:
    """Production transport (stdlib only, so the gate image has no third-party code)."""
    request = urllib.request.Request(url, data=body, method=method, headers=dict(headers))
    try:
        with urllib.request.urlopen(request, timeout=DEFAULT_TIMEOUT_SECONDS) as resp:
            return Response(resp.status, dict(resp.headers.items()), resp.read())
    except urllib.error.HTTPError as exc:
        return Response(exc.code, dict(exc.headers.items()) if exc.headers else {}, exc.read())
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise TransportError(str(exc)) from exc


def _is_rate_limited(resp: Response) -> bool:
    if resp.status == 429:
        return True
    if resp.status == 403:
        if resp.header("Retry-After") is not None:
            return True  # GitHub secondary rate limit
        if resp.header("X-RateLimit-Remaining") == "0":
            return True
    return False


def _retryable(resp: Response) -> bool:
    return resp.status >= 500 or _is_rate_limited(resp)


@dataclass
class RetryingHttp:
    """Calls a transport with the bounded retry budget; raises GateError when exhausted."""

    transport: Transport = urllib_transport
    sleep: Callable[[float], None] = time.sleep
    clock: Callable[[], float] = time.time
    log: Callable[[str], None] = lambda _msg: None

    def request(
        self,
        method: str,
        url: str,
        headers: Mapping[str, str] | None = None,
        body: bytes | None = None,
        ok_statuses: tuple[int, ...] = (200,),
    ) -> Response:
        headers = dict(headers or {})
        attempts = len(BACKOFF_SECONDS) + 1
        last_problem = ""
        for attempt in range(attempts):
            try:
                resp = self.transport(method, url, headers, body)
            except TransportError as exc:
                resp = None
                last_problem = f"transport error: {exc}"
            if resp is not None:
                if resp.status in ok_statuses:
                    return resp
                if not _retryable(resp):
                    raise GateError(f"{method} {url} returned {resp.status}")
                last_problem = f"{method} {url} returned {resp.status}"
            if attempt == attempts - 1:
                break
            wait = self._wait_seconds(resp, attempt)
            self.log(f"retry {attempt + 1}/{len(BACKOFF_SECONDS)} in {wait}s: {last_problem}")
            self.sleep(wait)
        raise GateError(f"retries exhausted: {last_problem}")

    def _wait_seconds(self, resp: Response | None, attempt: int) -> float:
        backoff = BACKOFF_SECONDS[attempt]
        if resp is None:
            return backoff
        retry_after = resp.header("Retry-After")
        if retry_after is not None:
            try:
                seconds = int(retry_after.strip())
            except ValueError as exc:
                raise GateError(f"unparseable Retry-After: {retry_after!r}") from exc
            if seconds > MAX_RETRY_AFTER_SECONDS:
                raise GateError(
                    f"Retry-After {seconds}s exceeds {MAX_RETRY_AFTER_SECONDS}s; failing closed"
                )
            return max(seconds, 0)
        if _is_rate_limited(resp) and resp.header("X-RateLimit-Reset") is not None:
            try:
                reset = int(resp.header("X-RateLimit-Reset") or "0")
            except ValueError as exc:
                raise GateError("unparseable X-RateLimit-Reset") from exc
            seconds = max(reset - int(self.clock()), 0)
            if seconds > MAX_RETRY_AFTER_SECONDS:
                raise GateError(
                    f"rate limit resets in {seconds}s, over {MAX_RETRY_AFTER_SECONDS}s; failing closed"
                )
            return seconds
        return backoff
