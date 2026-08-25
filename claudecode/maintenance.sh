#!/usr/bin/env bash
# Component inventory and forced upgrades for the Claude Code add-on.
#
#   maintenance.sh check    report installed vs. latest for every component
#   maintenance.sh update   upgrade everything upgradable from inside the running
#                           container, then report
#
# Driven by the `maintenance` add-on option (run.sh runs this at startup and then
# resets the option back to `none`, so it behaves like a button in the add-on
# configuration page). Also available directly in the terminal as
# `cc-check-updates` / `cc-update-all`.
#
# The split that matters: some components are installed by package managers that
# work at runtime (npm, pip, Open VSX) and can be upgraded here without touching
# the image. Others are baked into the image by the Dockerfile as pinned
# tarballs/static binaries — Node, code-server and the Docker CLI. Upgrading
# those in place would be silently undone by the next add-on Update or Rebuild,
# so they are only *reported*, with a note to run a Rebuild.
#
# Every network lookup is best-effort: an unreachable registry prints `?` and
# never aborts the run, because this script executes on the add-on's startup path
# and must not be able to keep the terminal from coming up.

set -o pipefail

ACTION="${1:-check}"
PERSIST_DIR=/homeassistant/.claudecode
MS_VENV="$PERSIST_DIR/memsearch-venv"
CS_DATA=/data/vscode
CS_EXT=/data/vscode/extensions

NET_TIMEOUT=20
fetch() { curl -sf --max-time "$NET_TIMEOUT" "$@" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
OUTDATED=0
REBUILD_NEEDED=0

ver_or_unknown() { local v="$1"; [ -n "$v" ] && [ "$v" != "null" ] && echo "$v" || echo "?"; }

# report <component> <installed> <latest> [rebuild]
# "rebuild" marks a component that only a full add-on Rebuild can move.
report() {
  local name="$1" have latest kind status
  have=$(ver_or_unknown "$2"); latest=$(ver_or_unknown "$3"); kind="${4:-runtime}"
  if [ "$have" = "?" ]; then
    status="not installed"
  elif [ "$latest" = "?" ]; then
    status="latest unknown"
  elif [ "$have" = "$latest" ]; then
    status="up to date"
  else
    status="OUTDATED"
    if [ "$kind" = "rebuild" ]; then
      REBUILD_NEEDED=$((REBUILD_NEEDED + 1))
      status="OUTDATED (needs add-on Rebuild)"
    else
      OUTDATED=$((OUTDATED + 1))
    fi
  fi
  printf '[INFO]   %-26s %-12s -> %-12s %s\n' "$name" "$have" "$latest" "$status"
}

# ---------------------------------------------------------------------------
# Installed versions
# ---------------------------------------------------------------------------
have_claude()    { claude --version 2>/dev/null | awk '{print $1}'; }
have_memsearch() { [ -x "$MS_VENV/bin/pip" ] && "$MS_VENV/bin/pip" show memsearch 2>/dev/null | awk '/^Version:/{print $2}'; }
have_hassmcp()   { pip3 show hass-mcp 2>/dev/null | awk '/^Version:/{print $2}'; }
have_pwmcp()     { jq -r '.version // empty' /opt/playwright-mcp/node_modules/@playwright/mcp/package.json 2>/dev/null; }
have_gh()        { gh --version 2>/dev/null | head -1 | awk '{print $3}'; }
# `ha` has no --version flag, and `ha cli info` reports the Supervisor cli plugin
# (CalVer) rather than this binary, so the installed tag is stamped at download
# time — by the Dockerfile during the build, and by update_ha_cli below.
HA_VER_FILE=/usr/local/share/ha-cli.version
have_ha()        { cat "$HA_VER_FILE" 2>/dev/null; }
have_node()      { node --version 2>/dev/null | tr -d 'v'; }
have_codeserver() { code-server --version 2>/dev/null | head -1 | awk '{print $1}'; }
have_docker()    { docker --version 2>/dev/null | awk '{print $3}' | tr -d ','; }
have_ext() {
  [ -d "$CS_EXT" ] || return 0
  code-server --user-data-dir "$CS_DATA" --extensions-dir "$CS_EXT" \
    --list-extensions --show-versions 2>/dev/null \
    | grep -i '^anthropic\.claude-code@' | head -1 | cut -d@ -f2
}

# ---------------------------------------------------------------------------
# Latest versions
# ---------------------------------------------------------------------------
latest_npm()  { npm view "$1" version 2>/dev/null | tail -1; }
latest_pypi() { fetch "https://pypi.org/pypi/$1/json" | jq -r '.info.version // empty'; }
latest_gh_release() { fetch "https://api.github.com/repos/$1/releases/latest" | jq -r '.tag_name // empty' | sed 's/^v//'; }
# Newest Node LTS line, matching what the Dockerfile pins by hand.
latest_node() { fetch https://nodejs.org/dist/index.json | jq -r '[.[] | select(.lts != false)][0].version // empty' | sed 's/^v//'; }
latest_ext()  { fetch https://open-vsx.org/api/Anthropic/claude-code/latest | jq -r '.version // empty'; }
# Docker publishes static builds as a plain directory index, with no API. Take the
# highest stable version listed for this architecture.
arch_docker() { case "$(uname -m)" in x86_64) echo x86_64 ;; aarch64) echo aarch64 ;; *) echo x86_64 ;; esac; }
latest_docker() {
  local arch
  arch=$(arch_docker)
  fetch "https://download.docker.com/linux/static/stable/${arch}/" \
    | grep -oE 'docker-[0-9]+\.[0-9]+\.[0-9]+\.tgz' \
    | sed -E 's/^docker-(.*)\.tgz$/\1/' | sort -V | tail -1
}

