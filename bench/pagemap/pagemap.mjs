// Reference builder of the page map, on the raw DevTools answers, to validate the join before
// the same logic is written in Swift (app/Sources/App/PageMap.swift). Output is the shape the
// harness reads (harness/src/page.rs): a flat, depth-first list of nodes.
//
// usage: node pagemap.mjs [--scroll=<px>] <url|file> ...   → out/<slug>.page.json and out/<slug>.page.txt
// The harness's fixtures (harness/src/fixtures/*.page.json) are its output on pages/*.html.
// With --scroll the page is scrolled that far down before the capture (out/<slug>-scrolled.*):
// the boxes are in page coordinates and must come out the same as without.

import { createRequire } from 'node:module';
import fs from 'node:fs';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
// Playwright from this folder's node_modules, else the kit's, else the global one.
const { chromium } = (() => {
  for (const from of [import.meta.url, path.join(here, '../../kit/browser/node_modules/'), '/opt/node22/lib/node_modules/']) {
    try { return createRequire(from)('playwright'); } catch {}
  }
  throw new Error('playwright is not installed here, in kit/browser, or globally');
})();
const OUT = path.join(here, 'out');
fs.mkdirSync(OUT, { recursive: true });

// Roles a person acts on. Anything else with a name or text is kept as content.
const CONTROL_ROLES = new Set([
  'link', 'button', 'textbox', 'searchbox', 'combobox', 'checkbox', 'radio', 'menuitem',
  'menuitemcheckbox', 'menuitemradio', 'tab', 'option', 'switch', 'slider', 'spinbutton',
  'listbox', 'treeitem', 'menubutton', 'ListBoxOption', 'DisclosureTriangle', 'Iframe',
]);
// Structure worth a line of its own, when named.
const GROUP_ROLES = new Set(['heading', 'radiogroup', 'group', 'form', 'navigation', 'main', 'banner',
  'contentinfo', 'region', 'search', 'dialog', 'alertdialog', 'alert', 'list', 'listitem', 'table', 'row',
  'cell', 'columnheader', 'rowheader', 'tablist', 'menu', 'menubar', 'tree', 'article', 'section',
  'complementary', 'figure', 'img', 'image', 'Iframe', 'status', 'log', 'progressbar', 'definition', 'term']);
// Internal roles that are never a line.
const SKIP_ROLES = new Set(['none', 'generic', 'InlineTextBox', 'LineBreak', 'ListMarker', 'RootWebArea', 'LabelText', 'Legend', 'Caption', 'paragraph', 'Pre', 'blockquote', 'code', 'emphasis', 'strong', 'superscript', 'subscript', 'time', 'Abbr', 'deletion', 'insertion', 'mark', 'Ruby', 'Details', 'Summary', 'Canvas', 'SvgRoot', 'DescriptionList', 'DescriptionListTerm', 'DescriptionListDetail']);
const STATE_PROPS = ['checked', 'selected', 'expanded', 'disabled', 'required', 'invalid', 'focused', 'pressed', 'readonly', 'multiselectable', 'hasPopup', 'level', 'valuemin', 'valuemax'];
const MAX_NAME = 120;
const MAX_TEXT = 160;

const clean = (s) => String(s ?? '').replace(/\s+/g, ' ').trim();
// A text cut to its limit ends with an ellipsis: the harness numbers such a line, and `read`
// fetches the whole of it.
const cut = (s, max) => (s.length <= max ? s : s.slice(0, max - 1) + '…');

