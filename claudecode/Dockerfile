ARG BUILD_FROM
FROM ${BUILD_FROM}

# Labels
LABEL maintainer="Robson Felix"
LABEL org.opencontainers.image.title="Claude Code for Home Assistant"
LABEL org.opencontainers.image.description="Claude Code CLI with web terminal and HA integration"
LABEL org.opencontainers.image.source="https://github.com/s1mptom/hass-addons"
LABEL org.opencontainers.image.licenses="MIT"

# Environment setup
ENV \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color \
    DEBIAN_FRONTEND=noninteractive \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    HF_HOME=/homeassistant/.claudecode/hf-cache

# System dependencies.
# NOTE: this add-on is now built on the Home Assistant *Debian* (glibc) base
# instead of Alpine/musl, because MemSearch's native deps (onnxruntime,
# milvus-lite) ship glibc-only wheels and do not run on musl. `mbpoll` is a
# Debian package here (no source build needed). `gh`, `docker` CLI, `ttyd`
# and the `ha` CLI are installed as static binaries below.
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash \
    curl \
    ca-certificates \
    git \
    jq \
    openssh-client \
    vim \
    nano \
    tmux \
    ripgrep \
    p7zip-full \
    xz-utils \
    socat \
    mbpoll \
    python3 \
    python3-venv \
    python3-pip \
    less \
    gnupg \
    procps \
    && rm -rf /var/lib/apt/lists/*

# ttyd static binary (avoids libwebsockets issues)
ARG BUILD_ARCH

# Passed by the Supervisor on every build (`--build-arg BUILD_VERSION=<config.yaml
# version>`) and referenced by each RUN below that resolves a moving `latest` at
# build time — gh, Claude Code, the Python helpers, the Playwright MCP and the
# HA CLI. Without it those layers stay cached forever: the Rebuild on 2026-09-04
# finished in 14 seconds and shipped the same Claude Code 2.1.245 that was baked
# on 2026-08-25, which is why every start had to reinstall 2.1.260 over it.
# Bumping the add-on version now busts exactly those layers.
# Version-pinned layers (Node, code-server, Docker CLI) deliberately do NOT
# reference it — bumping their pin is what rebuilds them.
ARG BUILD_VERSION
RUN case "${BUILD_ARCH}" in \
        amd64) TTYD_ARCH="x86_64" ;; \
        aarch64) TTYD_ARCH="aarch64" ;; \
        armv7|armhf) TTYD_ARCH="armhf" ;; \
        i386) TTYD_ARCH="i686" ;; \
        *) TTYD_ARCH="x86_64" ;; \
    esac && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://github.com/tsl0922/ttyd/releases/download/1.7.7/ttyd.${TTYD_ARCH}" -o /usr/bin/ttyd && \
    chmod +x /usr/bin/ttyd

# GitHub CLI (gh) static binary — not in Debian main
RUN echo "add-on ${BUILD_VERSION}" >/dev/null && \
    GH_ARCH=$(case "${BUILD_ARCH}" in amd64) echo amd64 ;; aarch64) echo arm64 ;; armv7|armhf) echo armv6 ;; *) echo amd64 ;; esac) && \
    GH_VER=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${GH_ARCH}.tar.gz" -o /tmp/gh.tgz && \
    tar -xzf /tmp/gh.tgz -C /tmp && \
    mv /tmp/gh_*/bin/gh /usr/local/bin/gh && \
    chmod +x /usr/local/bin/gh && \
    rm -rf /tmp/gh.tgz /tmp/gh_*

# Docker CLI static binary (for Docker socket access)
RUN DOCKER_ARCH=$(case "${BUILD_ARCH}" in amd64) echo x86_64 ;; aarch64) echo aarch64 ;; armv7|armhf) echo armhf ;; *) echo x86_64 ;; esac) && \
    DOCKER_VER=29.8.0 && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://download.docker.com/linux/static/stable/${DOCKER_ARCH}/docker-${DOCKER_VER}.tgz" -o /tmp/docker.tgz && \
    tar -xzf /tmp/docker.tgz -C /tmp && \
    mv /tmp/docker/docker /usr/local/bin/docker && \
    chmod +x /usr/local/bin/docker && \
    rm -rf /tmp/docker.tgz /tmp/docker

