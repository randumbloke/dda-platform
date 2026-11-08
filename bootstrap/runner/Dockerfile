# DDA Terraform runner image (design §6.4.2, P6-26): Terraform, gcloud, curl and jq.
# Built by a bootstrap administrator from the reviewed dda-platform commit and pushed to
# Artifact Registry dda-ci (runner/cloudbuild.yaml); triggers reference it by digest.
#
# Terraform 1.16.3 per the phase 1 contracts (contracts README §6). Design §6.11 names 1.17.1;
# that difference is reported, not resolved here.

# VERIFY IN BUILD (estate): pin by digest (gcloud artifacts docker images describe ...).
ARG BASE_IMAGE=gcr.io/google.com/cloudsdktool/google-cloud-cli:slim
FROM ${BASE_IMAGE}

ARG TERRAFORM_VERSION=1.16.3
# From https://releases.hashicorp.com/terraform/1.16.3/terraform_1.16.3_SHA256SUMS (read 2026-11-09).
ARG TERRAFORM_SHA256_AMD64=093b6ae9a2228af5029c41606bc96eb583553528aad1bfe7e0b4d62fc91e25d8
ARG TERRAFORM_SHA256_ARM64=b6b293550af7a6a7ffd867a04900ce161db86ec9407b234a636c2adbae2ca9f0
ARG TARGETARCH=amd64

ENV TERRAFORM_VERSION=${TERRAFORM_VERSION} \
    TF_IN_AUTOMATION=1 \
    TF_INPUT=0 \
    CHECKPOINT_DISABLE=1 \
    DDA_SHIM_DIR=/opt/dda/shim \
    PATH=/opt/dda/bin:${PATH}

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl jq unzip ca-certificates git; \
    rm -rf /var/lib/apt/lists/*; \
    case "${TARGETARCH}" in \
      amd64) sum="${TERRAFORM_SHA256_AMD64}" ;; \
      arm64) sum="${TERRAFORM_SHA256_ARM64}" ;; \
      *) echo "unsupported arch ${TARGETARCH}"; exit 1 ;; \
    esac; \
    zip="terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip"; \
    curl -fsSLo "/tmp/${zip}" "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/${zip}"; \
    echo "${sum}  /tmp/${zip}" | sha256sum -c -; \
    unzip -o "/tmp/${zip}" terraform -d /usr/local/bin; \
    rm -f "/tmp/${zip}"; \
    mkdir -p /opt/dda/bin /opt/dda/shim

# Shim scripts location (data domain module, §2.3.2). The module itself lives in
# dda-platform/modules/data_domain_shim and is fetched by git with the stack; scripts that the
# module calls by absolute path are copied here when they exist.
COPY shim/ /opt/dda/shim/
COPY check-terraform-version.sh /opt/dda/bin/check-terraform-version
RUN chmod 0755 /opt/dda/bin/check-terraform-version /opt/dda/shim/*.sh 2>/dev/null || true; \
    /opt/dda/bin/check-terraform-version "${TERRAFORM_VERSION}"; \
    gcloud --version; jq --version; curl --version | head -n 1

WORKDIR /workspace
ENTRYPOINT ["bash"]
