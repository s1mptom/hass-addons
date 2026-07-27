# Claude Code for Home Assistant

Run [Claude Code](https://docs.anthropic.com/en/docs/claude-code), Anthropic's AI-powered coding assistant, directly in your Home Assistant sidebar with full access to your configuration.

## Quick Start

```bash
claude "List all my automations"
claude "Turn off all lights in the living room"
claude "Create an automation to turn on lights at sunset"
claude "Why isn't my motion sensor automation working?"
```

## Requirements

- Home Assistant OS or Supervised installation
- **64-bit architecture** — `amd64` or `aarch64` (32-bit was dropped in 1.3.0)
- [Anthropic account](https://console.anthropic.com/) (authentication handled in the add-on)

## Features

- **Two UI modes**: the classic browser terminal, or **full VS Code in the browser** with the native Claude Code extension — see [User Interface Modes](#user-interface-modes)
- **Config Access**: Read and write Home Assistant configuration files
- **hass-mcp Integration**: Direct control of HA entities and services
- **MemSearch** (optional): persistent semantic memory across sessions, fully local (ONNX embedder + Milvus Lite)
- **Playwright MCP** (optional): browser automation against the Playwright Browser add-on, plus downscaled screenshots
- **Auto-update**: installs the latest Claude Code at startup and re-checks every 12 hours
- **Session Persistence**: Optional tmux integration to preserve sessions across page refreshes
- **Secure Authentication**: Claude Code handles its own authentication securely

## User Interface Modes

The `ui_mode` option controls what the add-on's Web UI serves. **Both modes share the same
authentication, MCP servers, MemSearch memory and conversation history** — they are two
front-ends onto the same Claude Code state in `/homeassistant/.claudecode`. Switching only
needs an add-on restart, not a rebuild.

| `ui_mode` | What you get |
|-----------|--------------|
| `terminal` (default) | The ttyd web terminal. You run `claude` yourself. Lightest option. |
| `vscode` | Full VS Code in the browser ([code-server](https://github.com/coder/code-server)) with the [Claude Code extension](https://open-vsx.org/extension/Anthropic/claude-code) — chat panel, inline diffs, plan mode. |

In `vscode` mode the add-on installs the extension from Open VSX on first start (this
takes a minute and is logged), opens `/homeassistant` as the workspace so the extension
lists the same sessions as the CLI, and disables Workspace Trust — the extension declares
that it does not support untrusted workspaces, so without this it would stay silently
disabled. code-server's own state lives in `/data/vscode`, deliberately outside the
workspace.

Notes for `vscode` mode:

- `terminal_font_size`, `terminal_theme` and `session_persistence` apply to `terminal` mode only.
- The integrated terminal in VS Code still has `claude`, `ha`, `gh` and everything else on `PATH`.
- Default `settings.json` is seeded once with excludes for `.storage`, `*.db`, `*.log` and
  `.claudecode`, so VS Code does not index the HA database and the MemSearch model cache.
  Your own edits to it are preserved.

## Setup

### 1. Install the Add-on

1. Add the repository to Home Assistant
2. Install the "Claude Code" add-on
3. Start the add-on
4. Open the Web UI from the sidebar

### 2. Authenticate with Claude Code

On first launch, Claude Code will prompt you to authenticate:

1. Open the terminal from the HA sidebar
2. Type `claude` to start
3. Follow the authentication prompts
4. Your credentials are stored securely by Claude Code

**Note**: The add-on does NOT require you to enter API keys in the configuration. Claude Code handles authentication itself, storing credentials securely in its own configuration directory. This is more secure than storing keys in Home Assistant's add-on config.

## Using Claude Code

### Basic Usage

Once authenticated, Claude Code is ready to help with:

- Editing Home Assistant YAML configurations
- Creating automations and scripts
- Debugging configuration issues
- Writing custom integrations

### Home Assistant Integration

With hass-mcp enabled, Claude can:

- Query entity states: "What's the temperature in the living room?"
- Control devices: "Turn off all lights in the bedroom"
- List services: "What services are available for climate control?"
- Debug automations: "Why didn't my morning routine trigger?"

### Example Commands

```bash
# Start interactive session
claude

# One-off commands
claude "Add a new automation that turns on the porch light at sunset"
claude "Check my configuration.yaml for errors"
claude "List all unavailable entities"

# Continue previous conversation
claude --continue
```

### Keyboard Shortcuts

| Shortcut | Command |
|----------|---------|
| `c` | `claude` |
| `cc` | `claude --continue` |
| `ha-config` | Navigate to config directory |
| `ha-logs` | View Home Assistant logs |

## Configuration Options

| Option | Description | Default |
|--------|-------------|---------|
| `ui_mode` | `terminal` (ttyd) or `vscode` (code-server + Claude Code extension) | terminal |
| `enable_mcp` | Enable HA integration (hass-mcp) | true |
| `enable_playwright_mcp` | Enable Playwright MCP — needs the Playwright Browser add-on | false |
| `playwright_cdp_host` | Playwright Browser hostname; empty = auto-detect | "" |
| `terminal_font_size` | Font size (10-24) — `terminal` mode only | 14 |
| `terminal_theme` | dark or light — `terminal` mode only | dark |
| `working_directory` | Start directory | /homeassistant |
| `session_persistence` | Use tmux for persistent sessions — `terminal` mode only | true |
| `auto_update_claude` | Install latest Claude Code at startup, re-check every 12h | true |
| `memsearch_enabled` | Persistent semantic memory (local ONNX + Milvus Lite) | false |
| `memsearch_model` | MemSearch embedding model (~558 MB download on first use) | bge-m3 |

## File Locations

| Path | Description | Access |
|------|-------------|--------|
| `/homeassistant` | HA configuration directory | read-write |
| `/share` | Shared folder | read-write |
| `/media` | Media folder | read-write |
| `/ssl` | SSL certificates | read-only |
| `/backup` | Backups | read-only |

## Session Persistence

When `session_persistence` is enabled, the add-on uses tmux to maintain your terminal session. This means:

- Your session survives browser refreshes
- You can disconnect and reconnect without losing context
- Claude Code conversations are preserved

### tmux Commands

If you're new to tmux:

| Key | Action |
|-----|--------|
| `Ctrl+b d` | Detach from session (keeps it running) |
| `Ctrl+b [` | Enter scroll/copy mode (use arrow keys) |
| Mouse wheel | Scroll up/down — handled natively by the browser |
| `q` | Exit scroll/copy mode |

### Copy and Paste

Since 1.2.68 copy/paste is the normal browser behaviour. tmux no longer grabs the mouse
(`set -g mouse off`) and Claude's TUI is kept in `"tui": "default"`, so the web terminal
handles selection itself:

| Action | How to do it |
|--------|--------------|
| **Copy** | Just select the text with the mouse — it goes to the system clipboard automatically |
| **Paste** | `Ctrl+V` / `Cmd+V`, or right-click |

Scrolling is native too (the alternate screen buffer is disabled), with a 20,000 line
scrollback buffer.

#### Authenticating Claude Code (first launch)

The authentication URL can be long and may wrap across multiple lines. To handle this:

1. **Zoom out** your browser (`Ctrl + -` or `Cmd + -`) until the URL fits on a single line
2. **Click the link** — it should open in a new tab
3. Complete authentication in the browser and **copy the auth code**
4. Click back on the terminal and **paste** it

If clicking the link doesn't work, select the URL with your mouse (it is copied
automatically) and paste it into your browser's address bar.

### Scrolling and Session Persistence Trade-offs

**With tmux (`session_persistence: true`):**
- ✅ Session survives browser refresh/disconnect
- ✅ Can detach and reattach to running sessions
- ✅ Long-running Claude tasks continue in background
- ✅ Native browser scrolling and copy/paste (since 1.2.68)
- ✅ 20,000 line scrollback buffer

**Without tmux (`session_persistence: false`):**
- ✅ Simpler terminal behavior
- ❌ Session lost on browser refresh
- ❌ Session lost if add-on restarts

**Recommendation:** leave `session_persistence: true` (the default) — since 1.2.68 it no
longer costs you normal copy/paste, so there is little reason to turn it off.

## Security

### Authentication
- **No API keys in add-on config**: Claude Code handles authentication itself
- Credentials are stored securely in Claude Code's own directory (`~/.claude/`)
- This is more secure than storing keys in Home Assistant's configuration

### Container Security
- The Supervisor token is automatically managed and not exposed
- File access is limited to mapped directories
- The add-on runs in an isolated container

## Troubleshooting

### Authentication issues

Claude Code manages its own authentication. If you have issues:
1. Type `claude` to start the authentication flow
2. Follow the prompts to log in or enter your API key
3. Credentials are saved automatically for future sessions

**Can't copy the URL or paste the auth code?** See [Copy and Paste](#copy-and-paste) — selection copies automatically, and the URL may need browser zoom-out to stay on one line.

### hass-mcp not working

1. Verify `enable_mcp` is true in configuration
2. Check add-on logs for connection errors
3. Restart the add-on after configuration changes

### Terminal not loading

1. Check that the add-on is running (green indicator)
2. Try refreshing the page
3. Check browser console for errors
4. Review add-on logs for ttyd errors

### VS Code mode: the Claude Code panel is blank

If code-server shows **"code-server is being accessed in an insecure context"**, you are
reaching Home Assistant over plain HTTP (e.g. `http://192.168.1.x:8123`). Browsers only
grant a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts)
to HTTPS origins and `localhost`, and VS Code **webviews are disabled without one** — the
extension loads and activates, but its UI renders blank.

This is not specific to this add-on: the official Studio Code Server add-on hits the same
warning over HTTP, and VS Code upstream
([microsoft/vscode#311660](https://github.com/microsoft/vscode/issues/311660)) closed the
request to support webviews without a secure context as **out of scope** — webviews need
`crypto.subtle` and Service Workers, both of which browsers gate behind a secure context.
So it cannot be fixed from the server side.

It can be worked around from the client side. Options, cheapest first — the first two need
no certificates at all:

1. **Browser allowlist** (documented in the [code-server FAQ](https://coder.com/docs/code-server/FAQ)) —
   in Chrome/Edge open `chrome://flags/#unsafely-treat-insecure-origin-as-secure`, add your
   HA origin (e.g. `http://192.168.1.10:8123`), enable, restart the browser. Per browser,
   affects only that origin.
2. **Reach HA over `localhost`** — `localhost` and `127.0.0.1` are always secure contexts,
   so an SSH tunnel works: `ssh -L 8123:<ha-ip>:8123 user@<lan-host>`, then open
   `http://localhost:8123`.
3. **A real, publicly-trusted certificate** — Let's Encrypt via a TLS reverse proxy
   (Caddy, Nginx Proxy Manager, the NGINX SSL proxy add-on), Home Assistant Cloud
   (Nabu Casa), Tailscale's `*.ts.net` HTTPS, or a Cloudflare Tunnel. Nothing to install on
   client devices.
4. **A self-signed certificate is not enough on its own** — webviews still fail unless the
   CA is trusted on every client device (e.g. via `mkcert`).

`terminal` mode is unaffected — it works fine over plain HTTP.

### VS Code mode: no Claude Code panel

1. Check the add-on log for `Installing Claude Code VS Code extension from Open VSX` —
   the first start downloads it and needs network access
2. If the install failed, open the Extensions panel in VS Code and install **Claude Code**
   (publisher Anthropic) manually
3. Verify the CLI is present: open the VS Code terminal and run `claude --version`.
   The extension drives that binary — without it the panel cannot work
4. As a fallback, `claude` in the VS Code terminal always works, exactly as in `terminal` mode

### VS Code mode: slow, or high CPU/memory

The workspace is your HA config directory, which contains a large `home-assistant_v2.db`
and `.storage`. The add-on seeds `settings.json` with excludes for these on first start —
if you have overwritten it, re-add `files.watcherExclude` / `search.exclude` entries for
`**/.storage/**`, `**/*.db`, `**/*.log` and `**/.claudecode/**`.

### Session not persisting

1. Ensure `session_persistence` is set to true
2. The session is named "claude" - it will auto-attach on reconnect

### Configuration changes not applying

After changing configuration:
1. Save the configuration
2. Restart the add-on completely

## Support

- [GitHub Issues](https://github.com/s1mptom/hass-addons/issues)
- [Home Assistant Community](https://community.home-assistant.io/)
