// The browser side of the kit: one Playwright page, driven over stdin and stdout with one JSON
// object per line. The harness is the brain; this file only looks and does.
//
// Requests, one per line:
//   {"id": 1, "cmd": "open", "url": "https://..."}
//   {"id": 2, "cmd": "observe", "survey": false, "focus": [y, ...], "settled": {"spans": [{"from", "to"}]} | null}
//   {"id": 3, "cmd": "act", "actions": [{"id": "s1a1", "kind": "click", "x": 10, "y": 20}, ...]}
//   {"id": 4, "cmd": "close"}
// Replies: {"id": n, "ok": true, ...} or {"id": n, "ok": false, "error": "..."}.
//
// The observation and the actions are the harness's own shapes (harness/src/observe.rs and
// action.rs), as serde writes them: camelCase fields, actions flat with a "kind".

import readline from 'node:readline';
import { chromium } from 'playwright';

// How the page is looked at and acted on. A look is taken when the page has settled: no change
// to its DOM for QUIET_MS and no request still in flight, judged by a MutationObserver in the
// page and a count of its requests here, never by a fixed wait. The caps only bound a page that
// never settles (an endless animation, a long poll).
const SURVEY_OVERLAP_PX = 120; // shared by neighbouring survey screens, so a control cut by one edge is whole on the next
const FOCUS_NEAR_PX = 24; // a survey screen this close to a wanted one is the same screen
const QUIET_MS = 250; // this long without a DOM change, with no request in flight, is settled
const SETTLE_CAP_MS = 5000; // the longest a look waits for the page to settle
const SCROLL_SETTLE_CAP_MS = 1000; // the longest a scroll waits for what it brought into view
const OPEN_MS = 30000; // how long opening the start page may take
const CHOOSER_MS = 3000; // how long an upload waits for the file picker
const MAX_WAIT_MS = 30000; // the longest one wait action may be
const JPEG_QUALITY = 80;
const EVALUATE_RETRIES = 5; // how many times a page function is tried again across a navigation
const RETRY_MS = 150; // between those tries
const MAX_LABEL_CHARS = 80;
const MAX_VALUE_CHARS = 200;

const args = parseArgs(process.argv.slice(2));
const width = Number(args.width ?? 1280);
const height = Number(args.height ?? 720);

const launch = { headless: !args.headed };
if (process.env.HTTPS_PROXY) {
  launch.proxy = { server: process.env.HTTPS_PROXY };
}
const browser = await chromium.launch(launch);
const context = await browser.newContext({ viewport: { width, height }, deviceScaleFactor: 1 });
let page = await context.newPage();
let notes = []; // things the screenshot cannot show, for the next look
let zoneShots = []; // photos taken when a zone of the last batch was done
let chooser = null; // a file picker a click opened, until it is answered
const inFlight = new Set(); // the page's requests not yet answered, for the settle check

context.on('page', (opened) => {
  page = opened;
  watch(page);
  notes.push('The page opened a new tab, which is now the one shown.');
});
watch(page);

function watch(p) {
  p.on('request', (request) => {
    // A socket or an event stream stays open for the page's life and does not keep it busy.
    if (!['websocket', 'eventsource'].includes(request.resourceType())) inFlight.add(request);
  });
  p.on('requestfinished', (request) => inFlight.delete(request));
  p.on('requestfailed', (request) => inFlight.delete(request));
  p.on('dialog', async (dialog) => {
    const accept = dialog.type() === 'alert' || dialog.type() === 'beforeunload';
    notes.push(`A dialog said: ${clip(dialog.message(), MAX_VALUE_CHARS)} (it was ${accept ? 'accepted' : 'dismissed'}).`);
    await (accept ? dialog.accept() : dialog.dismiss()).catch(() => {});
  });
  p.on('download', (download) => notes.push(`A file downloaded: ${download.suggestedFilename()}.`));
  p.on('filechooser', (opened) => {
    chooser = opened;
  });
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const name = arg.slice(2);
    if (argv[i + 1] !== undefined && !argv[i + 1].startsWith('--')) {
      out[name] = argv[++i];
    } else {
      out[name] = true;
    }
  }
  return out;
}

function clip(text, max) {
  return text.length > max ? text.slice(0, max) : text;
}

