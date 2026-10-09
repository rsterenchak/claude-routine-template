#!/usr/bin/env node
// render-check.mjs — render a running preview at the viewports, routes and
// interaction steps a TODO.md `Verify:` line names, and write one PNG per shot
// to .verify/. The routine's <visual_verification> step (routine-base.md) runs
// this, then READS the PNGs and judges them against the task. Pure Node plus
// Playwright; no dependency is added to the repo that carries it.
//
// Usage:
//   node scripts/render-check.mjs --url http://localhost:4173/ "<Verify line>" [more lines]
//   node scripts/render-check.mjs --url http://localhost:4173/ --default
//
// A Verify line (the `- Verify:` prefix is optional):
//   1300x900, 390x844 → /                         two viewports, one route
//   920x600 → / ; click "Fight" ; wait 1500        route, then steps before the shot
//   1300x900 → /, /play                           two routes
//   1300x900 → / ; click "#settings" ; click text="+ Add target"
//
// Grammar:
//   <viewports> → <route-group> [, <route-group> …]
//   viewports    comma-separated WIDTHxHEIGHT
//   route-group  <route> [; <step> …]   — the steps run after the route loads,
//                in order, before the shot. A route listed twice with different
//                steps is two shots.
//   step         click <target> | type <target> "text" | press <Key> |
//                wait <ms> | hover <target> | scroll <px>
//   target       "visible text" (exact, case-insensitive) | a CSS selector
//                (#id, .class, tag[attr]) | a Playwright selector verbatim
//                (text=…, role=…, css=…)
//
// Output: .verify/<WxH>-<route-slug>[-<step-slug>].png per shot, plus
// .verify/manifest.json listing every shot with its viewport, route, steps and
// whether every step succeeded. A step that cannot run (target not found)
// still produces the shot — of whatever state the page reached — and marks
// the entry `stepsOk: false` so the judge knows the picture may not show the
// intended state. Exit code is 0 when every shot was written, 1 otherwise.
//
// Playwright resolution: the repo does not depend on it. claude-run.yml
// installs it once per run outside the repo and points PLAYWRIGHT_MODULE at
// it; locally, `npm i --prefix /tmp/pw playwright && npx playwright install
// chromium` then PLAYWRIGHT_MODULE=/tmp/pw/node_modules/playwright/index.mjs.
// Falls back to a plain `import('playwright')` for repos that happen to have it.
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const DEFAULT_LINE = "1300x900, 1300x700, 820x600, 390x844 → /";
const OUT_DIR = ".verify";

// ── args ────────────────────────────────────────────────────────────────────
const argv = process.argv.slice(2);
let baseUrl = "";
let useDefault = false;
const lines = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === "--url") baseUrl = argv[++i] || "";
  else if (a.startsWith("--url=")) baseUrl = a.slice(6);
  else if (a === "--default") useDefault = true;
  else if (a === "-h" || a === "--help") { usage(); process.exit(0); }
  else lines.push(a);
}
if (!baseUrl) { usage("--url is required (the preview URL from .claude/routine.md)"); process.exit(2); }
if (useDefault || lines.length === 0) lines.push(DEFAULT_LINE);
if (!baseUrl.endsWith("/")) baseUrl += "/";

function usage(err) {
  if (err) console.error(`render-check: ${err}`);
  console.error('usage: node scripts/render-check.mjs --url <preview url> "<Verify line>" [...]  |  --default');
}