/** The snapshot's layout, by backendNodeId: document box, styles, clickable, live values. */
function layoutIndex(snap) {
  const S = snap.strings;
  const by = new Map();
  // Which document each iframe element holds, by the element's backendNodeId.
  const childDoc = new Map();
  snap.documents.forEach((doc) => {
    (doc.nodes.contentDocumentIndex?.index ?? []).forEach((i, k) => childDoc.set(doc.nodes.backendNodeId[i], snap.strings[snap.documents[doc.nodes.contentDocumentIndex.value[k]].frameId]));
  });
  by.childDoc = childDoc;
  // Layout bounds are in the coordinates of the node's own document, wherever that document is
  // scrolled to (Chromium 154 and Playwright's both): the main document's are page coordinates
  // as they are. A child document sits where the iframe element that holds it is, less what the
  // child has scrolled; that offset moves its boxes onto the page.
  const offsets = snap.documents.map(() => [0, 0]);
  snap.documents.forEach((doc, d) => {
    const n = doc.nodes;
    (n.contentDocumentIndex?.index ?? []).forEach((i, k) => {
      const child = n.contentDocumentIndex.value[k];
      const at = doc.layout.nodeIndex.indexOf(i);
      if (at >= 0) {
        const [x, y] = doc.layout.bounds[at];
        const inner = snap.documents[child];
        offsets[child] = [offsets[d][0] + x - (inner.scrollOffsetX ?? 0), offsets[d][1] + y - (inner.scrollOffsetY ?? 0)];
      }
    });
  });
  snap.documents.forEach((doc, d) => {
    const [ox, oy] = offsets[d];
    const n = doc.nodes;
    const clickable = new Set(n.isClickable?.index ?? []);
    const checked = new Set(n.inputChecked?.index ?? []);
    const selected = new Set(n.optionSelected?.index ?? []);
    const values = new Map((n.inputValue?.index ?? []).map((i, k) => [i, S[n.inputValue.value[k]]]));
    const attrs = (i) => { const a = n.attributes[i] ?? []; const o = {}; for (let k = 0; k < a.length; k += 2) o[S[a[k]]] = S[a[k + 1]]; return o; };
    const L = doc.layout;
    for (let k = 0; k < L.nodeIndex.length; k++) {
      const i = L.nodeIndex[k];
      const [x, y, w, h] = L.bounds[k];
      const st = (L.styles[k] ?? []).map((s) => S[s]);
      const entry = {
        box: [x + ox, y + oy, w, h], frame: d,
        display: st[0], visibility: st[1], opacity: st[2], cursor: st[3],
        clickable: clickable.has(i), checked: checked.has(i), selected: selected.has(i),
        value: values.get(i), tag: S[n.nodeName[i]], attrs: attrs(i), frameId: doc.frameId,
        nodeType: n.nodeType[i],
      };
      by.set(n.backendNodeId[i], entry);
    }
    // Nodes without layout (display:none, head) still get their attributes.
    for (let i = 0; i < n.backendNodeId.length; i++) {
      if (!by.has(n.backendNodeId[i])) by.set(n.backendNodeId[i], { box: null, tag: S[n.nodeName[i]], attrs: attrs(i), clickable: clickable.has(i), checked: checked.has(i), selected: selected.has(i), value: values.get(i), frameId: doc.frameId, nodeType: n.nodeType[i], frame: d });
    }
  });
  return by;
}

/** Whether a laid-out node can be seen at all. A node that is only transparent (`opacity: 0`)
 * is kept when `transparent` says so: a radio or a checkbox styled through its label sits
 * see-through over the drawn circle or box, named by the label, and takes the click. */
function visible(l, transparent = false) {
  if (!l || !l.box) return false;
  const [, , w, h] = l.box;
  if (w <= 0 || h <= 0) return false;
  if (l.display === 'none' || l.visibility === 'hidden' || l.visibility === 'collapse') return false;
  if (!transparent && l.opacity !== undefined && Number(l.opacity) === 0) return false;
  // Parked off the page (left: -9999px) or clipped to a dot (screen-reader-only text).
  const [x, y] = l.box;
  if (x + w <= 0 || y + h <= 0) return false;
  if (w <= 1 && h <= 1) return false;
  return true;
}

/** Class tokens a person can read: words, not hashes. */
function readableClasses(attrs) {
  return clean(attrs?.class ?? '').split(' ').filter((c) => c && /^[a-z][a-z-]{2,30}$/i.test(c) && !/[0-9]{3,}|^(css|sc|jss|_)-?/i.test(c)).slice(0, 3).join(' ');
}

