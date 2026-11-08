# runner

The Terraform runner image, `dda-ci/terraform-runner` (design §6.4.2, P6-26): Terraform 1.16.3
(contracts README §6), `gcloud`, `curl`, `jq`, `git`, and the shim scripts location
`/opt/dda/shim` (`$DDA_SHIM_DIR`). Every plan and apply step of every trigger runs in it, by
digest.

| File | Purpose |
|---|---|
| `Dockerfile` | Installs Terraform from `releases.hashicorp.com`, checked against the pinned SHA-256, and runs the version check at build time |
| `check-terraform-version.sh` | Fails unless `terraform version` equals the pin (argument, `$TERRAFORM_VERSION`, or 1.16.3); installed as `/opt/dda/bin/check-terraform-version` |
| `cloudbuild.yaml` | Builds, checks the version in the built image, pushes to `dda-ci` and prints the digest |
| `shim/` | Helper scripts for the data domain module, copied to `/opt/dda/shim` |

Build (bootstrap administrator, from the reviewed `dda-platform` commit):

```bash
gcloud builds submit bootstrap/runner --project=pltfrm-ngnrng --region=australia-southeast1 \
  --config=bootstrap/runner/cloudbuild.yaml --substitutions=_TAG=$(git rev-parse HEAD)
```

Pass the printed digest to bootstrap stage 2 as `runner_image_digest`.

`VERIFY IN BUILD (estate)`: pin the base image and the docker builder by digest. Design §6.11
names Terraform 1.17.1; the contracts pin 1.16.3 (reported difference).