// ── parse ───────────────────────────────────────────────────────────────────
// Returns [{ width, height, route, steps:[{kind,target,text,ms,px,key}] }].
function parseVerify(line) {
  let s = String(line).trim().replace(/^-\s*/, "").replace(/^Verify:\s*/i, "");
  // Accept →, ->, or => as the separator.
  const m = s.match(/^(.*?)\s*(?:→|->|=>)\s*(.*)$/);
  if (!m) throw new Error(`no "→" in Verify line: ${line}`);
  const viewports = m[1].split(",").map((v) => v.trim()).filter(Boolean).map((v) => {
    const vm = v.match(/^(\d+)\s*[x×]\s*(\d+)$/i);
    if (!vm) throw new Error(`bad viewport "${v}" (want WIDTHxHEIGHT)`);
    return { width: Number(vm[1]), height: Number(vm[2]) };
  });
  if (!viewports.length) throw new Error(`no viewports in Verify line: ${line}`);
  // Route groups are comma-separated, but a quoted step argument may contain a
  // comma, so split on commas outside quotes.
  const groups = splitOutsideQuotes(m[2], ",").map((g) => g.trim()).filter(Boolean);
  if (!groups.length) throw new Error(`no routes in Verify line: ${line}`);
  const shots = [];
  for (const g of groups) {
    const parts = splitOutsideQuotes(g, ";").map((p) => p.trim()).filter(Boolean);
    const route = parts.shift();
    if (!route.startsWith("/")) throw new Error(`route must start with "/": ${route}`);
    const steps = parts.map(parseStep);
    for (const vp of viewports) shots.push({ ...vp, route, steps });
  }
  return shots;
}

function splitOutsideQuotes(s, sep) {
  const out = []; let cur = ""; let q = null;
  for (const ch of s) {
    if (q) { cur += ch; if (ch === q) q = null; continue; }
    if (ch === '"' || ch === "'") { q = ch; cur += ch; continue; }
    if (ch === sep) { out.push(cur); cur = ""; continue; }
    cur += ch;
  }
  out.push(cur);
  return out;
}