// `trees` maps a frameId to that frame's own accessibility tree (the main frame's tree does not
// hold the nodes of its child frames).
export function buildPageMap(ax, snap, viewport, trees = new Map()) {
  const byAx = new Map(ax.nodes.map((n) => [n.nodeId, n]));
  // The app's Chromium reports the snapshot's boxes in the screen's pixels on a Retina
  // display (Playwright's emulation does not): the document's width says which.
  const ratio = Math.max(viewport.ratio ?? 1, 1);
  const content = snap.documents[0]?.contentWidth ?? 0;
  const scale = ratio > 1 && content > 0 && viewport.pageWidth > 0 && Math.abs(content - viewport.pageWidth * ratio) < Math.abs(content - viewport.pageWidth) ? ratio : 1;
  if (scale !== 1) for (const doc of snap.documents) doc.layout.bounds = doc.layout.bounds.map((b) => b.map((v) => v / scale));
  for (const t of trees.values()) for (const n of t.nodes) byAx.set(n.nodeId, n);
  const lay = layoutIndex(snap);
  const nodes = [];
  let next = 0;
  const stats = { axNodes: ax.nodes.length, hidden: 0, clickableDivs: 0 };

  const emit = (role, name, l, depth, extra = {}) => {
    const [x, y, w, h] = l?.box ?? [0, 0, 0, 0];
    nodes.push({ id: ++next, role, name: cut(clean(name), role === 'text' ? MAX_TEXT : MAX_NAME), depth, x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h), frame: l?.frame ?? 0, ...extra });
    return nodes[nodes.length - 1];
  };

  const walk = (axNode, depth) => {
    if (!axNode) return;
    const role = axNode.role?.value ?? '';
    const name = clean(axNode.name?.value);
    const l = lay.get(axNode.backendDOMNodeId);
    const props = {};
    for (const p of axNode.properties ?? []) props[p.name] = p.value?.value;
    let line = null;
    const roleName = { DisclosureTriangle: 'disclosure', ListBoxOption: 'option', Iframe: 'frame', image: 'image', img: 'image' }[role] ?? role;

    // A hidden node and everything under it is not on the page a person sees.
    if (l && l.box === null && role !== 'RootWebArea' && axNode.backendDOMNodeId && l.nodeType === 1 && (l.display === 'none')) { stats.hidden++; return; }
    if (l && l.box && !visible(l, CONTROL_ROLES.has(role)) && role !== 'RootWebArea') { stats.hidden++; return; }

    const named = !axNode.ignored && (role === 'generic' || role === 'none') && name && !CONTROL_ROLES.has(role);
    if (!axNode.ignored && (!SKIP_ROLES.has(role) || named)) {
      if (CONTROL_ROLES.has(role) || GROUP_ROLES.has(role) || role === 'StaticText' || named) {
        const states = [];
        for (const k of STATE_PROPS) {
          const v = props[k];
          if (v === undefined || v === false || v === 'false' || v === 'none') continue;
          states.push(v === true || v === 'true' ? k : `${k}=${v}`);
        }
        // Live facts the snapshot has and the tree may not.
        if (l?.checked && !states.includes('checked')) states.push('checked');
        if (l?.attrs?.disabled !== undefined && !states.includes('disabled')) states.push('disabled');
        let value = axNode.value?.value;
        if ((value === undefined || value === '') && l?.value !== undefined && l.attrs?.type !== 'password') value = l.value;
        const kind = l?.attrs?.type;
        const extra = { states };
        if (value !== undefined && value !== '' && role !== 'StaticText' && kind !== 'password') extra.value = cut(clean(value), MAX_TEXT);
        if (kind && role === 'textbox' && kind !== 'text') extra.kind = kind;
        if (role === 'StaticText' || named) {
          if (name) line = emit('text', name, l, depth, {});
        } else {
          const hint = CONTROL_ROLES.has(role) && !name ? readableClasses(l?.attrs) : '';
          if (hint) extra.hint = hint;
          if (l?.attrs?.href && role === 'link') extra.href = l.attrs.href.slice(0, 120);
          line = emit(roleName, name, l, depth, extra);
        }
      }
    }
    if (!line && l?.clickable && l.nodeType === 1 && (l.cursor === 'pointer' || l.attrs?.onclick !== undefined) && visible(l)) {
      // A div made into a button: the tree calls it generic, the page says it is pressed.
      // Kept only when no descendant turns out to be a control of its own (checked below).
      stats.clickableDivs++;
      line = emit('clickable', name, l, depth, { hint: readableClasses(l.attrs) });
    }
    const childDepth = line ? depth + 1 : depth;
    const before = nodes.length;
    for (const id of axNode.childIds ?? []) walk(byAx.get(id), childDepth);
    // The frame's own tree, under the frame's line.
    const frameId = lay.childDoc.get(axNode.backendDOMNodeId);
    if (frameId && trees.has(frameId)) walk(trees.get(frameId).nodes[0], childDepth);
    // A clickable wrapper whose children carry a real control is noise: drop it, lift the children.
    if (line && line.role === 'clickable') {
      const kids = nodes.slice(before);
      if (kids.some((k) => CONTROL_ROLES.has(k.role) || k.role === 'clickable')) {
        nodes.splice(before - 1, 1);
        for (const k of kids) k.depth -= 1;
        stats.clickableDivs--;
      } else if (!line.name) {
        // Name it from its text, as a button would be.
        line.name = cut(kids.filter((k) => k.role === 'text').map((k) => k.name).join(' '), MAX_NAME);
        nodes.splice(before, kids.length);
      }
    }
    // A sole child that only repeats its parent's name (the image in a link, the heading in a
    // link, the text of a button) says nothing new.
    if (line && line.role !== 'text') {
      const kids = nodes.slice(before);
      if (kids.length === 1 && kids[0].name === line.name && !CONTROL_ROLES.has(kids[0].role)) nodes.splice(before, 1);
    }
  };
  walk(ax.nodes[0], 0);
  // A label's text right before the control it names is the control's name already.
  for (let i = nodes.length - 2; i >= 0; i--) {
    if (nodes[i].role === 'text' && nodes[i + 1].role !== 'text' && nodes[i + 1].name === nodes[i].name) nodes.splice(i, 1);
  }
  // Renumber after the drops, depth first.
  nodes.forEach((n, i) => { n.id = i + 1; });
  return { url: '', title: '', viewport, nodes, stats };
}

