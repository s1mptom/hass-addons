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

# Seed settings.json before anything tries to edit it. The MCP allow-list merge
# and the renderer's `tui` write are both `jq <file>` reads, which fail on a
# missing file — on a first boot, before Claude Code has ever run, that made the
# pre-authorised tool list quietly not apply.
[ -s "$PERSIST_DIR/settings.json" ] || echo '{}' > "$PERSIST_DIR/settings.json"

# --------------------------------------------------------------------------
# Persist the GitHub CLI login and git config the same way.
#
# `gh auth login` writes its token to /root/.config/gh/hosts.yml and
# `gh auth setup-git` writes a credential helper into /root/.gitconfig — both
# live in the image, so an add-on Update or Rebuild silently logs you out of
# GitHub again. Moving them under $PERSIST_DIR makes the login survive.
# --------------------------------------------------------------------------
mkdir -p "$PERSIST_DIR/gh"
if [ ! -L /root/.config/gh ]; then rm -rf /root/.config/gh; ln -s "$PERSIST_DIR/gh" /root/.config/gh; fi
if [ ! -L /root/.gitconfig ]; then touch "$PERSIST_DIR/gitconfig"; rm -f /root/.gitconfig; ln -s "$PERSIST_DIR/gitconfig" /root/.gitconfig; fi

# Checked by file, not by `gh auth status`: that command round-trips to GitHub to
# validate the token, and this runs on the startup path of every boot.
if [ -s "$PERSIST_DIR/gh/hosts.yml" ]; then
  gh auth setup-git 2>&1 || echo '[WARN] gh auth setup-git failed — git pushes may prompt for credentials'
  echo "[INFO] GitHub CLI authenticated ($(gh --version 2>/dev/null | head -1 | awk '{print $3}')); git uses gh as its credential helper"
else
  echo '[INFO] GitHub CLI available but not logged in — run `gh auth login` once in the terminal (the login now persists across add-on updates)'
fi

# --------------------------------------------------------------------------
# Read add-on options
# --------------------------------------------------------------------------
FONT_SIZE=$(jq -r '.terminal_font_size // 14' /data/options.json)
THEME=$(jq -r '.terminal_theme // "dark"' /data/options.json)
SESSION_PERSIST=$(jq -r '.session_persistence // true' /data/options.json)
ENABLE_MCP=$(jq -r '.enable_mcp // true' /data/options.json)
ENABLE_PLAYWRIGHT=$(jq -r '.enable_playwright_mcp // false' /data/options.json)
PLAYWRIGHT_HOST=$(jq -r '.playwright_cdp_host // ""' /data/options.json)
UI_MODE=$(jq -r '.ui_mode // "terminal"' /data/options.json)

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
      # Errors here are logged, NOT sent to /dev/null. Every one of these calls
      # used to be silenced, which is exactly how MemSearch spent weeks recording
      # empty sessions after AppArmor started denying its hook helpers: nothing
      # was broken loudly enough to notice. If configuring or registering the
      # plugin fails, that has to be visible in the add-on log.
      ms_cfg() {
        "$MS_VENV/bin/memsearch" config set "$1" "$2" 2>&1 \
          || echo "[WARN] memsearch config set $1 failed"
      }
      ms_cfg embedding.provider onnx
      [ -n "$MEMSEARCH_MODEL" ] && ms_cfg embedding.model "$MEMSEARCH_MODEL"
      ms_cfg milvus.uri "$MS_HOME/milvus.db"

      # Register + enable the Claude Code plugin (idempotent; loads at session
      # start). `marketplace update` refreshes an already-added marketplace, so a
      # new plugin release is picked up without touching the add-on.
      claude plugin marketplace add zilliztech/memsearch --scope user 2>&1 \
        || claude plugin marketplace update memsearch 2>&1 \
        || echo '[WARN] MemSearch marketplace add/update failed — plugin may be stale'
      claude plugin install memsearch --scope user 2>&1 \
        || echo '[WARN] MemSearch plugin install failed'
      claude plugin enable memsearch --scope user 2>&1 \
        || echo '[WARN] MemSearch plugin enable failed'

      # Health line: version, whether the DB and the ~558MB model are actually on
      # disk, and whether Claude really sees the plugin. Cheap, and it turns "is
      # memory working?" from a guess into one glance at the log.
      MS_VER=$("$MS_VENV/bin/pip" show memsearch 2>/dev/null | awk '/^Version:/{print $2}')
      MS_DB_SIZE=$([ -f "$MS_HOME/milvus.db" ] && du -h "$MS_HOME/milvus.db" | cut -f1 || echo 'not created yet')
      MS_MODEL_SIZE=$(du -sh "$HF_HOME" 2>/dev/null | cut -f1)
      if claude plugin list 2>/dev/null | grep -qi memsearch; then
        MS_PLUGIN='registered with Claude Code'
      else
        MS_PLUGIN='NOT visible to Claude Code — memory will not record anything'
      fi
      echo "[INFO] MemSearch ${MS_VER:-?} enabled (provider=onnx, model=$MEMSEARCH_MODEL); plugin $MS_PLUGIN"
      echo "[INFO] DB: $MS_HOME/milvus.db ($MS_DB_SIZE) | model cache: $HF_HOME (${MS_MODEL_SIZE:-empty}, downloads ~558MB on first use)"
    fi
  fi
