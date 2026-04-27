#!/usr/bin/env bash
# Update workflow: pin a new upstream tag in .env, rebuild the image.
# Usage: ./scripts/update.sh <upstream-tag>
#        ./scripts/update.sh v0.4.11
#
# Tags come from https://github.com/DeusData/codebase-memory-mcp/releases
# (use the leading 'v', e.g. v0.4.11 — that's the git tag the Containerfile
# clones with `--branch`).
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <upstream-tag>   (e.g. v0.4.11)" >&2
    exit 2
fi

NEW_TAG="$1"

if [ ! -f .env ]; then
    echo "VERSION=${NEW_TAG}" > .env
    echo ">> Created .env with VERSION=${NEW_TAG}"
elif grep -qE '^VERSION=' .env; then
    sed -i.bak -E "s|^VERSION=.*|VERSION=${NEW_TAG}|" .env
    rm -f .env.bak
    echo ">> Updated VERSION in .env to ${NEW_TAG}"
else
    printf '\nVERSION=%s\n' "${NEW_TAG}" >> .env
    echo ">> Appended VERSION=${NEW_TAG} to .env"
fi

echo ">> Rebuilding"
./scripts/build.sh

echo ">> Pruning dangling images"
podman image prune -f

echo ">> Update complete. Pinned version: ${NEW_TAG}"
echo ">> Restart the service:"
echo "      systemctl --user restart codebase-memory-mcp.service"
