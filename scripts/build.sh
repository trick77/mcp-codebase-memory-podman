#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"
IMAGE_NAME="localhost/codebase-memory-mcp:local"

# Load .env if present (NPM_REGISTRY, VERSION).
if [ -f "${REPO_ROOT}/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    . "${REPO_ROOT}/.env"
    set +a
fi

if ! command -v podman &>/dev/null; then
    echo "Error: podman not found. Install podman and retry." >&2
    exit 1
fi

# --- Host CAs ---
# /etc/pki/ca-trust/source/anchors is the standard location on RHEL/Fedora
# for corporate root CAs. Override with HOST_ANCHORS=/path/to/anchors. The
# directory may be empty on a non-corporate host — the build still works.
HOST_ANCHORS="${HOST_ANCHORS:-/etc/pki/ca-trust/source/anchors}"
if [ -d "$HOST_ANCHORS" ]; then
    echo "Mounting host CA certificates from ${HOST_ANCHORS}"
else
    echo "Warning: ${HOST_ANCHORS} not found — building without corporate CAs"
    HOST_ANCHORS=$(mktemp -d)
    trap 'rm -rf "$HOST_ANCHORS"' EXIT
fi

# --- Build args ---
BUILD_ARGS=()
[ -n "${NPM_REGISTRY:-}" ] && BUILD_ARGS+=(--build-arg "NPM_REGISTRY=${NPM_REGISTRY}")
[ -n "${VERSION:-}" ]      && BUILD_ARGS+=(--build-arg "VERSION=${VERSION}")

echo "Building ${IMAGE_NAME}..."
podman build \
    --build-context "hostcerts=${HOST_ANCHORS}" \
    "${BUILD_ARGS[@]}" \
    -f "${REPO_ROOT}/Containerfile" \
    -t "$IMAGE_NAME" \
    "$@" \
    "$REPO_ROOT"

echo "Image built: ${IMAGE_NAME}"

# --- Verify ---
ver_output=$(podman run --rm --entrypoint codebase-memory-mcp "$IMAGE_NAME" --version 2>&1) || true
if [ -n "$ver_output" ]; then
    echo "$ver_output"
fi