# Node.js from the official tarball, NOT Debian's `nodejs`/`npm` packages.
# Debian trixie ships Node 20, but Claude Code requires >= 22 — installing it on
# Node 20 only produced an `npm WARN EBADENGINE` and an unsupported runtime.
# This also puts npm under /usr/local (already ix/link-allowed in AppArmor)
# instead of Debian's /usr/share/nodejs symlink target.
ARG NODE_VERSION="24.20.0"
RUN NODE_ARCH=$(case "${BUILD_ARCH}" in amd64) echo x64 ;; aarch64) echo arm64 ;; *) echo x64 ;; esac) && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" && \
    tar -xJf /tmp/node.tar.xz --strip-components 1 -C /usr/local \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' && \
    rm -f /tmp/node.tar.xz && \
    node --version && npm --version

# Install Claude Code via npm
RUN echo "add-on ${BUILD_VERSION}" >/dev/null && \
    npm install -g @anthropic-ai/claude-code && \
    claude --version

# code-server (VS Code in the browser) — powers the optional `ui_mode: vscode`.
# Lets the native Claude Code VS Code extension (installed at runtime from
# Open VSX) run in-browser via HA ingress, as an alternative to the ttyd
# terminal (`ui_mode: terminal`).
# Installed from a pinned release tarball (same approach as the official HA
# Studio Code Server add-on) rather than `curl code-server.dev/install.sh | sh`:
# reproducible builds, no dpkg/distro detection, and a build that fails loudly
# here instead of at runtime. Ships its own bundled Node.
ARG CODE_SERVER_VERSION="4.135.0"
RUN CS_ARCH=$(case "${BUILD_ARCH}" in amd64) echo amd64 ;; aarch64) echo arm64 ;; *) echo amd64 ;; esac) && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o /tmp/code-server.tar.gz \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${CS_ARCH}.tar.gz" && \
    mkdir -p /usr/local/lib/code-server && \
    tar zxf /tmp/code-server.tar.gz --strip 1 -C /usr/local/lib/code-server && \
    ln -s /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server && \
    rm -f /tmp/code-server.tar.gz && \
    code-server --version

# hass-mcp (Home Assistant MCP) + Modbus/serial helpers into system Python
# `websockets` is for verify-osc52.py, which speaks ttyd's protocol directly to
# check what really reaches the browser (alt-screen, mouse, OSC 52).
RUN echo "add-on ${BUILD_VERSION}" >/dev/null && \
    pip3 install --no-cache-dir hass-mcp pymodbus pyserial websockets

# Playwright MCP into a dedicated prefix, launched via `node` (see run.sh).
# Installing locally and invoking with `node cli.js` avoids the exec-bit and the
# /usr/local/bin/mcp clash with hass-mcp. Browsers are skipped — the MCP attaches
# to the Playwright Browser add-on over CDP, it never launches its own.
ENV NPM_CONFIG_CACHE=/root/.npm
RUN echo "add-on ${BUILD_VERSION}" >/dev/null \
    && mkdir -p /opt/playwright-mcp \
    && cd /opt/playwright-mcp \
    && npm init -y >/dev/null 2>&1 \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install @playwright/mcp@latest

# Second, lightweight MCP that adds a downscaled-screenshot tool (CDP clip.scale).
COPY playwright-shot-mcp /opt/playwright-shot-mcp
RUN cd /opt/playwright-shot-mcp \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev

# Home Assistant CLI (ha command).
# The release tag is resolved explicitly and written to /usr/local/share/ha-cli.version
# because the binary cannot report its own: it has no `--version` flag, and
# `ha cli info` answers with the Supervisor *cli plugin* version (CalVer, e.g.
# 2026.06.0), which is a different thing from this repo's 5.x releases. Without
# the stamp the maintenance check has nothing to compare against.
RUN echo "add-on ${BUILD_VERSION}" >/dev/null && \
    case "${BUILD_ARCH}" in \
        amd64) HA_ARCH="amd64" ;; \
        aarch64) HA_ARCH="aarch64" ;; \
        armv7|armhf) HA_ARCH="armhf" ;; \
        i386) HA_ARCH="i386" ;; \
        *) HA_ARCH="amd64" ;; \
    esac && \
    HA_CLI_VER=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 https://api.github.com/repos/home-assistant/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://github.com/home-assistant/cli/releases/download/${HA_CLI_VER}/ha_${HA_ARCH}" -o /usr/local/bin/ha && \
    chmod +x /usr/local/bin/ha && \
    mkdir -p /usr/local/share && printf '%s\n' "${HA_CLI_VER}" > /usr/local/share/ha-cli.version

