#!/usr/bin/env bash
# Wire OpenCode to the running codebase-memory-mcp HTTP endpoint.
# The container itself is managed by Quadlet (see scripts/install-systemd.sh);
# OpenCode just connects to http://127.0.0.1:23149/mcp.
set -euo pipefail

OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
MCP_URL="${MCP_URL:-http://127.0.0.1:23149/mcp}"

echo "codebase-memory-mcp OpenCode wiring"
echo "Endpoint: ${MCP_URL}"

# --- Sanity-check the endpoint is up. ---
if command -v curl >/dev/null 2>&1; then
    if ! curl -fsS -o /dev/null --max-time 3 -X POST -H 'Content-Type: application/json' \
            -H 'Accept: application/json, text/event-stream' \
            --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"install-check","version":"0"}}}' \
            "$MCP_URL"; then
        echo "WARNING: ${MCP_URL} did not respond. Is the systemd service running?" >&2
        echo "         systemctl --user status codebase-memory-mcp.service" >&2
    else
        echo ">> Endpoint reachable."
    fi
fi

mkdir -p "$(dirname "$OPENCODE_CONFIG")"

if [ -f "$OPENCODE_CONFIG" ] && \
   ! python3 -c "import json; json.load(open('$OPENCODE_CONFIG'))" 2>/dev/null && \
   ! jq empty "$OPENCODE_CONFIG" 2>/dev/null; then
    echo "ERROR: ${OPENCODE_CONFIG} contains invalid JSON. Fix it and re-run." >&2
    exit 1
fi

if command -v jq >/dev/null 2>&1; then
    entry=$(jq -n --arg url "$MCP_URL" '{type: "remote", url: $url, enabled: true}')
    if [ -f "$OPENCODE_CONFIG" ]; then
        tmp=$(mktemp)
        jq --argjson entry "$entry" '.mcp["codebase-memory-mcp"] = $entry' "$OPENCODE_CONFIG" > "$tmp"
        mv "$tmp" "$OPENCODE_CONFIG"
    else
        echo '{}' | jq --argjson entry "$entry" '.mcp["codebase-memory-mcp"] = $entry' > "$OPENCODE_CONFIG"
    fi
elif command -v python3 >/dev/null 2>&1; then
    MCP_URL="$MCP_URL" OPENCODE_CONFIG="$OPENCODE_CONFIG" python3 <<'PYEOF'
import json, os
path = os.environ['OPENCODE_CONFIG']
url  = os.environ['MCP_URL']
entry = {"type": "remote", "url": url, "enabled": True}
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
data.setdefault('mcp', {})['codebase-memory-mcp'] = entry
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
PYEOF
else
    echo "ERROR: neither jq nor python3 available; cannot edit ${OPENCODE_CONFIG}." >&2
    exit 1
fi

echo ">> Updated ${OPENCODE_CONFIG}"
echo ""
echo "Restart OpenCode and verify 'codebase-memory-mcp' appears in the MCP server list."
