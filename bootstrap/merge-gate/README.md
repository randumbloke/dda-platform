# merge-gate

Step 0 of every apply, promotion and image build of the DDA reference deployment (design §6.5,
decision P6-16). Deterministic Python (D-01), standard library only, read-only against GitHub,
and it fails closed: any API error, exhausted retry, unreadable object or unknown identity stops
the build before `terraform init` or any image step.

## Checks (§6.5.1)

| # | Check | Modes |
|---|---|---|
| 1 | The built commit is the merge commit of a pull request merged into `main` (merge commit or squash) | apply, image, promotion |
| 2 | Every commit since the environment's latest marker came through a merged pull request or lies in an accepted range; compare status `ahead` or `identical` | apply, image, promotion |
| 3 | `ci-checks` completed with `success`, posted by the `github-actions` app; waits up to `GATE_CI_WAIT_MINUTES` (20) | apply, image, promotion |
| 4 | Cloud Build approver is not the author of any pull request in the range; a change to `classification/infotype_rules.yaml` needs two `dda-governance-admins` approvals on the final head commit, not by the author | promotion |
| 5 | The previous environment's marker exists for the commit | promotion |
| 6 | No pull request in the range was merged by a machine user from `identities.json` | apply, image, promotion |

`user` mode (P6-34; VA-102, VA-103): group membership comes from `bootstrap/identities.json` only.
`organization` mode also checks the GitHub team membership API.

Retries (§6.16.3): three retries per call, waiting 2, 4 and 8 s; `Retry-After` is honoured up to
60 s, and a longer one fails closed at once; a primary rate limit (`X-RateLimit-Remaining: 0`)
waits for `X-RateLimit-Reset` under the same 60 s cap; 5xx, 429 and network errors are retried;
other 4xx responses fail at once.

The gate override (§6.5.3) checks the approver (a platform engineer, not an author, committer
or pusher of the range), that the revert pull request merged after the range, and writes
`gate/accepted/<repo>/<first>..<last>`.

## Layout

```text
src/merge_gate/
  http.py      retries, Retry-After, transport (urllib)
  github.py    read-only GitHub REST client with pagination
  store.py     state bucket (markers, accepted ranges, identities.json), Cloud Build approval, Pub/Sub
  checks.py    checks 1-6 and the gate override
  cli.py       python -m merge_gate check | promote | override
tests/
  fixtures/*.json            golden fixtures: scripted GitHub responses, bucket objects, expected verdict
  make_fixtures.py           generates the fixtures (the committed JSON is the golden source)
  fakes.py                   scripted transport and fake clock (no network)
  test_gate.py               runs every fixture
  test_promotion_override.py checks 4 and 5, gate override
Dockerfile, cloudbuild.yaml  image build into Artifact Registry dda-ci
```

## Checks to run

```bash
uv sync
uv run pytest
uv run ruff check .
```

Fixtures cover: unreviewed commit behind a merge and as the built commit, reviewed merge commit
and squash merge, accepted range, machine-user merge, retries with `Retry-After`, exhausted
retries, an over-long `Retry-After`, primary rate limit reset, 404, CI from another app, failed
CI, CI polling and timeout, rollback behind the marker, no marker, newest marker, compare
pagination and a missing `identities.json`.

## Deployment

A bootstrap administrator builds the image from the reviewed `dda-platform` commit and pushes
it to `dda-ci` (`gcloud builds submit ... --config=merge-gate/cloudbuild.yaml`), then passes the
digest to bootstrap stage 2 (see `../README.md`). The triggers run it by digest as
`tf-deployer`, with `GATE_TOKEN` from the `merge-gate-token` secret.

## VERIFY IN BUILD markers

- VA-89 (`github.py`): the endpoints return associated pull requests, merge state, `merged_by`,
  check runs with their app and reviews with the gate's token, including squash merges.
- VA-103 (`github.py`): a classic token with no scopes reads public repositories in `user` mode.
- VA-92 (`cli.py`): publishing to the promotion topic queues the approval-pending build.
- estate (`Dockerfile`, `cloudbuild.yaml`): base and builder image digests.