function parseStep(raw) {
  const m = raw.match(/^(\w+)\s*(.*)$/);
  if (!m) throw new Error(`bad step: ${raw}`);
  const kind = m[1].toLowerCase(); const rest = m[2].trim();
  switch (kind) {
    case "click": case "hover":
      if (!rest) throw new Error(`${kind} needs a target`);
      return { kind, target: rest };
    case "type": {
      const tm = rest.match(/^(.*?)\s+("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')$/);
      if (!tm) throw new Error(`type needs: type <target> "text" — got: ${raw}`);
      return { kind, target: tm[1].trim(), text: unquote(tm[2]) };
    }
    case "press":
      if (!rest) throw new Error("press needs a key (Enter, Escape, Tab, …)");
      return { kind, key: rest };
    case "wait": {
      const ms = Number(rest); if (!Number.isFinite(ms) || ms < 0) throw new Error(`wait needs milliseconds: ${raw}`);
      return { kind, ms };
    }
    case "scroll": {
      const px = Number(rest); if (!Number.isFinite(px)) throw new Error(`scroll needs pixels: ${raw}`);
      return { kind, px };
    }
    default: throw new Error(`unknown step "${kind}" (click, type, press, wait, hover, scroll)`);
  }
}

function unquote(s) { return s.slice(1, -1).replace(/\\(["'\\])/g, "$1"); }

// A target in quotes is visible text; otherwise it is passed to Playwright as
// a selector (CSS, or an engine-prefixed one like text= / role=).
function locatorFor(page, target) {
  const t = target.trim();
  if (/^".*"$/.test(t) || /^'.*'$/.test(t)) {
    // Exact text, case-insensitive, trimmed — buttons and links usually.
    const text = unquote(t);
    return page.getByText(text, { exact: true }).first().or(page.getByRole("button", { name: text }).first());
  }
  return page.locator(t).first();
}

function slug(s) {
  return s.replace(/^\//, "").replace(/[^a-z0-9]+/gi, "-").replace(/^-+|-+$/g, "").toLowerCase() || "root";
}

// ── render ──────────────────────────────────────────────────────────────────
async function loadPlaywright() {
  const mod = process.env.PLAYWRIGHT_MODULE;
  try { return mod ? await import(mod) : await import("playwright"); }
  catch (e) {
    console.error("render-check: cannot load playwright. Set PLAYWRIGHT_MODULE to its index.mjs, or run `npm i --prefix /tmp/pw playwright` and point at /tmp/pw/node_modules/playwright/index.mjs.");
    console.error(String(e && e.message || e));
    process.exit(2);
  }
}

const shots = [];
for (const l of lines) shots.push(...parseVerify(l));
mkdirSync(OUT_DIR, { recursive: true });

const { chromium } = await loadPlaywright();
const launchOpts = {};
if (process.env.PLAYWRIGHT_CHROMIUM_PATH) launchOpts.executablePath = process.env.PLAYWRIGHT_CHROMIUM_PATH;
const browser = await chromium.launch(launchOpts);
const manifest = [];
let failures = 0;
try {
  for (const shot of shots) {
    const ctx = await browser.newContext({ viewport: { width: shot.width, height: shot.height }, deviceScaleFactor: 1, reducedMotion: "reduce" });
    const page = await ctx.newPage();
    const url = baseUrl + shot.route.replace(/^\//, "");
    const stepLog = [];
    let stepsOk = true;
    let file = `${shot.width}x${shot.height}-${slug(shot.route)}`;
    if (shot.steps.length) file += "-" + shot.steps.map((s) => s.kind + (s.target ? "-" + slug(s.target) : s.key ? "-" + slug(s.key) : "")).join("-").slice(0, 60);
    file = join(OUT_DIR, file + ".png");
    try {
      await page.goto(url, { waitUntil: "networkidle", timeout: 30000 });
      await page.waitForTimeout(500);
      for (const st of shot.steps) {
        try {
          switch (st.kind) {
            case "click": await locatorFor(page, st.target).click({ timeout: 8000 }); break;
            case "hover": await locatorFor(page, st.target).hover({ timeout: 8000 }); break;
            case "type": await locatorFor(page, st.target).fill(st.text, { timeout: 8000 }); break;
            case "press": await page.keyboard.press(st.key); break;
            case "wait": await page.waitForTimeout(st.ms); break;
            case "scroll": await page.mouse.wheel(0, st.px); await page.waitForTimeout(200); break;
          }
          stepLog.push({ ...st, ok: true });
        } catch (e) {
          stepsOk = false;
          stepLog.push({ ...st, ok: false, error: String(e && e.message || e).split("\n")[0] });
          console.error(`render-check: step failed (${st.kind} ${st.target || st.key || st.ms || st.px}) at ${shot.width}x${shot.height} ${shot.route}: ${stepLog.at(-1).error}`);
        }
      }
      await page.waitForTimeout(800);
      await page.screenshot({ path: file, fullPage: false });
      // How much of the document is below the fold, and whether the page can
      // scroll — the two facts a judge most often needs beside the picture.
      const metrics = await page.evaluate(() => ({
        scrollHeight: document.scrollingElement ? document.scrollingElement.scrollHeight : 0,
        innerHeight: window.innerHeight,
        bodyOverflowY: getComputedStyle(document.body).overflowY,
      }));
      manifest.push({ file, viewport: `${shot.width}x${shot.height}`, route: shot.route, url, steps: stepLog, stepsOk, metrics });
      console.log(`${stepsOk ? "shot" : "shot (steps incomplete)"}  ${file}  ${metrics.scrollHeight > metrics.innerHeight ? `(content ${metrics.scrollHeight}px tall in ${metrics.innerHeight}px viewport, overflow-y ${metrics.bodyOverflowY})` : "(fits)"}`);
    } catch (e) {
      failures++;
      manifest.push({ file, viewport: `${shot.width}x${shot.height}`, route: shot.route, url, steps: stepLog, stepsOk: false, error: String(e && e.message || e).split("\n")[0] });
      console.error(`render-check: FAILED ${shot.width}x${shot.height} ${shot.route}: ${String(e && e.message || e).split("\n")[0]}`);
    } finally {
      await ctx.close();
    }
  }
} finally {
  await browser.close();
}
writeFileSync(join(OUT_DIR, "manifest.json"), JSON.stringify({ baseUrl, lines, shots: manifest }, null, 2));
console.log(`render-check: ${manifest.length - failures}/${manifest.length} shots written to ${OUT_DIR}/ (manifest.json beside them)`);
process.exit(failures ? 1 : 0);