else
  claude plugin disable memsearch --scope user >/dev/null 2>&1 || true
  echo '[INFO] MemSearch disabled'
fi

# --------------------------------------------------------------------------
# Maintenance action — the add-on config page has no buttons (the options schema
# only knows bool/list/str/int), so `maintenance` is a one-shot option instead:
# pick an action, save, let Home Assistant restart the add-on, and this block
# runs it and then resets the option back to "none" through the Supervisor API.
# The effect is a button, and the report lands in the add-on log.
#
# Deliberately placed after the MCP/MemSearch setup (so it can upgrade what those
# blocks installed) and before Remote Control and the UI (so it never races a
# running Claude process, and never sits between the user and their terminal for
# longer than the update actually takes).
#
# NOTE on the reset: POST /addons/self/options REPLACES the whole options object
# rather than patching one key — sending just {"maintenance":"none"} fails with
# "Missing option ...". Read the current options back first and edit that.
# --------------------------------------------------------------------------
MAINTENANCE=$(jq -r '.maintenance // "none"' /data/options.json)

maintenance_reset() {
  local opts payload
  opts=$(curl -sf -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
           http://supervisor/addons/self/info | jq -c '.data.options')
  if [ -z "$opts" ] || [ "$opts" = "null" ]; then
    echo '[WARN] Could not read back add-on options — `maintenance` stays set and will run again on the next restart'
    return 1
  fi
  payload=$(jq -nc --argjson o "$opts" '{options: ($o + {maintenance: "none"})}')
  if curl -sf -X POST -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
       -H 'Content-Type: application/json' -d "$payload" \
       http://supervisor/addons/self/options >/dev/null; then
    echo '[INFO] maintenance reset to "none"'
  else
    echo '[WARN] Could not reset `maintenance` — set it back to "none" by hand, or it runs again on every restart'
  fi
}

case "$MAINTENANCE" in
  check_updates) /usr/local/bin/maintenance.sh check;  maintenance_reset ;;
  update_all)    /usr/local/bin/maintenance.sh update; maintenance_reset ;;
  none|"")       : ;;
  *)             echo "[WARN] Unknown maintenance action '$MAINTENANCE' — ignoring" ;;
esac

# --------------------------------------------------------------------------
# Terminal renderer (ui_mode: terminal only)
#
# fullscreen — Claude Code's own alternate-screen renderer: virtualized
#              scrolling that actually works, no flicker, mouse support.
#              Copy-on-select travels over OSC 52, which needs BOTH
#              `set-clipboard on` here AND the shim injected into the ttyd
#              frontend below (xterm.js has no OSC 52 handler of its own).
#              Over plain http navigator.clipboard is unavailable — there,
#              Shift+drag gives a native selection that Ctrl+C copies.
# classic    — strip the alternate screen so TUI frames land in ttyd's own
#              scrollback, where the browser can select them without Shift.
#              That is what costs proper scrolling. Kept for old browsers and
#              as the fallback if the OSC 52 route ever stops working.
# upstream   — what robsonfelix/robsonfelix-hass-addons ships: like classic,
#              but tmux owns the mouse, so the wheel drives tmux copy-mode
#              history. Its historical copy/paste caveat is gone now that
#              set-clipboard + the shim carry tmux's own OSC 52 out.
#
# set-clipboard is "on" in every mode, never the default "external": under
# "external" tmux silently drops OSC 52 before it reaches the client, which
# kills copy-on-select in fullscreen and copy-mode copying in upstream alike.
# Measured on the wire, not assumed.
#
# Note that tmux emits `ESC ] 52 ; ; <base64>` — an EMPTY Pc parameter, unlike
# Claude Code's `52;c;`. The shim keys off `ESC ] 52 ;` for that reason; do not
# "simplify" it to a literal `52;c;` search or tmux's own copying stops working.
# --------------------------------------------------------------------------
RENDERER=$(jq -r '.terminal_renderer // "fullscreen"' /data/options.json)

# Sourced last in every mode so it wins. It lives in the HA config dir and thus
# survives restarts, rebuilds and reinstalls — unlike /root/.tmux.conf, which is
# rewritten from scratch on every start. This hook exists upstream; the fork had
# dropped it, and it is what lets tmux be tweaked without rebuilding the image.
TMUX_USER_OVERRIDE='source-file -q /homeassistant/.claudecode/tmux.conf'

case "$RENDERER" in
  classic)
    TUI_MODE=default
    cat > /root/.tmux.conf << 'TMUXEOF'
set -g history-limit 20000
# Strip the alternate screen so TUI frames land in ttyd's scrollback, where the
# browser can select them natively. This is what costs us proper scrolling.
set -ga terminal-overrides ',xterm*:smcup@:rmcup@'
set -g mouse off
set -g set-clipboard on
TMUXEOF
    ;;
  upstream)
    TUI_MODE=default
    cat > /root/.tmux.conf << 'TMUXEOF'
