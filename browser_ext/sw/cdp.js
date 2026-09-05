// CDP (chrome.debugger) transport: trusted input events + screenshots of any
// tab. Debugger input is synthesized by Chrome itself, so pages cannot tell it
// from real user input; the documented cost is the "started debugging this
// browser" infobar shown while attached (E23). The default control plane stays
// content-script (quiet) — CDP is per-call opt-in via args.trusted.

const attached = new Map(); // tabId -> targetId from attach (presence = attached)

/** Error carrying an ops-visible code (ops.dispatch surfaces it verbatim). */
const cdpErr = (msg, code) => Object.assign(new Error(msg), { code });

/** Map a chrome.debugger failure onto an op error code. */
function mapErr(e) {
  const msg = String(e?.message || e);
  if (/another client|already attached/i.test(msg)) {
    return cdpErr('another debugger client (DevTools?) owns this tab — retry without args.trusted for the quiet content path', 'denied');
  }
  const code = /no tab with id|tab was closed|not attached|inspector detached/i.test(msg) ? 'no_tab' : 'cdp';
  return cdpErr(msg, code);
}

// DevTools / another client stealing the target ends our session: evict.
chrome.debugger.onDetach.addListener((src) => {
  if (src && src.tabId != null) attached.delete(src.tabId);
});

/** Attach protocol '1.3' to the tab unless cached; cache lives until evict/detach. */
async function ensure(tabId) {
  if (attached.has(tabId)) return attached.get(tabId);
  let targetId;
  try {
    targetId = await chrome.debugger.attach({ tabId }, '1.3');
  } catch (e) {
    throw mapErr(e);
  }
  attached.set(tabId, targetId ?? null);
  return targetId ?? null;
}

/** sendCommand wrapper; session-ending failures evict the stale cache entry. */
async function send(tabId, method, params) {
  try {
    return await chrome.debugger.sendCommand({ tabId }, method, params ?? {});
  } catch (e) {
    if (/not attached|inspector detached|was detached/i.test(String(e?.message || e))) attached.delete(tabId);
    throw mapErr(e);
  }
}

/** Runtime.evaluate with returnByValue → the unwrapped value. */
async function evalValue(tabId, expression) {
  const res = await send(tabId, 'Runtime.evaluate', { expression, returnByValue: true });
  return res && res.result ? res.result.value : undefined;
}

/** Page-world snippet: center of the first selector match, or null. */
const centerExpr = (selector) =>
  `(() => { const el = document.querySelector(${JSON.stringify(selector)});`
  + ` if (!el) return null; const r = el.getBoundingClientRect();`
  + ` return { x: r.x + r.width / 2, y: r.y + r.height / 2, w: r.width, h: r.height }; })()`;

/** Center {x,y,w,h} of the element; no match → node_vanished. */
async function rect(tabId, selector) {
  const box = await evalValue(tabId, centerExpr(selector));
  if (!box) throw cdpErr(`no element matches "${selector}"`, 'node_vanished');
  return box;
}

const mouse = (type, x, y) => ({ type, x, y, button: 'left', clickCount: 1 });

/** Trusted click: mousePressed + mouseReleased at the element center. */
async function trustedClick(tabId, selector) {
  const at = await rect(tabId, selector);
  await send(tabId, 'Input.dispatchMouseEvent', mouse('mousePressed', at.x, at.y));
  await send(tabId, 'Input.dispatchMouseEvent', mouse('mouseReleased', at.x, at.y));
  return { selector };
}

/** One char as keyDown(text) → char(text) → keyUp. */
const charEvents = (ch) => [
  { type: 'keyDown', key: ch, code: '', text: ch },
  { type: 'char', key: ch, code: '', text: ch },
  { type: 'keyUp', key: ch, code: '' },
];

/** Focus-finder expression; false when the selector misses. */
const focusExpr = (selector) =>
  `(() => { const el = document.querySelector(${JSON.stringify(selector)});`
  + ` if (!el) return false; el.focus(); return true; })()`;

/** Trusted typing: focus the element, type each char, Enter when submit. */
async function trustedType(tabId, selector, text, submit) {
  if (selector != null) {
    const focused = await evalValue(tabId, focusExpr(selector));
    if (!focused) throw cdpErr(`no element matches "${selector}"`, 'node_vanished');
  }
  for (const ch of String(text ?? '')) {
    for (const ev of charEvents(ch)) await send(tabId, 'Input.dispatchKeyEvent', ev);
  }
  if (submit) {
    await send(tabId, 'Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', text: '\r', windowsVirtualKeyCode: 13 });
    await send(tabId, 'Input.dispatchKeyEvent', { type: 'keyUp', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
  }
  return { typed: String(text ?? '').length };
}

/** Trusted key press on the focused element; single printable chars add 'char'. */
async function trustedPressKey(tabId, key) {
  const k = String(key ?? '');
  const printable = k.length === 1;
  const down = printable ? { type: 'keyDown', key: k, code: '', text: k } : { type: 'keyDown', key: k, code: k };
  await send(tabId, 'Input.dispatchKeyEvent', down);
  if (printable) await send(tabId, 'Input.dispatchKeyEvent', { type: 'char', key: k, code: '', text: k });
  await send(tabId, 'Input.dispatchKeyEvent', printable ? { type: 'keyUp', key: k, code: '' } : { type: 'keyUp', key: k, code: k });
  return { key: k };
}

/** PNG of ANY tab — active or not, no activation, no visibility needed (AC16). */
async function captureTab(tabId) {
  const res = await send(tabId, 'Page.captureScreenshot', { format: 'png' });
  return { pngBase64: (res && res.data) || '', mimeType: 'image/png' };
}

/** Detach every tab we still hold (ops.task_end calls this). Count detached. */
async function detachAll() {
  const ids = [...attached.keys()];
  attached.clear();
  await Promise.all(ids.map(async (tabId) => {
    try { await chrome.debugger.detach({ tabId }); } catch { /* already gone */ }
  }));
  return ids.length;
}

/** Debug snapshot: tabIds with a live debugger session. */
function status() {
  return { attached: [...attached.keys()] };
}

// Classic-SW module glue (see tabs.js). Loads after ops.js; ops reaches the
// namespace lazily at call time, never via top-level destructure.
globalThis.faSw = Object.assign(globalThis.faSw ?? {}, {
  cdp: { ensure, rect, trustedClick, trustedType, trustedPressKey, captureTab, detachAll, status },
});
