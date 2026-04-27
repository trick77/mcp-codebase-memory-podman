# mcp-codebase-memory-podman

Hardened podman wrapper around [`DeusData/codebase-memory-mcp`](https://github.com/DeusData/codebase-memory-mcp). `cap_drop: ALL`, `no-new-privileges`, source tree mounted RO, graph DB in a named volume, MCP endpoint on `127.0.0.1:23149` only.

Upstream is stdio-only and ships a glibc-too-new static binary. We build from source on Debian 13 and bridge stdio→streamable-http via [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) so the container runs as a long-lived Quadlet service.

## Prerequisites

- `podman` ≥ 4.4
- `podman-compose` ≥ 1.0.6
- Source repos under one base directory (default `~/localgit`)

## Setup

```sh
podman pull ghcr.io/trick77/mcp-codebase-memory-podman:latest
podman-compose up -d
./scripts/install-opencode.sh
```

Boot-time auto-start via rootless Quadlet:

```sh
./scripts/install-systemd.sh
```

Use either compose or Quadlet, not both — same container name, same port.

## How it works

1. Quadlet runs the image, publishes `127.0.0.1:23149:8000`.
2. `mcp-proxy` listens on `:8000` inside.
3. Client opens streamable-http to `http://127.0.0.1:23149/mcp`.
4. mcp-proxy spawns one `codebase-memory-mcp` stdio child per session and forwards JSON-RPC.
5. On disconnect the child exits; the container stays up.

Cache lives in the named volume `codebase-memory-mcp-cache`. Resource ceilings (`MemoryMax=2G`, `CPUQuota=200%`, `PidsLimit=128`) cover proxy + all session children — bump for large monorepos.

## Updates

Quadlet has `AutoUpdate=registry`:

```sh
podman auto-update
# or pin:
sed -i 's|:latest|:v0.6.0|' ~/.config/containers/systemd/codebase-memory-mcp.container
systemctl --user daemon-reload && systemctl --user restart codebase-memory-mcp.service
```

CI publishes per build:

- `:<upstream>-<utc-timestamp>` — immutable
- `:<upstream>` — rolling per upstream version
- `:latest` — rolling globally

`upstream-watch.yaml` opens a PR bumping `UPSTREAM_VERSION` in `build.yaml`; the smoke test gates the merge.

## Tools

`index_repository`, `detect_changes`, `index_status`, `search_graph`, `query_graph` (Cypher), `search_code`, `get_code_snippet`, `trace_path`, `get_architecture`, `get_graph_schema`, `manage_adr`, `ingest_traces`, `list_projects`, `delete_project`.

## Constraints

- Source tree is RO. Indexing is read-only.
- No host bind mounts beyond the source tree.
- Graph UI is not exposed in service mode — the binary's `--ui=true` binds 9749 per-process and mcp-proxy spawns one child per session, so multiple sessions would collide. For ad-hoc UI:

  ```sh
  podman run --rm -it -p 127.0.0.1:9749:9749 \
      -v $HOME/localgit:$HOME/localgit:ro \
      -v codebase-memory-mcp-cache:/root/.cache/codebase-memory-mcp \
      --entrypoint codebase-memory-mcp \
      ghcr.io/trick77/mcp-codebase-memory-podman:latest --ui=true
  ```

  Stop the service first — graph DB doesn't tolerate concurrent writers on the same volume.

## Network

Both compose and the Quadlet publish `127.0.0.1:23149:8000`. Verify:

```sh
ss -ltn 'sport = :23149'
curl -i http://127.0.0.1:23149/mcp
```

For cross-host access, front with an authenticated reverse proxy. Don't change the bind to `0.0.0.0`.

## Verify

```sh
systemctl --user is-active codebase-memory-mcp.service
curl -sN -X POST http://127.0.0.1:23149/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}'
# expect serverInfo.name == "codebase-memory-mcp"
```

## Hardening

Compose and Quadlet apply identical flags. `podman run` directly for service use bypasses them.

- `cap_drop: ALL`, `no-new-privileges`
- Source tree RO, mounted at same path on host and in container so graph paths match
- `mem_limit=2g`, `cpus=2.0`, `pids_limit=128` (matching `MemoryMax`/`CPUQuota`/`PidsLimit` on Quadlet)
- Loopback-only port publish

## Uninstall

```sh
systemctl --user disable --now codebase-memory-mcp.service
rm ~/.config/containers/systemd/codebase-memory-mcp.container
systemctl --user daemon-reload
podman rmi ghcr.io/trick77/mcp-codebase-memory-podman:latest
podman volume rm codebase-memory-mcp-cache
# Remove "codebase-memory-mcp" from .mcp in ~/.config/opencode/opencode.json
```

## Building from source

Required behind a TLS-intercepting proxy (CI image has only public CAs).

```sh
cp .env.example .env
./scripts/build.sh                  # tags localhost/codebase-memory-mcp:local
```

`build.sh` mounts `/etc/pki/ca-trust/source/anchors/` (override `HOST_ANCHORS=/path`); both stages import anchors so `git`, `npm`, and `mcp-proxy` trust your corp CA.

Switch compose / Quadlet `image:` / `Image=` to `localhost/codebase-memory-mcp:local` and drop `AutoUpdate=registry` from the Quadlet.

Bump upstream:

```sh
./scripts/update.sh v0.6.1
podman-compose up -d --force-recreate
# or: systemctl --user restart codebase-memory-mcp.service
```
