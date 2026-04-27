FROM debian:13-slim AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      gcc g++ make git curl ca-certificates nodejs npm zlib1g-dev libgit2-dev pkg-config && \
    rm -rf /var/lib/apt/lists/*

# Bake corporate CAs into the build stage so npm/git over HTTPS work behind a
# TLS-intercepting proxy. Mount provided by scripts/build.sh via a named build
# context — works with both podman and docker BuildKit:
#   podman/docker build --build-context hostcerts=/etc/pki/ca-trust/source/anchors ...
RUN --mount=type=bind,from=hostcerts,target=/host-anchors,ro \
    for f in /host-anchors/*; do \
        [ -f "$f" ] || continue; \
        base=$(basename "$f"); \
        cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
    done && \
    update-ca-certificates

RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    curl -fsSL "https://go.dev/dl/go1.23.6.linux-${ARCH}.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

ARG NPM_REGISTRY=https://registry.npmjs.org/
RUN npm config set registry "$NPM_REGISTRY" && \
    npm ping || { echo "Error: Cannot reach npm registry at ${NPM_REGISTRY}" >&2; exit 1; }

ARG VERSION=latest

WORKDIR /src
RUN if [ "$VERSION" = "latest" ]; then \
      VERSION=$(curl -fsSL https://api.github.com/repos/DeusData/codebase-memory-mcp/releases/latest | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//'); \
    fi && \
    git clone --depth 1 --branch "$VERSION" https://github.com/DeusData/codebase-memory-mcp.git .

ENV MAKEFLAGS="-j$(nproc)"
RUN bash scripts/build.sh --with-ui

# --- runtime stage ---
# Native binary + Python 3 in one image. The binary speaks MCP over stdio
# (upstream has no native HTTP transport). Python runs sparfenyuk/mcp-proxy
# which spawns the binary as a child and exposes JSON-RPC as streamable-http
# on 0.0.0.0:8000 so the container can run as a long-lived, Quadlet-managed
# service like other enterprise MCP wrappers.
FROM debian:13-slim

ARG MCP_PROXY_VERSION=0.10.0

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        libgit2-1.9 \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Re-import host CAs in the runtime stage too. mcp-proxy is Python and uses
# the system bundle directly via REQUESTS_CA_BUNDLE.
RUN --mount=type=bind,from=hostcerts,target=/host-anchors,ro \
    for f in /host-anchors/*; do \
        [ -f "$f" ] || continue; \
        base=$(basename "$f"); \
        cp "$f" "/usr/local/share/ca-certificates/${base%.*}.crt"; \
    done && \
    update-ca-certificates

# Install mcp-proxy into a venv owned by root, on PATH for everyone.
RUN python3 -m venv /opt/mcp-proxy && \
    /opt/mcp-proxy/bin/pip install --no-cache-dir "mcp-proxy==${MCP_PROXY_VERSION}" && \
    ln -s /opt/mcp-proxy/bin/mcp-proxy /usr/local/bin/mcp-proxy

COPY --from=builder /src/build/c/codebase-memory-mcp /usr/local/bin/codebase-memory-mcp

ENV REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

EXPOSE 8000

# mcp-proxy spawns one `codebase-memory-mcp` child per MCP client session
# (NOT per request — sessions are tracked, so OpenCode + Cursor + Claude Code
# concurrently = 3 long-lived child processes, not N-per-tool-call).
#
# UI (--ui=true) is intentionally NOT enabled here. The graph UI binds port
# 9749 inside the child process; with multiple concurrent sessions, only the
# first child would win the bind. For ad-hoc UI exploration, run the image
# directly: `podman run --rm -it -p 127.0.0.1:9749:9749 codebase-memory-mcp --ui=true`.
ENTRYPOINT ["mcp-proxy", "--host", "0.0.0.0", "--port", "8000", \
            "--pass-environment", "--", \
            "codebase-memory-mcp"]
