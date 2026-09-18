#!/usr/bin/env bash
# Build ralph-dashboard inside the optional Dockerfile.build image and extract
# dist/ onto the host via docker cp. Docker is an operator convenience only;
# when it is missing, exit with a clear message and use host `npm run build`.
#
# Usage:
#   bash ralph-dashboard/scripts/build-in-container.sh
#
# Env:
#   RALPH_DASHBOARD_BUILD_IMAGE  Image tag (default: ralph-dashboard-build)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DASHBOARD_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOCKERFILE="${DASHBOARD_ROOT}/Dockerfile.build"
IMAGE_NAME="${RALPH_DASHBOARD_BUILD_IMAGE:-ralph-dashboard-build}"
HOST_DIST="${DASHBOARD_ROOT}/dist"
CONTAINER_DIST="/app/dist"

if ! command -v docker >/dev/null 2>&1; then
  cat >&2 <<EOF
Docker was not found on PATH.

Containerized dashboard builds require Docker. Install Docker Desktop (or another
Docker Engine), ensure \`docker\` is on PATH, then re-run:

  bash ${SCRIPT_DIR}/build-in-container.sh

Or build on the host without Docker:

  cd ${DASHBOARD_ROOT} && npm run build
EOF
  exit 1
fi

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "Missing Dockerfile: ${DOCKERFILE}" >&2
  exit 1
fi

echo "Building image ${IMAGE_NAME} from ${DOCKERFILE} ..."
docker build -f "${DOCKERFILE}" -t "${IMAGE_NAME}" "${DASHBOARD_ROOT}"

container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm -f "${container_id}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# Image already ran \`npm run build\` during docker build; create a stopped
# container so we can docker cp the finished dist tree.
container_id="$(docker create "${IMAGE_NAME}")"

# Replace host dist only after a successful image build + create.
rm -rf "${HOST_DIST}"
mkdir -p "${HOST_DIST}"
docker cp "${container_id}:${CONTAINER_DIST}/." "${HOST_DIST}/"

echo "Extracted container ${CONTAINER_DIST} -> ${HOST_DIST}"
if [[ -d "${HOST_DIST}/ralph-dashboard" ]]; then
  echo "OK: ${HOST_DIST}/ralph-dashboard"
else
  echo "Expected ${HOST_DIST}/ralph-dashboard after extract, but it is missing." >&2
  exit 1
fi