# Create necessary directories (NOT /root/.claude - will be symlinked at runtime)
RUN mkdir -p \
    /homeassistant \
    /root/.config \
    /root/.local/bin

# NOTE: /root/.tmux.conf is NOT baked in here any more — it depends on the
# `terminal_renderer` option and is written by run.sh on every start. The old
# hard-coded version (smcup@:rmcup@ + mouse off) is now just the `classic` mode.
# Its comment also claimed the browser terminal "auto-copies to the system
# clipboard", which was never true: ttyd's frontend has no copyOnSelect option.

# bash config: aliases, prompt, MCP token refresh, HF cache on persistent path
RUN cat > /root/.bashrc << 'EOF'
export TERM=xterm-256color
export LANG=C.UTF-8
# MemSearch ONNX model cache on persistent storage (matches run.sh)
export HF_HOME=/homeassistant/.claudecode/hf-cache
PS1='\[\033[1;36m\]claude-code\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Refresh the HA MCP token before starting Claude
update_mcp_token() {
  local SETTINGS_FILE=/root/.claude/settings.json
  if [ -f "$SETTINGS_FILE" ] && [ -n "$SUPERVISOR_TOKEN" ]; then
    jq ".mcpServers.homeassistant.env.HASS_TOKEN = \"$SUPERVISOR_TOKEN\"" "$SETTINGS_FILE" > /tmp/settings.tmp 2>/dev/null && mv /tmp/settings.tmp "$SETTINGS_FILE"
  fi
}

# Aliases
alias ll='ls -la'
alias c='update_mcp_token && claude'
alias cc='update_mcp_token && claude --continue'
alias ha-config='cd /homeassistant'
alias ha-logs='cat /homeassistant/home-assistant.log 2>/dev/null || echo "Log not found"'
# Same script the `maintenance` add-on option runs, for when you would rather
# not round-trip through the config page and an add-on restart.
alias cc-check-updates='/usr/local/bin/maintenance.sh check'
alias cc-update-all='/usr/local/bin/maintenance.sh update'
EOF

# Ensure .bashrc is sourced for login shells too
RUN echo 'source ~/.bashrc' > /root/.profile

# OSC 52 clipboard shim injected into the ttyd frontend at runtime (see run.sh).
# ttyd embeds its own index.html in the binary and the only supported override is
# --index, so the patched page is built in the container, not here: the add-on is
# cross-built (aarch64 on amd64) and ttyd cannot be executed during the build.
COPY osc52-shim.js /usr/local/share/ttyd-osc52-shim.js
COPY inject-shim.py /usr/local/bin/inject-shim.py
# Transport probe for the same path: speaks ttyd's websocket protocol directly
# and reports whether alt-screen, mouse tracking and OSC 52 really reach a
# client. Shipped so the renderer can be diagnosed inside the add-on, without a
# browser and without the source tree.
COPY verify-osc52.py /usr/local/share/verify-osc52.py

# Startup script + the maintenance action behind the `maintenance` option
COPY run.sh /usr/local/bin/run.sh
COPY maintenance.sh /usr/local/bin/maintenance.sh
RUN chmod +x /usr/local/bin/run.sh /usr/local/bin/maintenance.sh /usr/local/bin/inject-shim.py

# Set up PATH
ENV PATH="/root/.local/bin:${PATH}"

# Set working directory
WORKDIR /homeassistant

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:7681/ || exit 1

# Use /homeassistant/.claudecode which is always persistent
ENTRYPOINT []
CMD ["/usr/local/bin/run.sh"]