// ---- The rendering the harness does (mirrored here only to eyeball the output). ----

function render(map) {
  const { viewport: v } = map;
  const top = v.scrollY, bottom = v.scrollY + v.height;
  const inView = (n) => n.role === 'text' ? (n.y + n.h > top && n.y < bottom) : (n.y + n.h / 2 >= top && n.y + n.h / 2 < bottom);
  const lines = [`VIEW y=${top}..${bottom} of ${v.pageHeight}`];
  const out = [];
  for (const n of map.nodes) {
    if (!inView(n)) continue;
    const parts = [n.role === 'text' ? `"${n.name}"` : `${n.role}[${n.id}]${n.name ? ` "${n.name}"` : ''}`];
    if (n.kind) parts.push(`type=${n.kind}`);
    if (n.value !== undefined) parts.push(`value="${n.value}"`);
    if (n.states?.length) parts.push(n.states.join(' '));
    if (n.hint) parts.push(`class=${n.hint}`);
    if (n.role !== 'text') parts.push(`@${n.x},${n.y} ${n.w}x${n.h}`);
    out.push('  '.repeat(Math.min(n.depth, 8)) + parts.join(' '));
  }
  lines.push(...out);
  // Minimap: the rest of the page in bands of one viewport.
  const bands = new Map();
  for (const n of map.nodes) {
    if (inView(n) || n.role === 'text') continue;
    const b = Math.floor(n.y / v.height);
    if (!bands.has(b)) bands.set(b, { controls: 0, headings: [], names: [] });
    const band = bands.get(b);
    if (CONTROL_ROLES.has(n.role) || n.role === 'clickable') { band.controls++; if (n.name && band.names.length < 4 && !band.names.includes(n.name.slice(0, 40))) band.names.push(n.name.slice(0, 40)); }
    if (n.role === 'heading' && band.headings.length < 2) band.headings.push(n.name.slice(0, 60));
  }
  if (bands.size) lines.push('MINIMAP');
  for (const [b, band] of [...bands].sort((a, c) => a[0] - c[0])) {
    lines.push(`  y=${b * v.height}..${(b + 1) * v.height}  ${band.controls} controls${band.headings.length ? `  headings: ${band.headings.map((h) => `"${h}"`).join(' ')}` : ''}${band.names.length ? `  e.g. ${band.names.map((h) => `"${h}"`).join(' ')}` : ''}`);
  }
  return lines.join('\n');
}

