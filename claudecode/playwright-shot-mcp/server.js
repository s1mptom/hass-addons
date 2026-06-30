#!/usr/bin/env node
/**
 * playwright-shot-mcp — a tiny, separate MCP server that adds ONE thing the
 * official @playwright/mcp can't do: a *downscaled* screenshot.
 *
 * Why a second server instead of patching @playwright/mcp?
 *   - The official package stays untouched, so it keeps updating from npm.
 *   - Both servers attach to the SAME Chromium over CDP (the Playwright Browser
 *     add-on at :9222), so this tool screenshots whatever page the official MCP
 *     navigated to.
 *
 * The point: the consumer (Claude) has a ~2000x2000 image limit. Naively fitting
 * a wide UI by shrinking the VIEWPORT reflows the layout (responsive breakpoints
 * change) — so Claude sees a different page than the human. Instead we keep the
 * viewport WIDE (the user's real resolution) and only shrink the resulting raster
 * via Chrome's native CDP `Page.captureScreenshot({clip:{scale}})`. Same layout,
 * fewer pixels. (deviceScaleFactor < 1 is ignored by Chrome for screenshots — see
 * the project spec — which is why we use clip.scale.)
 */
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { chromium } from "playwright-core";
import { writeFile } from "node:fs/promises";

function resolveEndpoint() {
  const argIdx = process.argv.indexOf("--cdp-endpoint");
  if (argIdx !== -1 && process.argv[argIdx + 1]) return process.argv[argIdx + 1];
  return (
    process.env.PLAYWRIGHT_SHOT_CDP ||
    process.env.PLAYWRIGHT_CDP_ENDPOINT ||
    "http://localhost:9222"
  );
}

const CDP_ENDPOINT = resolveEndpoint();

// Cache the CDP connection; reconnect if the browser went away.
let browserPromise = null;
async function getBrowser() {
  if (browserPromise) {
    try {
      const b = await browserPromise;
      if (b && b.isConnected()) return b;
    } catch {
      /* fall through and reconnect */
    }
    browserPromise = null;
  }
  browserPromise = chromium.connectOverCDP(CDP_ENDPOINT);
  return browserPromise;
}

/** Pick the page to shoot from the shared browser. */
async function pickPage(browser, urlFilter) {
  const pages = browser.contexts().flatMap((c) => c.pages());
  if (pages.length === 0) {
    const ctx = browser.contexts()[0] || (await browser.newContext());
    return ctx.newPage();
  }
  if (urlFilter) {
    const match = pages.find((p) => p.url().includes(urlFilter));
    if (match) return match;
  }
  // Prefer a real page over about:blank; default to the most recent.
  const real = pages.filter((p) => p.url() && p.url() !== "about:blank");
  const pool = real.length ? real : pages;
  return pool[pool.length - 1];
}

const server = new McpServer({
  name: "playwright-shot-mcp",
  version: "0.1.0",
});

server.tool(
  "take_screenshot_scaled",
  "Screenshot the shared Playwright browser and downscale the resulting PNG so it " +
    "fits an image-size limit WITHOUT reflowing the layout. Keeps the wide viewport " +
    "(the human's real resolution) and shrinks only the raster via CDP clip.scale. " +
    "Use this instead of resizing the viewport when you need to see the UI as the user does. " +
    "Pass `url` to navigate first, or omit it to capture the current page that the " +
    "official playwright MCP is on. Set `scale` (0.1-1) or `maxWidth` (auto scale).",
  {
    url: z
      .string()
      .url()
      .optional()
      .describe("If set, navigate the page here first; else shoot the current page."),
    urlFilter: z
      .string()
      .optional()
      .describe("Substring to pick which open tab to shoot (current-page mode)."),
    selector: z
      .string()
      .optional()
      .describe("CSS selector for element-only screenshot."),
    fullPage: z
      .boolean()
      .default(false)
      .describe("Capture the full scrollable page instead of just the viewport."),
    scale: z
      .number()
      .min(0.1)
      .max(1)
      .default(1)
      .describe("Downscale factor for the output PNG (1 = no scaling)."),
    maxWidth: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Target max PNG width in px; if set, scale is computed automatically."),
    width: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Set viewport width before capture (e.g. your monitor width, 2560)."),
    height: z
      .number()
      .int()
      .positive()
      .optional()
      .describe("Set viewport height before capture (used together with width)."),
    waitUntil: z
      .enum(["load", "domcontentloaded", "networkidle", "commit"])
      .default("load")
      .describe("Navigation wait condition (only when `url` is given)."),
    filename: z
      .string()
      .optional()
      .describe("Optional path to also save the PNG to (e.g. /homeassistant/shot.png)."),
  },
  async ({ url, urlFilter, selector, fullPage, scale, maxWidth, width, height, waitUntil, filename }) => {
    const browser = await getBrowser();
    const page = await pickPage(browser, url ? new URL(url).host : urlFilter);

    if (width) await page.setViewportSize({ width, height: height || 1440 });
    if (url) await page.goto(url, { waitUntil });

    const cdp = await page.context().newCDPSession(page);
    try {
      // 1. Work out the capture rectangle (CSS px).
      let rect;
      let mode;
      if (selector) {
        const box = await page.locator(selector).boundingBox();
        if (!box) throw new Error(`selector not found / not visible: ${selector}`);
        rect = box;
        mode = "element";
      } else {
        const metrics = await cdp.send("Page.getLayoutMetrics");
        if (fullPage) {
          const cs = metrics.cssContentSize;
          rect = { x: cs.x || 0, y: cs.y || 0, width: cs.width, height: cs.height };
          mode = "fullPage";
        } else {
          const lv = metrics.cssLayoutViewport;
          rect = { x: 0, y: 0, width: lv.clientWidth, height: lv.clientHeight };
          mode = "viewport";
        }
      }

      // 2. Effective scale: explicit maxWidth wins, else the scale factor.
      const eff = maxWidth ? Math.min(1, maxWidth / rect.width) : scale;

      // 3. Native downscale in the browser (no extra deps, no reflow).
      const clip = {
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        width: Math.round(rect.width),
        height: Math.round(rect.height),
        scale: eff,
      };
      const { data } = await cdp.send("Page.captureScreenshot", {
        format: "png",
        clip,
        captureBeyondViewport: mode === "fullPage",
      });

      if (filename) await writeFile(filename, Buffer.from(data, "base64"));

      const outW = Math.round(rect.width * eff);
      const outH = Math.round(rect.height * eff);
      const note =
        `Captured ${mode} ${Math.round(rect.width)}x${Math.round(rect.height)} CSS px ` +
        `→ scale x${eff.toFixed(3)} → ${outW}x${outH} px PNG` +
        (filename ? ` (saved to ${filename})` : "") +
        `\nLayout is unchanged (viewport stayed ${Math.round(rect.width)} wide); only the raster was shrunk.`;

      return {
        content: [
          { type: "image", data, mimeType: "image/png" },
          { type: "text", text: note },
        ],
      };
    } finally {
      await cdp.detach().catch(() => {});
    }
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
console.error(`[playwright-shot-mcp] ready, CDP endpoint: ${CDP_ENDPOINT}`);
