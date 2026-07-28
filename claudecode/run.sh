#!/usr/bin/env bash
# Claude Code add-on entrypoint.
# (Extracted from the old inline Dockerfile CMD so the MemSearch bootstrap below
#  is readable instead of escaped into a single bash -c string.)
set -o pipefail

export HA_TOKEN="$SUPERVISOR_TOKEN"
export HA_URL="http://supervisor/core"

# /homeassistant/.claudecode is always persistent (survives add-on updates)
PERSIST_DIR=/homeassistant/.claudecode
mkdir -p "$PERSIST_DIR/config" /root/.config

# --------------------------------------------------------------------------
# CLAUDE.md — guidance loaded into every Claude Code session in this add-on
# --------------------------------------------------------------------------
cat > "$PERSIST_DIR/CLAUDE.md" << 'CLAUDEMD'
# Claude Code - Home Assistant Add-on

## Path Mapping

In this add-on container, paths are mapped differently than HA Core:
- `/homeassistant` = HA config directory (equivalent to `/config` in HA Core)
- `/config` does NOT exist - always use `/homeassistant`

When users mention `/config/...`, translate to `/homeassistant/...`

## Available Paths

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media files | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

## Home Assistant Integration

Use the `homeassistant` MCP server to query entities and call services.

## Reading Home Assistant Logs

**Log levels (from most to least verbose):**
- `debug` - Only shown if explicitly enabled in configuration.yaml
- `info` - General information, shown by default
- `warning` - Warnings, always shown
- `error` - Errors, always shown

**Commands to read logs:**
```bash
# View recent logs (ha CLI)
ha core logs 2>&1 | tail -100

# Filter by keyword
ha core logs 2>&1 | grep -i keyword

# Filter errors only
ha core logs 2>&1 | grep -iE "(error|exception)"

# Alternative: read log file directly
tail -100 /homeassistant/home-assistant.log
```

**To enable debug logging for an integration**, add to `configuration.yaml`:
```yaml
logger:
  default: info
  logs:
    custom_components.YOUR_INTEGRATION: debug
```

**Key insight:** `_LOGGER.debug()` calls are invisible unless the logger level is set to debug. Use `_LOGGER.info()` or `_LOGGER.warning()` for logs that should always appear.
CLAUDEMD

# --------------------------------------------------------------------------
# Persist Claude auth/config by symlinking into $PERSIST_DIR
# --------------------------------------------------------------------------
if [ ! -L /root/.claude ]; then rm -rf /root/.claude; ln -s "$PERSIST_DIR" /root/.claude; fi
if [ ! -L /root/.config/claude-code ]; then rm -rf /root/.config/claude-code; ln -s "$PERSIST_DIR/config" /root/.config/claude-code; fi
if [ ! -L /root/.claude.json ]; then touch "$PERSIST_DIR/.claude.json"; rm -f /root/.claude.json; ln -s "$PERSIST_DIR/.claude.json" /root/.claude.json; fi

# --------------------------------------------------------------------------
# Read add-on options
# --------------------------------------------------------------------------
FONT_SIZE=$(jq -r '.terminal_font_size // 14' /data/options.json)
THEME=$(jq -r '.terminal_theme // "dark"' /data/options.json)
SESSION_PERSIST=$(jq -r '.session_persistence // true' /data/options.json)
ENABLE_MCP=$(jq -r '.enable_mcp // true' /data/options.json)
ENABLE_PLAYWRIGHT=$(jq -r '.enable_playwright_mcp // false' /data/options.json)
PLAYWRIGHT_HOST=$(jq -r '.playwright_cdp_host // ""' /data/options.json)

