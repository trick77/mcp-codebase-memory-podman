#!/bin/sh
# Apply persisted config from env (one-shot, idempotent), then exec mcp-proxy.
# Each AUTO_* var maps to a `codebase-memory-mcp config set` key. Unset vars
# leave the existing value alone, so a fresh volume picks up the env defaults
# and an existing volume's manual overrides survive image rebuilds.
set -eu

[ -n "${AUTO_INDEX:-}" ]       && codebase-memory-mcp config set auto_index       "$AUTO_INDEX"
[ -n "${AUTO_INDEX_LIMIT:-}" ] && codebase-memory-mcp config set auto_index_limit "$AUTO_INDEX_LIMIT"

exec mcp-proxy --host 0.0.0.0 --port 8000 --pass-environment -- codebase-memory-mcp