// Runs a page function, waiting out a navigation meanwhile: between two documents the context is
// destroyed, or the new document has no element yet, and either fails the function once.
async function evaluate(fn, arg) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await page.evaluate(fn, arg);
    } catch (error) {
      if (attempt >= EVALUATE_RETRIES) throw error;
      await page.waitForLoadState('load', { timeout: SETTLE_CAP_MS }).catch(() => {});
      await page.waitForTimeout(RETRY_MS);
    }
  }
}

async function metrics() {
  return evaluate(() => {
    const root = document.documentElement;
    if (!root) throw new Error('the page has no document yet');
    return { scrollX: window.scrollX, scrollY: window.scrollY, pageWidth: root.scrollWidth, pageHeight: root.scrollHeight };
  });
}

async function shot() {
  const raw = await page.screenshot({ type: 'jpeg', quality: JPEG_QUALITY });
  return `data:image/jpeg;base64,${raw.toString('base64')}`;
}

/// Waits until the page has settled: no DOM change for QUIET_MS (a MutationObserver in the page
/// says so) and no request in flight, within `cap`. A menu that is still opening, a list still
/// filling, a page still loading what a click asked for, is not what the model should plan from.
async function settled(cap = SETTLE_CAP_MS) {
  const started = Date.now();
  while (Date.now() - started < cap) {
    const left = cap - (Date.now() - started);
    const quiet = await evaluate(
      ({ quietMs, capMs }) =>
        new Promise((resolve) => {
          let timer = setTimeout(() => done(true), quietMs);
          const stop = setTimeout(() => done(false), capMs);
          const observer = new MutationObserver(() => {
            clearTimeout(timer);
            timer = setTimeout(() => done(true), quietMs);
          });
          function done(result) {
            observer.disconnect();
            clearTimeout(timer);
            clearTimeout(stop);
            resolve(result);
          }
          observer.observe(document, { childList: true, subtree: true, attributes: true, characterData: true });
        }),
      { quietMs: QUIET_MS, capMs: Math.max(QUIET_MS, left) },
    ).catch(() => true);
    if (quiet && inFlight.size === 0) return true;
    if (inFlight.size > 0) await page.waitForTimeout(RETRY_MS);
  }
  return false;
}

async function scrollTo(y) {
  await evaluate((top) => window.scrollTo(window.scrollX, top), y);
  await settled(SCROLL_SETTLE_CAP_MS);
}

/// Whether a control has the keyboard: typing goes somewhere.
/// The focused element, following the focus into embedded frames; a frame of another site
/// cannot be looked into, and is the answer itself then.
function deepActive() {
  let a = document.activeElement;
  while (a && a.tagName === 'IFRAME') {
    let inner = null;
    try { inner = a.contentDocument && a.contentDocument.activeElement; } catch (e) {}
    if (!inner || inner === a) return { element: a, sealed: true };
    a = inner;
  }
  if (!a || a === document.body || a === document.documentElement) return { element: null, sealed: false };
  if (a.ownerDocument && (a === a.ownerDocument.body || a === a.ownerDocument.documentElement)) return { element: null, sealed: false };
  return { element: a, sealed: false };
}

async function hasFocus() {
  return evaluate(`(${deepActive.toString()}, (() => {
    const { element: a, sealed } = deepActive();
    if (sealed) return true;
    if (!a) return false;
    return a.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(a.tagName);
  })())`);
}