# Auto-detect the Playwright Browser add-on hostname when enabled but unset
if [ -z "$PLAYWRIGHT_HOST" ] && [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
  echo '[INFO] Auto-detecting Playwright Browser hostname...'
  PW_SLUG=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons | jq -r '.data.addons[] | select(.slug | endswith("playwright-browser")) | .slug' | head -1)
  if [ -n "$PW_SLUG" ] && [ "$PW_SLUG" != "null" ]; then
    PLAYWRIGHT_HOST=$(curl -s -H "Authorization: Bearer $SUPERVISOR_TOKEN" http://supervisor/addons/"$PW_SLUG"/info | jq -r '.data.hostname')
    if [ -z "$PLAYWRIGHT_HOST" ] || [ "$PLAYWRIGHT_HOST" = "null" ]; then PLAYWRIGHT_HOST=$(echo "$PW_SLUG" | tr '_' '-'); fi
    echo "[INFO] Found Playwright Browser: $PLAYWRIGHT_HOST (slug: $PW_SLUG)"
  else
    echo '[WARN] Playwright Browser add-on not found, using default hostname'
    PLAYWRIGHT_HOST="playwright-browser"
  fi
fi

# --------------------------------------------------------------------------
# Optional: keep Claude Code up to date
# --------------------------------------------------------------------------
# NOTE: use `npm install -g ...@latest`, NOT `npm update -g`. For a globally
# installed package `npm update -g` frequently no-ops (it won't cross the
# recorded semver range / dist-tag), which is why the add-on stayed pinned on
# an old build even after restarts. `install @latest` always jumps to newest.
# Errors are logged (not swallowed) so a failed update is visible in the log.
update_claude() {
  local before after
  before=$(claude --version 2>/dev/null | awk '{print $1}')
  if npm install -g @anthropic-ai/claude-code@latest 2>&1; then
    hash -r 2>/dev/null || true
    after=$(claude --version 2>/dev/null | awk '{print $1}')
    if [ "$before" != "$after" ]; then
      echo "[INFO] Claude Code updated: ${before:-?} -> ${after:-?}"
    else
      echo "[INFO] Claude Code already latest (${after:-?})"
    fi
  else
    echo '[WARN] Claude Code update failed (network/npm) — continuing with installed version'
  fi
}

AUTO_UPDATE=$(jq -r '.auto_update_claude // true' /data/options.json)
if [ "$AUTO_UPDATE" = "true" ]; then
  echo '[INFO] Checking for Claude Code updates...'
  update_claude
  # Background updater: re-check every 12h so a long-running add-on picks up new
  # Claude Code releases without needing a restart.
  (
    while sleep 43200; do
      echo '[INFO] Periodic Claude Code update check...'
      update_claude
    done
  ) &
fi

# --------------------------------------------------------------------------
# MCP servers (Home Assistant + optional Playwright)
# --------------------------------------------------------------------------
claude mcp remove homeassistant -s user 2>/dev/null || true
claude mcp remove playwright -s user 2>/dev/null || true
claude mcp remove playwright-shot -s user 2>/dev/null || true

if [ "$ENABLE_MCP" = "true" ]; then
  claude mcp add-json homeassistant '{"command":"hass-mcp"}' -s user
  SETTINGS_FILE=/root/.claude/settings.json
  # NOTE: only Read(path) rules are honoured by file permission checks, and they
  # already cover every file-reading tool (Glob and Grep included). Listing
  # Glob(...)/Grep(...) here did nothing except print two warnings on every
  # single startup, so they are gone.
  ALLOWED_TOOLS='["mcp__homeassistant__get_version","mcp__homeassistant__get_entity","mcp__homeassistant__list_entities","mcp__homeassistant__search_entities_tool","mcp__homeassistant__domain_summary_tool","mcp__homeassistant__list_automations","mcp__homeassistant__get_history","mcp__homeassistant__get_error_log","Read(/homeassistant/**)","Read(/config/**)","Read(/share/**)","Read(/media/**)"]'
  # The merge below unions and never removes, so Glob(...)/Grep(...) entries
  # written by older versions would linger in settings.json forever (and keep
  # warning). Strip them on every start.
  jq --argjson tools "$ALLOWED_TOOLS" '
    .permissions.allow = (
      ($tools + (.permissions.allow // []))
      | map(select((startswith("Glob(") or startswith("Grep(")) | not))
      | unique
    )' "$SETTINGS_FILE" > /tmp/settings.tmp && mv /tmp/settings.tmp "$SETTINGS_FILE"
  echo '[INFO] MCP configured with Home Assistant integration'
  echo '[INFO] Pre-authorized read-only MCP tools'
else
  echo '[INFO] MCP disabled'
fi

if [ "$ENABLE_PLAYWRIGHT" = "true" ]; then
  claude mcp add-json playwright "{\"command\":\"node\",\"args\":[\"/opt/playwright-mcp/node_modules/@playwright/mcp/cli.js\",\"--cdp-endpoint\",\"http://${PLAYWRIGHT_HOST}:9222\"]}" -s user
  claude mcp add-json playwright-shot "{\"command\":\"node\",\"args\":[\"/opt/playwright-shot-mcp/server.js\"],\"env\":{\"PLAYWRIGHT_SHOT_CDP\":\"http://${PLAYWRIGHT_HOST}:9222\"}}" -s user
  echo "[INFO] Playwright MCP enabled (CDP: http://${PLAYWRIGHT_HOST}:9222)"
  echo "[INFO] Playwright-shot MCP enabled (downscaled screenshots, same CDP)"
  echo '[INFO] Make sure the Playwright Browser add-on is installed and running'
else
  echo '[INFO] Playwright MCP disabled'
fi

# --------------------------------------------------------------------------
# MemSearch — persistent semantic memory (local ONNX embedder + Milvus Lite)
# Toggle: memsearch_enabled. Installs itself on first enable into a persistent
# venv; the ~558MB bge-m3 model downloads lazily on first memory operation.
# --------------------------------------------------------------------------
MEMSEARCH_ENABLED=$(jq -r '.memsearch_enabled // false' /data/options.json)
MEMSEARCH_MODEL=$(jq -r '.memsearch_model // "bge-m3"' /data/options.json)
MS_VENV="$PERSIST_DIR/memsearch-venv"
MS_HOME="$PERSIST_DIR/memsearch"      # config.toml + milvus.db
export HF_HOME="$PERSIST_DIR/hf-cache"  # onnx model cache (~558MB), persistent
mkdir -p "$MS_HOME" "$HF_HOME"
ln -sfn "$MS_HOME" /root/.memsearch    # so `memsearch` reads persistent config

if [ "$MEMSEARCH_ENABLED" = "true" ]; then
  ARCH="$(uname -m)"
  if [ "$ARCH" != "x86_64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "[WARN] MemSearch needs a 64-bit arch (onnxruntime has no $ARCH wheels) — skipping"
  else
    NEED_INSTALL=false
    PYVER=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    [ -x "$MS_VENV/bin/memsearch" ] || NEED_INSTALL=true
    if [ -f "$MS_VENV/.pyver" ] && [ "$(cat "$MS_VENV/.pyver")" != "$PYVER" ]; then
      echo "[INFO] Python changed ($(cat "$MS_VENV/.pyver") -> $PYVER); rebuilding MemSearch venv"
      rm -rf "$MS_VENV"; NEED_INSTALL=true
    fi
    if [ "$NEED_INSTALL" = "true" ]; then
      echo '[INFO] Installing MemSearch (first enable — downloads wheels, may take a minute)...'
      if python3 -m venv "$MS_VENV" \
        && "$MS_VENV/bin/pip" install --no-cache-dir --upgrade pip >/dev/null 2>&1 \
        && "$MS_VENV/bin/pip" install --no-cache-dir "memsearch[onnx]"; then
        echo "$PYVER" > "$MS_VENV/.pyver"
        echo '[INFO] MemSearch installed'
      else
        echo '[ERROR] MemSearch install failed (network/pip) — memory disabled this boot'
        rm -rf "$MS_VENV"
      fi
    fi
    if [ -x "$MS_VENV/bin/memsearch" ]; then
      ln -sf "$MS_VENV/bin/memsearch" /usr/local/bin/memsearch
      "$MS_VENV/bin/memsearch" config set embedding.provider onnx >/dev/null 2>&1 || true
      [ -n "$MEMSEARCH_MODEL" ] && "$MS_VENV/bin/memsearch" config set embedding.model "$MEMSEARCH_MODEL" >/dev/null 2>&1 || true
      "$MS_VENV/bin/memsearch" config set milvus.uri "$MS_HOME/milvus.db" >/dev/null 2>&1 || true
      # Register + enable the Claude Code plugin (idempotent; loads at session start)
      claude plugin marketplace add zilliztech/memsearch --scope user >/dev/null 2>&1 || true
      claude plugin install memsearch --scope user >/dev/null 2>&1 || true
      claude plugin enable memsearch --scope user >/dev/null 2>&1 || true
      echo "[INFO] MemSearch enabled (provider=onnx, model=$MEMSEARCH_MODEL)"
      echo "[INFO] DB: $MS_HOME/milvus.db | model cache: $HF_HOME (downloads ~558MB on first use)"
    fi
  fi
else
  claude plugin disable memsearch --scope user >/dev/null 2>&1 || true
  echo '[INFO] MemSearch disabled'
fi

# --------------------------------------------------------------------------
# Remote Control — a always-on Claude Code session you can drive from the
# Claude mobile app (Code tab) or claude.ai/code.
#
# Runs detached in its own tmux session ('rc'), separate from the UI session, so
# it survives closing the browser. The `while true` wrapper is the point: Claude
# Code exits Remote Control after roughly 10 minutes without network, and the
# process cannot be restarted remotely (it registers itself outbound with the
# Anthropic API — there is nothing to connect to once it is gone). Without the
# loop, one network blip while you are away ends Remote Control until you are
# back at the machine. This also brings it back after an add-on or host restart.
#
# Modes:
#   interactive — `claude --remote-control`: one persistent session, always
#                 there to talk to. You can also attach locally and type in it.
#   server      — `claude remote-control`: waits for connections and creates
#                 sessions on demand (up to --capacity, default 32), so you can
#                 start new ones from the phone instead of reusing one.
# Requires a claude.ai login (API keys are not supported by Remote Control).
# --------------------------------------------------------------------------
RC_MODE=$(jq -r '.remote_control // "disabled"' /data/options.json)
case "$RC_MODE" in
  interactive) RC_CMD='claude --remote-control "Home Assistant"' ;;
  server)      RC_CMD='claude remote-control --name "Home Assistant"' ;;
  *)           RC_CMD='' ;;
esac

if [ -n "$RC_CMD" ]; then
  tmux kill-session -t rc 2>/dev/null || true
  tmux new-session -d -s rc -c /homeassistant \
    "while true; do $RC_CMD; echo '[rc] Remote Control exited — restarting in 30s'; sleep 30; done"
  echo "[INFO] Remote Control started in tmux session 'rc' (mode: $RC_MODE)"
  echo "[INFO] Attach with 'tmux attach -t rc' to see the session URL / QR code (detach: Ctrl-b d)"
  echo "[INFO] Or open the Claude app -> Code tab; the session appears as 'Home Assistant'"
else
  echo '[INFO] Remote Control disabled'
fi

# --------------------------------------------------------------------------
# Launch the UI: either the classic web terminal (ttyd) or full VS Code in the
# browser (code-server). Both serve on ingress port 7681, so the ingress config
# is unchanged and switching modes needs only a restart (no rebuild). The Claude
# Code experience is the same either way — the difference is terminal-only vs.
# the native Claude Code VS Code extension. All state (auth, sessions, MCP) lives
# in $PERSIST_DIR and is shared between both modes.
# --------------------------------------------------------------------------
UI_MODE=$(jq -r '.ui_mode // "terminal"' /data/options.json)

if [ "$UI_MODE" = "vscode" ]; then
  # code-server state lives in /data (the add-on's private persistent volume,
  # kept across restarts/updates) — same as the official Studio Code Server
  # add-on. Deliberately NOT under /homeassistant: that is the VS Code
  # workspace, and an extensions dir there would be indexed/watched by VS Code.
  # Claude's own state (auth, sessions, MCP) stays in $PERSIST_DIR and is
  # untouched, so history is shared with terminal mode.
  CS_DATA=/data/vscode
  CS_EXT=/data/vscode/extensions
  mkdir -p "$CS_DATA/User" "$CS_EXT"

  # Default VS Code settings, seeded once (user edits afterwards are preserved).
  # The excludes matter: the workspace is the HA config dir, which holds a
  # multi-GB home-assistant_v2.db, .storage, logs, and our own .claudecode
  # (MemSearch venv + ~558MB model cache). Without these, the file watcher and
  # search would index all of it and eat CPU/RAM on every start.
  if [ ! -f "$CS_DATA/User/settings.json" ]; then
    cat > "$CS_DATA/User/settings.json" << 'VSCSETTINGS'
{
  "files.watcherExclude": {
    "**/.storage/**": true,
    "**/.claudecode/**": true,
    "**/deps/**": true,
    "**/__pycache__/**": true,
    "**/node_modules/**": true,
    "**/*.db": true,
    "**/*.db-shm": true,
    "**/*.db-wal": true,
    "**/*.log": true
  },
  "search.exclude": {
    "**/.storage/**": true,
    "**/.claudecode/**": true,
    "**/deps/**": true,
    "**/__pycache__/**": true,
    "**/node_modules/**": true,
    "**/*.db": true,
    "**/*.log": true
  },
  "files.associations": { "*.yaml": "yaml" },
  "telemetry.telemetryLevel": "off",
  "update.mode": "none",
  "terminal.integrated.copyOnSelection": true
}
VSCSETTINGS
    echo '[INFO] Seeded default VS Code settings (HA config excludes)'
  fi

  # Install the native Claude Code extension from Open VSX if missing. Checked
  # via --list-extensions rather than a directory glob, because the on-disk
  # folder casing is not guaranteed (the published id is Anthropic.claude-code).
  if ! code-server --user-data-dir "$CS_DATA" --extensions-dir "$CS_EXT" \
        --list-extensions 2>/dev/null | grep -qi '^anthropic\.claude-code$'; then
    echo '[INFO] Installing Claude Code VS Code extension from Open VSX...'
    code-server --user-data-dir "$CS_DATA" --extensions-dir "$CS_EXT" \
      --install-extension Anthropic.claude-code 2>&1 \
      || echo '[WARN] Extension install failed — install "Claude Code" from the Extensions panel once code-server is up'
  fi

  if [ "$SESSION_PERSIST" = "true" ] || [ "$FONT_SIZE" != "14" ]; then
    echo '[INFO] Note: terminal_font_size / terminal_theme / session_persistence apply to ui_mode=terminal only'
  fi

  echo '[INFO] Starting code-server (VS Code in browser) on ingress port 7681'
  cd /homeassistant
  # --auth none: HA ingress already gates access (same as the official add-on).
  # --disable-workspace-trust is REQUIRED, not cosmetic: the Claude Code
  # extension declares capabilities.untrustedWorkspaces.supported = false, so in
  # an untrusted workspace VS Code silently disables it and the panel never
  # appears. Opening /homeassistant as the folder also keeps the extension's
  # session list identical to the CLI's (history is keyed by working directory).
  exec code-server \
    --bind-addr 0.0.0.0:7681 \
    --auth none \
    --disable-telemetry \
    --disable-update-check \
    --disable-workspace-trust \
    --user-data-dir "$CS_DATA" \
    --extensions-dir "$CS_EXT" \
    /homeassistant
fi

# Default (ui_mode: terminal) — the classic ttyd web terminal
if [ "$THEME" = "dark" ]; then
  COLORS='background=#1e1e2e,foreground=#cdd6f4,cursor=#f5e0dc'
else
  COLORS='background=#eff1f5,foreground=#4c4f69,cursor=#dc8a78'
fi

if [ "$SESSION_PERSIST" = "true" ]; then
  SHELL_CMD='tmux new-session -A -s claude'
else
  SHELL_CMD='bash --login'
fi

cd /homeassistant
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
  -t fontSize="$FONT_SIZE" \
  -t fontFamily=Monaco,Consolas,monospace \
  -t scrollback=20000 \
  -t "theme=$COLORS" \
  $SHELL_CMD