# ---------------------------------------------------------------------------
# Upgrades — runtime components only
# ---------------------------------------------------------------------------
step() { echo "[INFO] --- $* ---"; }
warn_fail() { echo "[WARN] $* failed — leaving the installed version in place"; }

# Static release binaries (gh, ha) are re-downloaded rather than package-managed.
# They land in /usr/local/bin, which is part of the image, so an add-on Update or
# Rebuild resets them to whatever the Dockerfile fetched. That is fine: the
# Dockerfile pulls `latest` for both, so a Rebuild is never a downgrade.
arch_gh()     { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64) echo arm64 ;; *) echo amd64 ;; esac; }
arch_ha()     { case "$(uname -m)" in x86_64) echo amd64 ;; aarch64) echo aarch64 ;; *) echo amd64 ;; esac; }
CURL_RETRY=(--retry 5 --retry-all-errors --retry-delay 3 --connect-timeout 20)

update_gh() {
  local ver arch tmp
  ver=$(latest_gh_release cli/cli); arch=$(arch_gh)
  [ -n "$ver" ] || { warn_fail "gh version lookup"; return 1; }
  [ "$ver" = "$(have_gh)" ] && { echo "[INFO] gh already $ver"; return 0; }
  tmp=$(mktemp -d)
  if curl -fsSL "${CURL_RETRY[@]}" \
       "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_${arch}.tar.gz" -o "$tmp/gh.tgz" \
     && tar -xzf "$tmp/gh.tgz" -C "$tmp" \
     && install -m 0755 "$tmp"/gh_*/bin/gh /usr/local/bin/gh; then
    echo "[INFO] gh updated to $ver"
  else
    warn_fail "gh update"
  fi
  rm -rf "$tmp"
}

update_ha_cli() {
  local ver arch tmp
  ver=$(latest_gh_release home-assistant/cli); arch=$(arch_ha)
  [ -n "$ver" ] || { warn_fail "ha CLI version lookup"; return 1; }
  [ "$ver" = "$(have_ha)" ] && { echo "[INFO] ha CLI already $ver"; return 0; }
  tmp=$(mktemp -d)
  if curl -fsSL "${CURL_RETRY[@]}" \
       "https://github.com/home-assistant/cli/releases/download/${ver}/ha_${arch}" -o "$tmp/ha" \
     && install -m 0755 "$tmp/ha" /usr/local/bin/ha; then
    printf '%s\n' "$ver" > "$HA_VER_FILE"
    echo "[INFO] ha CLI updated to $ver"
  else
    warn_fail "ha CLI update"
  fi
  rm -rf "$tmp"
}

