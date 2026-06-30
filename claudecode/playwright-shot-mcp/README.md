# playwright-shot-mcp

A tiny MCP server that adds **one** tool the official `@playwright/mcp` lacks:
a *downscaled* screenshot.

## Why it exists

Claude (the image consumer) has a ~2000×2000 px limit. The naive way to fit a
wide dashboard is to shrink the **viewport** — but that reflows the layout
(responsive breakpoints change), so Claude sees a *different* page than the human.

This server keeps the viewport **wide** (the user's real resolution) and shrinks
only the **raster** of the output PNG, using Chrome's native CDP
`Page.captureScreenshot({ clip: { scale } })`. Same layout, fewer pixels.
(`deviceScaleFactor < 1` is ignored by Chrome for screenshots — that's why we use
`clip.scale`.)

## How it runs

- Runs **alongside** the official `@playwright/mcp` — that package is never
  modified, so it keeps updating from npm.
- Both attach to the **same** Chromium over CDP (the Playwright Browser add-on at
  `:9222`), so this tool screenshots whatever page the official MCP navigated to.
- Registered automatically by the Claude Code add-on when `enable_playwright_mcp`
  is on (installed to `/opt/playwright-shot-mcp`, launched via `node server.js`).

CDP endpoint resolution order: `--cdp-endpoint <url>` arg → `PLAYWRIGHT_SHOT_CDP`
→ `PLAYWRIGHT_CDP_ENDPOINT` → `http://localhost:9222`.

## Tool: `take_screenshot_scaled`

| Param | Type | Notes |
|-------|------|-------|
| `scale` | 0.1–1 (default 1) | Downscale factor for the PNG. |
| `maxWidth` | int px | If set, `scale` is computed as `min(1, maxWidth/width)`. |
| `fullPage` | bool | Full scrollable page vs just the viewport. |
| `selector` | css | Element-only screenshot. |
| `url` | url | Navigate here first; omit to shoot the current page. |
| `urlFilter` | string | Substring to pick which open tab to shoot. |
| `width` / `height` | int px | Set the viewport (e.g. your monitor width, `2560`) before capture. |
| `waitUntil` | enum | Navigation wait condition when `url` is given. |
| `filename` | path | Optionally also save the PNG (e.g. `/homeassistant/shot.png`). |

Returns the PNG as MCP image content plus a text note with the capture mode and
the original→scaled dimensions.

### Example

```
take_screenshot_scaled({ width: 2560, height: 1440, fullPage: true, maxWidth: 1600 })
```

Renders the page at 2560-wide (the user's layout) and returns a ~1600 px PNG that
fits Claude's limit.
