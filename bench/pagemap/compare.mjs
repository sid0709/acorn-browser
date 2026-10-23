// Measures one page three ways, for the comparison the page map was designed from: Chromium's
// DOM snapshot, Chromium's accessibility tree (raw and compacted Oak-style), and Oak's own
// serializer, bundled unmodified from the Oak submodule. Prints one JSON object per page: sizes,
// times, controls missed, hidden nodes kept, icon-only controls left nameless, prices kept.
//
// usage: node compare.mjs <url|file> [...]      → one JSON line per page, files in out/
// Needs bun for the Oak bundle (built once into oak.js) and Playwright (this folder's
// node_modules or the global one); CHROMIUM=<path> picks the browser.
import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

import { execFileSync } from 'node:child_process';

const { chromium } = (() => { try { return createRequire(import.meta.url)('playwright'); } catch { return createRequire('/opt/node22/lib/node_modules/')('playwright'); } })();

const here = path.dirname(new URL(import.meta.url).pathname);
const OAK_BUNDLE = path.join(here, 'oak.js');
if (!fs.existsSync(OAK_BUNDLE)) {
  // Oak's serializer and tree export, exactly as the extension ships them.
  const entry = path.join(here, 'oak-entry.ts');
  fs.writeFileSync(entry, `import { serializeDom } from '../../Oak/extension/src/content/dom-serializer';
import { formatAnalyzeTrees } from '../../Oak/shared/tree-export';
(window as any).__oak = { run() { const t0 = performance.now(); const tree = serializeDom(); const t1 = performance.now(); const { pureTree } = formatAnalyzeTrees(tree as any); return { pureTree, serializeMs: t1 - t0, formatMs: performance.now() - t1 }; } };
`);
  execFileSync('bun', ['build', entry, '--target=browser', '--format=iife', `--outfile=${OAK_BUNDLE}`], { stdio: 'inherit' });
  fs.unlinkSync(entry);
}
const OAK = fs.readFileSync(OAK_BUNDLE, 'utf8');
const OUT = path.join(here, 'out');
fs.mkdirSync(OUT, { recursive: true });

const INTERACTIVE_ROLES = new Set([
  'link', 'button', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'menuitem',
  'menuitemcheckbox', 'menuitemradio', 'tab', 'option', 'switch', 'slider', 'spinbutton',
  'listbox', 'treeitem',
]);
const PRICE = /[$£€]\s?\d[\d,]*(\.\d\d)?/g;

const kb = (n) => Math.round(n / 102.4) / 10;
const ms = (t0) => Math.round(performance.now() - t0);

// What a person can see and use on the page, counted in the page itself: the reference the
// three outputs are scored against.
const GROUND_TRUTH = () => {
  const sel = 'a[href],button,input:not([type=hidden]),select,textarea,summary,[role=button],[role=link],[role=checkbox],[role=radio],[role=tab],[role=menuitem],[role=combobox],[role=option],[onclick],[tabindex]:not([tabindex="-1"])';
  const all = [...document.querySelectorAll(sel)];
  const visible = all.filter((el) => el.checkVisibility?.({ checkOpacity: true, checkVisibilityCSS: true }) && el.getClientRects().length);
  const inView = visible.filter((el) => { const r = el.getBoundingClientRect(); return r.bottom > 0 && r.top < innerHeight; });
  // Prices a person can see: text nodes in visible elements.
  let prices = 0;
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  const re = /[$£€]\s?\d/;
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    if (re.test(n.textContent) && n.parentElement?.checkVisibility?.()) prices++;
  }
  return {
    elements: document.getElementsByTagName('*').length,
    interactive: all.length,
    interactiveVisible: visible.length,
    interactiveInView: inView.length,
    visiblePriceTexts: prices,
    pageHeight: document.documentElement.scrollHeight,
  };
};

// Oak's ids are stamped on the live page: how many of them sit on things a person cannot see,
// and how many visible controls got none.
const OAK_AUDIT = () => {
  const vis = (el) => el.checkVisibility?.({ checkOpacity: true, checkVisibilityCSS: true }) && el.getClientRects().length > 0;
  const stamped = [...document.querySelectorAll('[data-oak-id]')];
  const sel = 'a[href],button,input:not([type=hidden]),select,textarea,[role=button],[role=link],[role=checkbox],[role=radio],[role=combobox]';
  const controls = [...document.querySelectorAll(sel)].filter(vis);
  const name = (el) => (el.getAttribute('aria-label') || el.textContent || el.getAttribute('title') || el.getAttribute('alt') || el.querySelector('img[alt]')?.getAttribute('alt') || '').trim();
  return {
    stamped: stamped.length,
    stampedHidden: stamped.filter((el) => !vis(el)).length,
    visibleControlsMissed: controls.filter((el) => !el.hasAttribute('data-oak-id')).length,
    // Icon-only controls: their only name is an image's alt or a title, which Oak does not keep.
    iconOnlyControls: controls.filter((el) => !(el.getAttribute('aria-label') || el.textContent.trim()) && name(el)).length,
  };
};