async function run(browser, target, scroll) {
  const url = /^https?:|^file:/.test(target) ? target : 'file://' + path.resolve(target);
  const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.waitForLoadState('networkidle', { timeout: 15000 }).catch(() => {});
  if (scroll) {
    await page.evaluate((y) => window.scrollTo(0, y), scroll);
    await page.waitForTimeout(100);
  }
  const cdp = await page.context().newCDPSession(page);
  await cdp.send('DOM.enable'); await cdp.send('Accessibility.enable');
  const m = await page.evaluate(() => ({ width: innerWidth, height: innerHeight, scrollX: scrollX, scrollY: scrollY, pageWidth: document.documentElement.scrollWidth, pageHeight: document.documentElement.scrollHeight, ratio: devicePixelRatio }));
  const t0 = performance.now();
  await cdp.send('Page.enable');
  const frameTree = await cdp.send('Page.getFrameTree');
  const childFrames = (t) => (t.childFrames ?? []).flatMap((c) => [c.frame.id, ...childFrames(c)]);
  const [ax, snap, ...childTrees] = await Promise.all([
    cdp.send('Accessibility.getFullAXTree'),
    cdp.send('DOMSnapshot.captureSnapshot', { computedStyles: ['display', 'visibility', 'opacity', 'cursor'], includeDOMRects: false }),
    ...childFrames(frameTree.frameTree).map((frameId) => cdp.send('Accessibility.getFullAXTree', { frameId }).then((t) => [frameId, t]).catch(() => null)),
  ]);
  const t1 = performance.now();
  const map = buildPageMap(ax, snap, m, new Map(childTrees.filter(Boolean)));
  const t2 = performance.now();
  map.url = page.url(); map.title = await page.title();
  const text = render(map);
  const slug = (new URL(url).hostname || path.basename(target)).replace(/\W+/g, '_') + (scroll ? '-scrolled' : '');
  fs.writeFileSync(path.join(OUT, `${slug}.page.json`), JSON.stringify(map));
  fs.writeFileSync(path.join(OUT, `${slug}.page.txt`), text);
  console.log(JSON.stringify({ url, fetchMs: Math.round(t1 - t0), buildMs: Math.round(t2 - t1), nodes: map.nodes.length, textKb: Math.round(Buffer.byteLength(text) / 102.4) / 10, jsonKb: Math.round(Buffer.byteLength(JSON.stringify(map)) / 102.4) / 10, ...map.stats }));
  await page.close();
}

const args = process.argv.slice(2);
const scroll = Number((args.find((a) => a.startsWith('--scroll=')) ?? '--scroll=0').slice('--scroll='.length));
const browser = await chromium.launch({ ...(process.env.CHROMIUM ? { executablePath: process.env.CHROMIUM } : {}) });
for (const t of args.filter((a) => !a.startsWith('--'))) await run(browser, t, scroll).catch((e) => console.log(JSON.stringify({ url: t, error: String(e).slice(0, 200) })));
await browser.close();
