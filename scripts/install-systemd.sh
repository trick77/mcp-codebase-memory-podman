#!/usr/bin/env bash
# Install the rootless Quadlet unit so the codebase-memory-mcp container
# starts at boot and exposes streamable-http on 127.0.0.1:23149.
#
# Requirements:
#   - podman >= 4.4 (RHEL 9.3+ is fine)
#   - systemd --user available
#   - localhost/codebase-memory-mcp:local already built (./scripts/build.sh)
set -euo pipefail

cd "$(dirname "$0")/.."

UNIT_SRC="$(pwd)/systemd/codebase-memory-mcp.container"
UNIT_DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
UNIT_DEST="${UNIT_DEST_DIR}/codebase-memory-mcp.container"
IMAGE="ghcr.io/trick77/mcp-codebase-memory-podman:latest"

# Pull the image up front so the first `systemctl start` doesn't have to
# do it (and so an unreachable registry surfaces here, not in journald).
echo ">> Pulling ${IMAGE}"
podman pull "$IMAGE"

# --- Ask for the base directory containing repos to index ---
DEFAULT_BASE_DIR="$HOME/localgit"
printf "Git base directory containing your projects [%s]: " "$DEFAULT_BASE_DIR"
read -r BASE_DIR
BASE_DIR="${BASE_DIR:-$DEFAULT_BASE_DIR}"
BASE_DIR="${BASE_DIR/#\~/$HOME}"

if [ ! -d "$BASE_DIR" ]; then
    echo "ERROR: ${BASE_DIR} does not exist." >&2
    exit 1
fi
echo ">> Will mount ${BASE_DIR} read-only into the container at the same path"

# 1. Allow this user's systemd to run after logout / on boot.
if ! loginctl show-user "$USER" 2>/dev/null | grep -q '^Linger=yes$'; then
    echo ">> Enabling lingering for $USER (sudo required once)"
    sudo loginctl enable-linger "$USER"
else
    echo ">> Lingering already enabled for $USER"
fi

# 2. Drop the unit in place with the real base-dir baked in.
mkdir -p "$UNIT_DEST_DIR"
sed "s|__BASE_DIR__|${BASE_DIR}|g" "$UNIT_SRC" > "$UNIT_DEST"
echo ">> Installed $UNIT_DEST"

# 3. Reload user systemd so Quadlet generates the .service unit.
systemctl --user daemon-reload

# 4. Start the service. Quadlet-generated units are transient — they can't
# be `enable`d via systemctl. The `[Install] WantedBy=default.target` line
# in the .container file handles boot-time wiring at daemon-reload time.
systemctl --user start codebase-memory-mcp.service

echo ">> Status:"
systemctl --user --no-pager status codebase-memory-mcp.service || true

cat <<EOF

Done. Useful commands:
  systemctl --user status   codebase-memory-mcp.service
  systemctl --user restart  codebase-memory-mcp.service
  systemctl --user stop     codebase-memory-mcp.service
  journalctl --user -u codebase-memory-mcp.service -f

The streamable-http MCP endpoint is now at http://127.0.0.1:23149/mcp

Next step: run ./scripts/install-opencode.sh to wire OpenCode to that endpoint.
EOF