/// The focused control as the page describes it, or null.
async function focus() {
  return evaluate(
    ({ maxLabel, maxValue, deep }) => {
      const { element: a, sealed } = new Function(`return (${deep})()`)();
      if (!a) return null;
      const cut = (text, max) => (text || '').trim().replace(/\s+/g, ' ').slice(0, max);
      if (sealed) {
        return { tag: 'iframe', type: '', label: cut(a.getAttribute('title') || a.getAttribute('aria-label') || a.getAttribute('name') || '', maxLabel) };
      }
      const doc = a.ownerDocument || document;
      const byId = a.getAttribute('aria-labelledby');
      const label =
        (a.labels && a.labels[0] && a.labels[0].innerText) ||
        a.getAttribute('aria-label') ||
        (byId && doc.getElementById(byId) && doc.getElementById(byId).innerText) ||
        a.getAttribute('placeholder') ||
        a.getAttribute('title') ||
        a.getAttribute('name') ||
        '';
      const tag = a.tagName.toLowerCase();
      const type = (a.type || '').toLowerCase();
      const out = { tag, type, label: cut(label, maxLabel) };
      if (tag === 'select') {
        out.options = Array.from(a.options).map((o) => cut(o.text, maxLabel));
        out.multiple = a.multiple;
        out.value = cut(a.selectedOptions[0] ? a.selectedOptions[0].text : '', maxValue);
      } else if (type === 'checkbox' || type === 'radio') {
        out.checked = a.checked;
      } else if (type !== 'password' && 'value' in a) {
        out.value = cut(a.value, maxValue);
      } else if (a.isContentEditable) {
        out.value = cut(a.innerText, maxValue);
      }
      out.required = !!a.required;
      if (typeof a.checkValidity === 'function' && !a.checkValidity()) out.invalid = cut(a.validationMessage, maxValue);
      return out;
    },
    { maxLabel: MAX_LABEL_CHARS, maxValue: MAX_VALUE_CHARS, deep: deepActive.toString() },
  );
}

async function open(url) {
  try {
    await page.goto(url, { waitUntil: 'load', timeout: OPEN_MS });
  } catch (error) {
    notes.push(`The page did not finish loading: ${error.message}`);
  }
}

/// One look at the page: the screenshot, where it is, what has focus, and, when asked, the whole
/// page as screens from top to bottom, leaving out the parts the harness settled.
async function observe(survey, focusYs, settledSpans) {
  await page.waitForLoadState('load', { timeout: SETTLE_CAP_MS }).catch(() => {});
  await settled();
  const vp = page.viewportSize();
  const m = await metrics();
  const observation = {
    screenshot: await shot(),
    url: page.url(),
    title: await page.title(),
    viewport: { width: vp.width, height: vp.height, ...m },
    focus: await focus(),
    notes: notes.splice(0),
    zoneShots: zoneShots.splice(0),
  };
  if (survey) {
    observation.survey = await surveyScreens(m, focusYs || [], settledSpans);
  }
  return observation;
}

function inSettled(settledSpans, from, to) {
  return !!settledSpans && settledSpans.spans.some((span) => span.from <= from + 1 && span.to >= to - 1);
}

async function surveyScreens(m, focusYs, settledSpans) {
  const h = page.viewportSize().height;
  const last = Math.max(0, m.pageHeight - h);
  const step = Math.max(1, h - SURVEY_OVERLAP_PX);
  const tops = [];
  for (let y = 0; ; y += step) {
    const top = Math.min(y, last);
    if (!inSettled(settledSpans, top, top + h)) tops.push(top);
    if (top >= last) break;
  }
  // A field whose fill did not verify gets a screen centred on it, so it is whole.
  for (const y of focusYs) {
    const top = Math.min(Math.max(y - h / 2, 0), last);
    if (!tops.some((t) => Math.abs(t - top) <= FOCUS_NEAR_PX)) tops.push(top);
  }
  tops.sort((a, b) => a - b);
  const screens = [];
  for (const top of tops) {
    if (screens.length && Math.abs(screens[screens.length - 1].scrollY - top) <= 1) continue;
    await scrollTo(top);
    screens.push({ screenshot: await shot(), scrollY: (await metrics()).scrollY });
  }
  await scrollTo(m.scrollY);
  return screens;
}

/// Carries the actions out in order. A failure stops the batch (the rest is reported as not run);
/// typing with nothing focused is not a failure of the batch, only of that action.
async function act(actions) {
  const results = [];
  let stopped = null;
  for (let i = 0; i < actions.length; i++) {
    const action = actions[i];
    if (stopped) {
      results.push({ id: action.id, ok: false, error: `not run: ${stopped}` });
      continue;
    }
    try {
      if (action.scrollTo != null) {
        const m = await metrics();
        if (action.pageHeight && Math.abs(m.pageHeight - action.pageHeight) > 12) {
          throw new Error(`the page is ${m.pageHeight} px tall now and was ${action.pageHeight} px when the point was measured`);
        }
        if (Math.abs(m.scrollY - action.scrollTo) > 1) await scrollTo(action.scrollTo);
      }
      const extra = await doAction(action);
      results.push({ id: action.id, ok: true, ...extra });
    } catch (error) {
      const unreached = error.unreached === true;
      results.push({ id: action.id, ok: false, error: error.message, unreached });
      if (!unreached) stopped = error.message;
    }
    // A zone's photo once its last action is done, for the harness to review on the side.
    const next = actions[i + 1];
    if (action.zone > 0 && (!next || next.zone !== action.zone)) {
      await settled();
      zoneShots.push({ zone: action.zone, screenshot: await shot(), scrollY: (await metrics()).scrollY });
    }
  }
  return results;
}

