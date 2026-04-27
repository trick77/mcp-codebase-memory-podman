# mcp-codebase-memory-podman (podman, streamable-http)

Hardened podman wrapper around [`DeusData/codebase-memory-mcp`](https://github.com/DeusData/codebase-memory-mcp). Built for enterprise workstations: corporate CAs baked in at build time, container is `cap_drop: ALL` and `no-new-privileges`, your source tree is mounted read-only, the graph database lives in a named podman volume, and the MCP endpoint is exposed only on `127.0.0.1:23149`.

Upstream speaks stdio only; we bundle [`sparfenyuk/mcp-proxy`](https://github.com/sparfenyuk/mcp-proxy) to expose streamable-http so the container can run as a long-lived Quadlet service. Upstream also ships a static binary that needs a newer glibc than RHEL 9 provides — we build from source inside Debian 13 in a multi-stage image so the final runtime contains only the compiled binary, mcp-proxy, and a Python venv.

## Using it (once installed)

You don't call any tool by name — OpenCode (or any MCP client) auto-discovers them on connect via `tools/list` and routes the agent there when your prompt asks about code structure, dependencies, or call chains. Concretely: just describe what you want to know about the codebase.

Useful prompt shape:

1. **What to look at** — a specific function, class, file, or "this project".
2. **What kind of question** — architecture, callers/callees, dead code, complexity, refactor candidates.
3. **What to do with it** — explain, list, generate a diagram, suggest changes.

Examples that route to the right tools:

```
Index this project and show me the architecture.
```

```
What functions call ProcessOrder, and what does ProcessOrder
itself depend on? Trace two levels deep.
```

```
Find dead code and the most complex functions in this repo.
List refactor candidates with reasons.
```

What the agent has access to (full list under [What works](#what-works) below): repository indexing, graph queries (Cypher), code search, call-path tracing, architecture summaries, dead-code / complexity analysis, ADR management, OpenTelemetry trace ingestion.

## Prerequisites

- `podman` ≥ 4.4 (RHEL 9.3+ is fine)
- `podman-compose` ≥ 1.0.6 (only if you want to run via compose; Quadlet doesn't need it)
- A build host with corporate root CA(s) in `/etc/pki/ca-trust/source/anchors/`
  (override with `HOST_ANCHORS=/path/to/anchors`; the dir may be empty on a
  non-corporate host).
- Source repos to index, all under one base directory (default: `~/localgit`).

## First-time setup

```sh
cp .env.example .env
$EDITOR .env                        # optionally pin VERSION or set NPM_REGISTRY
./scripts/build.sh
podman-compose up -d                # start the service (or use Quadlet, below)
./scripts/install-opencode.sh       # writes the OpenCode MCP entry
```

Then restart OpenCode. The MCP server appears as `codebase-memory-mcp` and points at `http://127.0.0.1:23149/mcp`.

Day-to-day:

```sh
podman-compose ps
podman-compose logs -f
podman-compose restart
podman-compose down
```

For boot-time auto-start (rootless Quadlet, recommended for workstations that should have the service available without logging in):

```sh
./scripts/install-systemd.sh        # one-shot: linger, drop Quadlet, enable
systemctl --user status codebase-memory-mcp.service
journalctl --user -u codebase-memory-mcp.service -f
```

Use **either** podman-compose **or** the Quadlet — not both at once on the same machine, they'd collide on the container name and the published port.

## How it works (1-minute version)

1. Quadlet boots `localhost/codebase-memory-mcp:local` and publishes `127.0.0.1:23149:8000`.
2. Inside the container, `mcp-proxy` listens on `:8000`.
3. OpenCode reads `~/.config/opencode/opencode.json`, sees the remote MCP entry, opens a streamable-http connection to `http://127.0.0.1:23149/mcp`, sends `initialize` → `tools/list`.
4. mcp-proxy spawns `codebase-memory-mcp` (the upstream binary in stdio mode) for that session. The child enumerates tools and serves `tools/call`s for the rest of the session.
5. When OpenCode disconnects, the child exits. The container stays up.

One MCP client session = one persistent binary child. Three concurrent clients = three children. Hard ceilings (`MemoryMax=2G`, `CPUQuota=200%`, `PidsLimit=128`) are set in the Quadlet unit — bump them if you index a large monorepo.

The graph database is persisted in the named volume `codebase-memory-mcp-cache` at `/root/.cache/codebase-memory-mcp/`. Indexes survive container restarts, image rebuilds, and version bumps.

## Updates

```sh
./scripts/update.sh v0.4.11                 # any tag from DeusData/codebase-memory-mcp releases
podman-compose up -d --force-recreate       # pick up the new image
# or, if running via Quadlet:
# systemctl --user restart codebase-memory-mcp.service
```

`update.sh` writes `VERSION=v0.4.11` into `.env`, rebuilds the image with fresh corporate CAs, and prunes dangling layers. `podman auto-update` is **intentionally not used** — the image is built on a controlled host, never pulled at runtime.

## What works

- `index_repository`, `detect_changes`, `index_status`
- `search_graph`, `query_graph` (Cypher), `search_code`, `get_code_snippet`
- `trace_path`, `get_architecture`, `get_graph_schema`
- `manage_adr`, `ingest_traces`
- `list_projects`, `delete_project`

## What does NOT work (by design)

- **No write access to your repos.** The base directory is mounted read-only, so the binary cannot modify, stage, or commit anything.
- **No host bind mounts beyond the source tree.** SSH keys, dotfiles, and other on-disk credentials are not reachable from inside the container.
- **Graph UI in service mode.** Upstream's `--ui=true` binds a per-process HTTP server on port 9749; with mcp-proxy spawning one child per session, only the first child would win the bind. The Quadlet entrypoint deliberately omits `--ui=true`. For ad-hoc UI exploration, run the image directly:

  ```sh
  podman run --rm -it -p 127.0.0.1:9749:9749 \
      -v $HOME/localgit:$HOME/localgit:ro \
      -v codebase-memory-mcp-cache:/root/.cache/codebase-memory-mcp \
      --entrypoint codebase-memory-mcp \
      localhost/codebase-memory-mcp:local --ui=true
  ```

  Stop it (or any active MCP session against the same volume) before starting the other — the graph DB doesn't tolerate concurrent writers.

## Network posture

**Host-only exposure.** Both `compose.yaml` and the Quadlet unit publish the port as `127.0.0.1:23149:8000`. Podman's port forwarder binds only on the loopback interface, so the MCP endpoint is reachable from the host itself but not from any other machine.

Verify after start:

```sh
ss -ltn 'sport = :23149'                          # only 127.0.0.1:23149 (and/or [::1]:23149)
curl -i http://127.0.0.1:23149/mcp                # works from the host
curl -i http://<host-external-ip>:23149/mcp       # MUST fail / connection refused
```

If you ever need cross-host access, do not change the bind to `0.0.0.0` — front it with an authenticated reverse proxy on the host that listens externally and forwards to `127.0.0.1:23149`.

## Verification

```sh
# 1. Image built with corp CAs (count certs in the runtime bundle).
podman run --rm --entrypoint sh localhost/codebase-memory-mcp:local -c \
  'awk "/-----BEGIN CERTIFICATE-----/{c++} END{print c\" certs in bundle\"}" /etc/ssl/certs/ca-certificates.crt'

# 2. Service is up.
systemctl --user is-active codebase-memory-mcp.service

# 3. Tool list comes back over HTTP.
curl -sN -X POST http://127.0.0.1:23149/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  --data '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | head
```

## Hardening

Identical flags in `compose.yaml` and `systemd/codebase-memory-mcp.container` (so podman-compose and Quadlet both apply them). Don't `podman run` this image directly for service use — you'd lose the hardening; always go through compose or the Quadlet.

- `cap_drop: ALL`, `no-new-privileges`.
- Source tree mounted read-only at the same path on host and in container (so paths in graph results match).
- Resource ceilings: `mem_limit=2g`, `cpus=2.0`, `pids_limit=128` (and the matching `MemoryMax`/`CPUQuota`/`PidsLimit` in the Quadlet). mcp-proxy + every spawned child combined cannot exceed these.
- Loopback-only port publish (`127.0.0.1:23149`).

## Layout

```
.
├── Containerfile                          # multi-stage Debian 13 build → minimal runtime image
├── compose.yaml                           # podman-compose service definition
├── .env.example                           # config template (.env is gitignored)
├── scripts/
│   ├── build.sh                           # podman build with -v mount of host CA anchors
│   ├── update.sh                          # pin a new upstream tag, rebuild
│   ├── install-systemd.sh                 # rootless Quadlet install for boot auto-start
│   └── install-opencode.sh                # write the OpenCode MCP "remote" entry
├── systemd/
│   └── codebase-memory-mcp.container      # Quadlet unit (templated)
├── .github/workflows/
│   └── upstream-watch.yaml                # daily mirror of upstream releases as tags
└── README.md
```

## Uninstall

```sh
systemctl --user disable --now codebase-memory-mcp.service
rm ~/.config/containers/systemd/codebase-memory-mcp.container
systemctl --user daemon-reload
podman rmi localhost/codebase-memory-mcp:local
podman volume rm codebase-memory-mcp-cache
# Remove "codebase-memory-mcp" from .mcp in ~/.config/opencode/opencode.json
```
