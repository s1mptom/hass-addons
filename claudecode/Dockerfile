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
    && rm -rf /var/lib/apt/lists/*

# ttyd static binary (avoids libwebsockets issues)
ARG BUILD_ARCH
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
RUN GH_ARCH=$(case "${BUILD_ARCH}" in amd64) echo amd64 ;; aarch64) echo arm64 ;; armv7|armhf) echo armv6 ;; *) echo amd64 ;; esac) && \
    GH_VER=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://github.com/cli/cli/releases/download/v${GH_VER}/gh_${GH_VER}_linux_${GH_ARCH}.tar.gz" -o /tmp/gh.tgz && \
    tar -xzf /tmp/gh.tgz -C /tmp && \
    mv /tmp/gh_*/bin/gh /usr/local/bin/gh && \
    chmod +x /usr/local/bin/gh && \
    rm -rf /tmp/gh.tgz /tmp/gh_*

# Docker CLI static binary (for Docker socket access)
RUN DOCKER_ARCH=$(case "${BUILD_ARCH}" in amd64) echo x86_64 ;; aarch64) echo aarch64 ;; armv7|armhf) echo armhf ;; *) echo x86_64 ;; esac) && \
    DOCKER_VER=29.6.2 && \
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
ARG NODE_VERSION="24.18.0"
RUN NODE_ARCH=$(case "${BUILD_ARCH}" in amd64) echo x64 ;; aarch64) echo arm64 ;; *) echo x64 ;; esac) && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o /tmp/node.tar.xz \
      "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" && \
    tar -xJf /tmp/node.tar.xz --strip-components 1 -C /usr/local \
      --exclude='*/CHANGELOG.md' --exclude='*/LICENSE' --exclude='*/README.md' && \
    rm -f /tmp/node.tar.xz && \
    node --version && npm --version

# Install Claude Code via npm
RUN npm install -g @anthropic-ai/claude-code

# code-server (VS Code in the browser) — powers the optional `ui_mode: vscode`.
# Lets the native Claude Code VS Code extension (installed at runtime from
# Open VSX) run in-browser via HA ingress, as an alternative to the ttyd
# terminal (`ui_mode: terminal`).
# Installed from a pinned release tarball (same approach as the official HA
# Studio Code Server add-on) rather than `curl code-server.dev/install.sh | sh`:
# reproducible builds, no dpkg/distro detection, and a build that fails loudly
# here instead of at runtime. Ships its own bundled Node.
ARG CODE_SERVER_VERSION="4.130.0"
RUN CS_ARCH=$(case "${BUILD_ARCH}" in amd64) echo amd64 ;; aarch64) echo arm64 ;; *) echo amd64 ;; esac) && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 -o /tmp/code-server.tar.gz \
      "https://github.com/coder/code-server/releases/download/v${CODE_SERVER_VERSION}/code-server-${CODE_SERVER_VERSION}-linux-${CS_ARCH}.tar.gz" && \
    mkdir -p /usr/local/lib/code-server && \
    tar zxf /tmp/code-server.tar.gz --strip 1 -C /usr/local/lib/code-server && \
    ln -s /usr/local/lib/code-server/bin/code-server /usr/local/bin/code-server && \
    rm -f /tmp/code-server.tar.gz && \
    code-server --version

# hass-mcp (Home Assistant MCP) + Modbus/serial helpers into system Python
RUN pip3 install --no-cache-dir hass-mcp pymodbus pyserial

# Playwright MCP into a dedicated prefix, launched via `node` (see run.sh).
# Installing locally and invoking with `node cli.js` avoids the exec-bit and the
# /usr/local/bin/mcp clash with hass-mcp. Browsers are skipped — the MCP attaches
# to the Playwright Browser add-on over CDP, it never launches its own.
ENV NPM_CONFIG_CACHE=/root/.npm
RUN mkdir -p /opt/playwright-mcp \
    && cd /opt/playwright-mcp \
    && npm init -y >/dev/null 2>&1 \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install @playwright/mcp@latest

# Second, lightweight MCP that adds a downscaled-screenshot tool (CDP clip.scale).
COPY playwright-shot-mcp /opt/playwright-shot-mcp
RUN cd /opt/playwright-shot-mcp \
    && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --omit=dev

# Home Assistant CLI (ha command)
RUN case "${BUILD_ARCH}" in \
        amd64) HA_ARCH="amd64" ;; \
        aarch64) HA_ARCH="aarch64" ;; \
        armv7|armhf) HA_ARCH="armhf" ;; \
        i386) HA_ARCH="i386" ;; \
        *) HA_ARCH="amd64" ;; \
    esac && \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20 "https://github.com/home-assistant/cli/releases/latest/download/ha_${HA_ARCH}" -o /usr/local/bin/ha && \
    chmod +x /usr/local/bin/ha

# Create necessary directories (NOT /root/.claude - will be symlinked at runtime)
RUN mkdir -p \
    /homeassistant \
    /root/.config \
    /root/.local/bin

# tmux config: large scrollback, native browser selection (mouse off)
RUN cat > /root/.tmux.conf << 'EOF'
set -g history-limit 20000
# Disable alternate screen buffer to allow terminal scrollback
set -ga terminal-overrides ',xterm*:smcup@:rmcup@'
# Mouse OFF so the browser terminal (ttyd) handles selection natively and
# auto-copies to the system clipboard.
set -g mouse off
# Bind mouse wheel to scroll through history in copy mode
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
bind -n WheelDownPane select-pane -t= \; send-keys -M
EOF

# bash config: aliases, prompt, MCP token refresh, HF cache on persistent path
RUN cat > /root/.bashrc << 'EOF'
export TERM=xterm-256color
export LANG=C.UTF-8
# MemSearch ONNX model cache on persistent storage (matches run.sh)
export HF_HOME=/homeassistant/.claudecode/hf-cache
PS1='\[\033[1;36m\]claude-code\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ '

# Keep Claude's TUI in "default" mode so the browser terminal handles selection.
if [ -f /root/.claude/settings.json ]; then
  jq '.tui = (.tui // "default")' /root/.claude/settings.json > /tmp/.settings.tmp 2>/dev/null && mv /tmp/.settings.tmp /root/.claude/settings.json
fi

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
EOF

# Ensure .bashrc is sourced for login shells too
RUN echo 'source ~/.bashrc' > /root/.profile

# Startup script
COPY run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

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