set -g history-limit 20000
set -ga terminal-overrides ',xterm*:smcup@:rmcup@'
# tmux owns the mouse here: the wheel drives copy-mode history. Selection goes to
# tmux rather than the browser — but with set-clipboard on, tmux emits its own
# OSC 52 and the ttyd shim puts it in the browser clipboard anyway. Shift+drag
# still bypasses tmux entirely and gives a native xterm.js selection.
set -g mouse on
set -g set-clipboard on
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
bind -n WheelDownPane select-pane -t= \; send-keys -M
TMUXEOF
    ;;
  *)
    RENDERER=fullscreen
    TUI_MODE=fullscreen
    cat > /root/.tmux.conf << 'TMUXEOF'
set -g history-limit 20000
# Mouse stays OFF at the tmux level on purpose: tmux must not capture it, it has
# to forward the events to Claude Code. Measured: with `mouse off` tmux still
# passes the application's ?1000h/?1002h/?1006h through to the client.
set -g mouse off
set -g set-clipboard on
TMUXEOF
    ;;
esac
echo "$TMUX_USER_OVERRIDE" >> /root/.tmux.conf

# The add-on option is an explicit switch in the UI, so it deliberately wins over
# a previous manual /tui choice.
mkdir -p /root/.claude
if [ -s /root/.claude/settings.json ]; then
  jq --arg t "$TUI_MODE" '.tui = $t' /root/.claude/settings.json > /tmp/.s.tmp \
    && mv /tmp/.s.tmp /root/.claude/settings.json
else
  printf '{"tui":"%s"}\n' "$TUI_MODE" > /root/.claude/settings.json
fi
echo "[INFO] Terminal renderer: $RENDERER (tui=$TUI_MODE)"

# --------------------------------------------------------------------------
# OSC 52 clipboard shim for the ttyd frontend.
#
# ttyd 1.7.7 bundles xterm.js, which registers OSC handlers 0,1,2,4,8,10,11,12,
# 104,110,111,112,1337 — and drops 52. Claude Code's fullscreen renderer copies
# the selection by emitting OSC 52, so without this the copy is a silent no-op.
# Updating ttyd would not help: 1.7.7 is the last release (2024-03-30) and
# xterm.js keeps OSC 52 in a separate addon rather than in core.
#
# ttyd embeds its frontend in the binary and the only supported way to replace it
# is --index, so the stock page is read out of a throwaway ttyd, the shim is
# injected, and the result is cached in /data. This happens at RUNTIME rather
# than during the build because the add-on is cross-built (aarch64 images are
# built on amd64) and ttyd cannot be executed there. The cache is keyed on the
# ttyd version plus the shim's hash, so editing either one rebuilds it.
#
# The shim is harmless in the other modes (no OSC 52 arrives in classic, and in
# upstream it is exactly what carries tmux copy-mode to the browser clipboard),
# so --index is not branched per renderer.
# --------------------------------------------------------------------------
TTYD_INDEX=/data/ttyd-index.html
TTYD_STAMP=/data/ttyd-index.stamp
SHIM=/usr/local/share/ttyd-osc52-shim.js
WANT_STAMP="$(ttyd --version 2>&1 | awk '{print $3}')-$(md5sum "$SHIM" 2>/dev/null | cut -c1-12)"

if [ "$UI_MODE" != "vscode" ] \
   && { [ ! -s "$TTYD_INDEX" ] || [ "$(cat "$TTYD_STAMP" 2>/dev/null)" != "$WANT_STAMP" ]; }; then
  ttyd --port 17681 --interface lo true >/dev/null 2>&1 &
  TTYD_TMP_PID=$!
  for _ in $(seq 1 20); do
    curl -sf http://127.0.0.1:17681/ -o /tmp/ttyd-index.raw && break
    sleep 0.25
  done
  kill "$TTYD_TMP_PID" 2>/dev/null || true
  if [ -s /tmp/ttyd-index.raw ]; then
    if python3 /usr/local/bin/inject-shim.py /tmp/ttyd-index.raw "$SHIM" "$TTYD_INDEX"; then
      echo "$WANT_STAMP" > "$TTYD_STAMP"
      echo '[INFO] ttyd frontend patched with the OSC 52 clipboard shim'
    else
      echo '[WARN] ttyd index patch failed — using the stock frontend (copy-on-select disabled)'
      rm -f "$TTYD_INDEX"
    fi
  else
    echo '[WARN] could not read the ttyd index — using the stock frontend (copy-on-select disabled)'
  fi
  rm -f /tmp/ttyd-index.raw
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

TTYD_INDEX_ARG=""
[ -s "$TTYD_INDEX" ] && TTYD_INDEX_ARG="--index $TTYD_INDEX"

cd /homeassistant
# shellcheck disable=SC2086  # TTYD_INDEX_ARG must word-split into two argv slots
exec ttyd --port 7681 --writable --ping-interval 30 --max-clients 5 \
  $TTYD_INDEX_ARG \
  -t fontSize="$FONT_SIZE" \
  -t fontFamily=Monaco,Consolas,monospace \
  -t scrollback=20000 \
  -t "theme=$COLORS" \
  $SHELL_CMD