do_update() {
  step "Claude Code (npm)"
  npm install -g @anthropic-ai/claude-code@latest 2>&1 || warn_fail "Claude Code update"
  hash -r 2>/dev/null || true

  step "Python helpers (hass-mcp, pymodbus, pyserial, websockets)"
  pip3 install --no-cache-dir --upgrade hass-mcp pymodbus pyserial websockets 2>&1 || warn_fail "pip upgrade"

  if [ -x "$MS_VENV/bin/pip" ]; then
    step "MemSearch (venv)"
    # Errors are deliberately NOT silenced here. The add-on has already lost weeks
    # of memory once to a failure that was swallowed by >/dev/null (AppArmor
    # blocking the plugin's hook helpers), so anything that goes wrong with
    # MemSearch must be visible in the add-on log.
    "$MS_VENV/bin/pip" install --no-cache-dir --upgrade "memsearch[onnx]" 2>&1 || warn_fail "MemSearch upgrade"
    step "MemSearch Claude plugin"
    # `memsearch-plugins` is the marketplace; `memsearch` is the plugin inside it.
    # Passing the plugin name to `marketplace update` fails with
    # "Marketplace 'memsearch' not found".
    claude plugin marketplace update memsearch-plugins 2>&1 || warn_fail "MemSearch marketplace update"
    claude plugin install memsearch --scope user 2>&1 || true
  else
    echo '[INFO] MemSearch not installed (memsearch_enabled is off) — skipped'
  fi

  step "Playwright MCP servers (npm)"
  ( cd /opt/playwright-mcp && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install @playwright/mcp@latest 2>&1 ) || warn_fail "Playwright MCP upgrade"
  ( cd /opt/playwright-shot-mcp && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm update --omit=dev 2>&1 ) || warn_fail "playwright-shot MCP upgrade"

  step "GitHub CLI (gh)"
  update_gh
  step "Home Assistant CLI (ha)"
  update_ha_cli

  if [ -d "$CS_EXT" ]; then
    step "Claude Code VS Code extension (Open VSX)"
    code-server --user-data-dir "$CS_DATA" --extensions-dir "$CS_EXT" \
      --install-extension Anthropic.claude-code --force 2>&1 || warn_fail "extension update"
  else
    echo '[INFO] VS Code extension not installed (ui_mode is not vscode) — skipped'
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$ACTION" in
  update)
    echo '[INFO] === Maintenance: updating every runtime-upgradable component ==='
    do_update
    echo '[INFO] === Update finished, re-checking versions ==='
    ;;
  check) echo '[INFO] === Maintenance: component version check ===' ;;
  *) echo "usage: $0 check|update" >&2; exit 2 ;;
esac

echo '[INFO] Runtime components (upgradable from this container):'
report 'Claude Code'        "$(have_claude)"     "$(latest_npm @anthropic-ai/claude-code)"
report 'MemSearch'          "$(have_memsearch)"  "$(latest_pypi memsearch)"
report 'hass-mcp'           "$(have_hassmcp)"    "$(latest_pypi hass-mcp)"
report 'Playwright MCP'     "$(have_pwmcp)"      "$(latest_npm @playwright/mcp)"
report 'GitHub CLI (gh)'    "$(have_gh)"         "$(latest_gh_release cli/cli)"
report 'Home Assistant CLI' "$(have_ha)"         "$(latest_gh_release home-assistant/cli)"
report 'VS Code extension'  "$(have_ext)"        "$(latest_ext)"

echo '[INFO] Image components (only an add-on Rebuild can move these):'
report 'Node.js'            "$(have_node)"       "$(latest_node)"        rebuild
report 'code-server'        "$(have_codeserver)" "$(latest_gh_release coder/code-server)" rebuild
report 'Docker CLI'         "$(have_docker)"     "$(latest_docker)"      rebuild

if [ "$OUTDATED" -gt 0 ]; then
  echo "[INFO] $OUTDATED runtime component(s) out of date — set maintenance: update_all (or run cc-update-all)"
fi
if [ "$REBUILD_NEEDED" -gt 0 ]; then
  echo "[INFO] $REBUILD_NEEDED image component(s) out of date — bump the pins in the Dockerfile and Rebuild the add-on"
fi
if [ "$OUTDATED" -eq 0 ] && [ "$REBUILD_NEEDED" -eq 0 ]; then
  echo '[INFO] Everything is current'
fi
echo '[INFO] === Maintenance done ==='