/** The accessibility tree as one line per meaningful node, Oak-style. */
function compactAx(nodes) {
  const byId = new Map(nodes.map((n) => [n.nodeId, n]));
  const lines = [];
  let interactive = 0, nameless = 0, n = 0;
  const skip = new Set(['generic', 'none', 'InlineTextBox', 'LineBreak', 'RootWebArea', 'ListMarker']);
  const walk = (node, depth, parentName) => {
    if (!node) return;
    const role = node.role?.value ?? '';
    const name = String(node.name?.value ?? '').replace(/\s+/g, ' ').trim();
    let keep = !node.ignored && !skip.has(role);
    if (role === 'StaticText' && (!name || (parentName && parentName.includes(name)))) keep = false;
    let next = depth;
    if (keep) {
      const props = {};
      for (const p of node.properties ?? []) props[p.name] = p.value?.value;
      const states = [];
      for (const k of ['checked', 'selected', 'expanded', 'disabled', 'required', 'invalid', 'focused']) {
        if (props[k] !== undefined && props[k] !== false && props[k] !== 'false') states.push(props[k] === true || props[k] === 'true' ? k : `${k}=${props[k]}`);
      }
      const value = node.value?.value ? ` value="${String(node.value.value).slice(0, 80)}"` : '';
      const label = role === 'StaticText' ? `"${name.slice(0, 120)}"` : `${role}[${++n}]${name ? ` "${name.slice(0, 120)}"` : ''}${value}${states.length ? ' ' + states.join(' ') : ''}`;
      lines.push('  '.repeat(depth) + label);
      if (INTERACTIVE_ROLES.has(role)) { interactive++; if (!name) nameless++; }
      next = depth + 1;
    }
    for (const id of node.childIds ?? []) walk(byId.get(id), next, keep && role !== 'StaticText' ? name : parentName);
  };
  walk(nodes[0], 0, '');
  return { text: lines.join('\n'), interactive, nameless };
}

async function measure(browser, target) {
  const url = /^https?:|^file:/.test(target) ? target : 'file://' + path.resolve(target);
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  const r = { url };
  let t0 = performance.now();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
  r.loadMs = ms(t0);
  r.title = await page.title();
  r.truth = await page.evaluate(GROUND_TRUTH);

  t0 = performance.now();
  const html = await page.content();
  r.rawHtml = { kb: kb(Buffer.byteLength(html)), ms: ms(t0) };

  t0 = performance.now();
  const jpeg = await page.screenshot({ type: 'jpeg', quality: 80 });
  r.screenshot = { kb: kb(jpeg.length), ms: ms(t0), screensForWholePage: Math.ceil(r.truth.pageHeight / 800) };

  const cdp = await page.context().newCDPSession(page);
  await cdp.send('DOM.enable');
  await cdp.send('Accessibility.enable');

  t0 = performance.now();
  const snap = await cdp.send('DOMSnapshot.captureSnapshot', { computedStyles: ['display', 'visibility', 'opacity', 'cursor'], includeDOMRects: true });
  const snapJson = JSON.stringify(snap);
  r.domSnapshot = { kb: kb(Buffer.byteLength(snapJson)), ms: ms(t0), nodes: snap.documents.reduce((s, d) => s + d.nodes.nodeType.length, 0), layoutNodes: snap.documents.reduce((s, d) => s + d.layout.nodeIndex.length, 0) };

  t0 = performance.now();
  const { nodes } = await cdp.send('Accessibility.getFullAXTree');
  const axMs = ms(t0);
  const axJson = JSON.stringify(nodes);
  t0 = performance.now();
  const ax = compactAx(nodes);
  r.axTree = { rawKb: kb(Buffer.byteLength(axJson)), ms: axMs, nodes: nodes.length, notIgnored: nodes.filter((n) => !n.ignored).length, compactKb: kb(Buffer.byteLength(ax.text)), compactLines: ax.text.split('\n').length, compactMs: ms(t0), interactive: ax.interactive, nameless: ax.nameless, prices: (ax.text.match(PRICE) ?? []).length };

  await page.addScriptTag({ content: OAK });
  t0 = performance.now();
  const oak = await page.evaluate(() => window.__oak.run());
  const oakMs = ms(t0);
  const oakNameless = oak.pureTree.split('\n').filter((l) => /^\s*(a|button)\[\d+\]/.test(l) && !/aria-label=|"[^"]+"\s*$/.test(l)).length;
  r.oak = { kb: kb(Buffer.byteLength(oak.pureTree)), lines: oak.pureTree.split('\n').length, ms: oakMs, serializeMs: Math.round(oak.serializeMs), prices: (oak.pureTree.match(PRICE) ?? []).length, namelessLinksButtons: oakNameless, ...(await page.evaluate(OAK_AUDIT)) };

  const slug = new URL(url).hostname.replace(/\W+/g, '_') || path.basename(target).replace(/\W+/g, '_');
  fs.writeFileSync(path.join(OUT, `${slug}.oak.txt`), oak.pureTree);
  fs.writeFileSync(path.join(OUT, `${slug}.ax.txt`), ax.text);
  fs.writeFileSync(path.join(OUT, `${slug}.jpg`), jpeg);
  await page.close();
  return r;
}

const browser = await chromium.launch({ ...(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {}) });
for (const target of process.argv.slice(2)) {
  try {
    console.log(JSON.stringify(await measure(browser, target)));
  } catch (err) {
    console.log(JSON.stringify({ url: target, error: String(err).slice(0, 300) }));
  }
}
await browser.close();