async function doAction(action) {
  chooser = null;
  switch (action.kind) {
    case 'click':
      await page.mouse.click(action.x, action.y);
      break;
    case 'double_click':
      await page.mouse.dblclick(action.x, action.y);
      break;
    case 'triple_click':
      await page.mouse.click(action.x, action.y, { clickCount: 3 });
      break;
    case 'right_click':
      await page.mouse.click(action.x, action.y, { button: 'right' });
      break;
    case 'hover':
      await page.mouse.move(action.x, action.y);
      break;
    case 'type': {
      if (!(await hasFocus())) {
        const error = new Error('nothing has focus, so there is nowhere to type');
        error.unreached = true;
        throw error;
      }
      await page.keyboard.type(action.text, { delay: 10 });
      break;
    }
    case 'key':
      for (const key of action.keys.split(/\s+/).filter(Boolean)) {
        await page.keyboard.press(key);
      }
      break;
    case 'scroll':
      await page.mouse.move(action.x ?? width / 2, action.y ?? height / 2);
      await page.mouse.wheel(action.dx ?? 0, action.dy ?? 0);
      await settled(SCROLL_SETTLE_CAP_MS);
      return {};
    case 'upload': {
      const [opened] = await Promise.all([page.waitForEvent('filechooser', { timeout: CHOOSER_MS }), page.mouse.click(action.x, action.y)]);
      chooser = null;
      if (!action.path) {
        await opened.setFiles([]);
        throw new Error('the task has no file to upload');
      }
      await opened.setFiles(action.path);
      return { detail: `attached ${action.fileName || action.path}` };
    }
    case 'wait':
      await page.waitForTimeout(Math.min(action.ms ?? 1000, MAX_WAIT_MS));
      return {};
    case 'navigate':
      if (!action.url) throw new Error('there is no address to go to');
      await open(action.url);
      return {};
    case 'back':
      await page.goBack({ waitUntil: 'load', timeout: OPEN_MS }).catch((error) => notes.push(`Going back did not finish: ${error.message}`));
      await settled();
      return {};
    default:
      throw new Error(`the browser cannot do an action of kind ${action.kind}`);
  }
  // A click that opens the file picker reports it within the settle; the next action, or the
  // look, waits for the page anyway.
  await settled();
  // A plain click that opened the file picker: it is closed, and the harness is told.
  if (chooser) {
    const opened = chooser;
    chooser = null;
    await opened.setFiles([]).catch(() => {});
    return { opened: 'file_picker' };
  }
  return {};
}

const lines = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
for await (const line of lines) {
  if (!line.trim()) continue;
  let request;
  try {
    request = JSON.parse(line);
  } catch (error) {
    process.stdout.write(`${JSON.stringify({ id: null, ok: false, error: `bad request: ${error.message}` })}\n`);
    continue;
  }
  let reply;
  try {
    switch (request.cmd) {
      case 'open':
        await open(request.url);
        reply = { ok: true };
        break;
      case 'observe':
        reply = { ok: true, observation: await observe(!!request.survey, request.focus, request.settled) };
        break;
      case 'act':
        reply = { ok: true, results: await act(request.actions || []) };
        break;
      case 'close':
        reply = { ok: true };
        break;
      default:
        reply = { ok: false, error: `unknown command ${request.cmd}` };
    }
  } catch (error) {
    reply = { ok: false, error: error.message };
  }
  process.stdout.write(`${JSON.stringify({ id: request.id, ...reply })}\n`);
  if (request.cmd === 'close') break;
}
await browser.close().catch(() => {});
process.exit(0);
