# s1mptom's Home Assistant Add-ons (fork)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

> **Fork notice:** This is a fork of [robsonfelix/robsonfelix-hass-addons](https://github.com/robsonfelix/robsonfelix-hass-addons), maintained at [s1mptom/hass-addons](https://github.com/s1mptom/hass-addons). All original work and credit go to **Robson Felix** (MIT). This fork adds local fixes — see each add-on's `CHANGELOG.md`.
>
> **Changes vs upstream:**
> - **Claude Code:**
>   - **VS Code in the browser** — new `ui_mode: vscode` serves code-server with the native [Claude Code extension](https://open-vsx.org/extension/Anthropic/claude-code) instead of the plain terminal, sharing the same auth, MCP servers and conversation history.
>   - **MemSearch** — optional persistent semantic memory across sessions, fully local (ONNX embedder + Milvus Lite). Required rebasing the image from Alpine to Debian, since its native deps ship glibc-only wheels.
>   - **Working Playwright MCP** — fixed the AppArmor `/opt` denial, the npx exec-bit problem and the MCP binary-name clash with hass-mcp, plus hostname auto-detection for the Playwright Browser add-on.
>   - **`playwright-shot` MCP** — a small extra MCP that captures wide UIs and downscales the PNG via CDP, so screenshots stay under the image size limit without reflowing the page.
>   - **Fixed auto-update** — `npm update -g` silently no-ops for global packages, so the add-on stayed pinned on an old build; now installs `@latest` at boot and re-checks every 12 hours.
>   - Terminal copy/paste fixed (native selection to the system clipboard).
> - **Playwright Browser:** fixed the build (`apt-get: not found`, upstream [#28](https://github.com/robsonfelix/robsonfelix-hass-addons/issues/28)) by pinning the base image directly, and upgraded Chromium to the latest `v1.61.1-noble`.

Custom add-ons for Home Assistant.

## Add-ons

| Add-on | Description |
|--------|-------------|
| [Claude Code](claudecode/) | AI assistant for automations, debugging, and smart home management — as a web terminal or full VS Code in the browser |
| [Auto-Monocle](auto-monocle/) | Auto-discover HA cameras and expose to Alexa via Monocle Gateway |
| [Playwright Browser](playwright-browser/) | Headless Chromium with CDP endpoint for browser automation |

> Add-ons from this fork show **"(Fork)"** in their name (e.g. *Playwright Browser (Fork)*) so they are easy to tell apart from the upstream repo in the Add-on Store.

## Installation

[![Add Repository](https://my.home-assistant.io/badges/supervisor_add_addon_repository.svg)](https://my.home-assistant.io/redirect/supervisor_add_addon_repository/?repository_url=https%3A%2F%2Fgithub.com%2Fs1mptom%2Fhass-addons)

Or manually: **Settings** → **Add-ons** → **Add-on Store** → **⋮** → **Repositories** → Add `https://github.com/s1mptom/hass-addons`

## License

MIT License — © Robson Felix (original author), fork by s1mptom.
