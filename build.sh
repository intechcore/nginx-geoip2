#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# renovate: nginx
NGINX_VERSION="${1:-1.29.5}"
IMAGE_NAME="nginx-geoip2"
IMAGE_TAG="${NGINX_VERSION}"

echo "[INFO] Building ${IMAGE_NAME}:${IMAGE_TAG}..."

docker build \
    --build-arg NGINX_VERSION="${NGINX_VERSION}" \
    -t "${IMAGE_NAME}:${IMAGE_TAG}" \
    .

echo "[INFO] Done: ${IMAGE_NAME}:${IMAGE_TAG}"
