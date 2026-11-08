"""Command line for the merge gate image (design §6.4.2 steps 0 and 4, §6.5.3).

  python -m merge_gate check    --mode apply|image|promotion --repo R --sha S --env E
  python -m merge_gate promote  --repo R --env E --sha S [--next-topic projects/P/topics/T]
  python -m merge_gate override --repo R --range FIRST..LAST --revert-pr N --reason TEXT

Environment (set by the bootstrap-owned inline build): GITHUB_OWNER, GITHUB_OWNER_TYPE,
STATE_BUCKET, GATE_PROJECT, GATE_REGION, GATE_CI_WAIT_MINUTES, BUILD_ID, and GATE_TOKEN (from
Secret Manager, for check and override only). Exit 0 only when every check passes.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections.abc import Sequence

from merge_gate.checks import Gate, Override
from merge_gate.github import GitHub
from merge_gate.http import GateError, RetryingHttp
from merge_gate.store import CloudBuild, GcsStore, MetadataToken, PubSub


def _env(name: str, required: bool = True, default: str | None = None) -> str:
    value = os.environ.get(name, default)
    if required and not value:
        raise GateError(f"environment variable {name} is not set")
    return value or ""


def _log(msg: str) -> None:
    print(f"[merge-gate] {msg}", file=sys.stderr, flush=True)


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="merge_gate")
    sub = p.add_subparsers(dest="command", required=True)

    c = sub.add_parser("check", help="step 0: run the merge gate checks")
    c.add_argument("--mode", choices=["apply", "image", "promotion"], required=True)
    c.add_argument("--repo", required=True)
    c.add_argument("--sha", required=True)
    c.add_argument("--env", required=True)

    m = sub.add_parser("promote", help="step 4: write the marker and queue the next environment")
    m.add_argument("--repo", required=True)
    m.add_argument("--env", required=True)
    m.add_argument("--sha", required=True)
    m.add_argument("--next-topic", default="")

    o = sub.add_parser("override", help="gate override for an unreviewed commit range")
    o.add_argument("--repo", required=True)
    o.add_argument("--range", required=True, dest="commit_range")
    o.add_argument("--revert-pr", required=True, type=int)
    o.add_argument("--reason", required=True)
    return p


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    http = RetryingHttp(log=_log)
    try:
        token = MetadataToken(http)
        store = GcsStore(_env("STATE_BUCKET"), http, token)
        if args.command == "check":
            gh = GitHub(_env("GITHUB_OWNER"), args.repo, _env("GATE_TOKEN"), http)
            gate = Gate(
                github=gh,
                store=store,
                owner_type=_env("GITHUB_OWNER_TYPE", default="user"),
                ci_wait_minutes=int(_env("GATE_CI_WAIT_MINUTES", default="20")),
                cloud_build=CloudBuild(_env("GATE_PROJECT"), _env("GATE_REGION"), http, token),
                log=_log,
            )
            report = gate.run(args.mode, args.sha, args.env, build_id=os.environ.get("BUILD_ID"))
            print(report.to_json())
            for r in report.results:
                _log(f"check {r.number} {'PASS' if r.passed else 'FAIL'}: {r.detail}")
            return 0 if report.passed else 1

        if args.command == "promote":
            record = json.dumps(
                {"repo": args.repo, "env": args.env, "sha": args.sha,
                 "build_id": _env("BUILD_ID")},
                sort_keys=True,
            ).encode()
            name = f"promotions/{args.repo}/{args.env}/{args.sha}"
            created = store.create(name, record)
            _log(f"marker {name} {'written' if created else 'already present'}")
            if args.next_topic:
                # VERIFY IN BUILD (VA-92): a publish queues the approval-pending promotion build.
                PubSub(http, token).publish(args.next_topic, {"sha": args.sha, "repo": args.repo})
                _log(f"queued {args.next_topic} for {args.sha}")
            return 0

        if args.command == "override":
            if ".." not in args.commit_range:
                raise GateError("--range must be FIRST..LAST")
            first, last = args.commit_range.split("..", 1)
            gh = GitHub(_env("GITHUB_OWNER"), args.repo, _env("GATE_TOKEN"), http)
            ok, detail = Override(
                gh, store, CloudBuild(_env("GATE_PROJECT"), _env("GATE_REGION"), http, token)
            ).run(first, last, args.revert_pr, args.reason, _env("BUILD_ID"))
            _log(("ACCEPTED: " if ok else "REFUSED: ") + detail)
            return 0 if ok else 1
    except GateError as exc:
        _log(f"FAIL (closed): {exc}")
        return 1
    return 1  # pragma: no cover


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
