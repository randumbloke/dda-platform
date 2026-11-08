# DDA merge gate image (design §6.5, §6.6.2 step 2). Standard library only: no third-party code
# in the image, so nothing to install.
# VERIFY IN BUILD (estate): pin the base image by digest.
ARG BASE_IMAGE=python:3.13-slim
FROM ${BASE_IMAGE}

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app/src

WORKDIR /app
COPY src/ /app/src/
RUN python -c "import merge_gate.cli" && useradd --uid 10001 --no-create-home gate
USER 10001

ENTRYPOINT ["python", "-m", "merge_gate"]
