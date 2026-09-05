(() => { // Classic-SW module scope: nothing leaks into the shared importScripts global (a top-level const here once collided with main.js and killed SW boot).
// browserReq dispatcher: maps contract ops to chrome.* APIs / content script.
// Every op resolves exactly once to {ok:true,result} or {ok:false,error,code?}.
const { trackCreated, taskEnd } = globalThis.faSw; // importScripts loads tabs.js first

const OP_CAP_MS = 30000;

const opErr = (error, code) => Object.assign(new Error(error), { code });

const fail = (error, code) => ({ ok: false, error, ...(code ? { code } : {}) });

const normalize = (e) => fail(String(e?.message || e), e?.code);

function withCap(promise) {
  return Promise.race([
    promise,
    new Promise((_, reject) => setTimeout(() => reject(opErr('op exceeded 30s cap', 'timeout')), OP_CAP_MS)),
  ]);
}

/** Restricted targets (E4): chrome://, extension pages, Web Store, PDF viewer. */
function restrictedReason(url) {
  let u;
  try { u = new URL(url); } catch { return null; } // let chrome report bad urls
  const scheme = u.protocol.replace(':', '');
  if (['chrome', 'chrome-extension', 'chrome-untrusted', 'edge', 'about', 'devtools', 'view-source'].includes(scheme)) {
    return `${scheme}: pages are restricted`;
  }
  if (u.hostname === 'chrome.google.com' && u.pathname.startsWith('/webstore')) return 'Web Store is restricted';
  if (scheme === 'file' && /\.pdf($|\?|#)/i.test(u.pathname + u.search)) return 'built-in PDF viewer is restricted';
  return null;
}

async function resolveTab(tabId) {
  if (tabId !== undefined && tabId !== null) {
    try { return await chrome.tabs.get(tabId); } catch { throw opErr(`no tab with id ${tabId}`, 'no_tab'); }
  }
  const [active] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!active) throw opErr('no active tab; pass tabId', 'no_target');
  return active;
}

function guardTab(tab) {
  const why = restrictedReason(tab.url ?? tab.pendingUrl);
  if (why) throw opErr(why, 'restricted_page');
}

function injectError(e) {
  const msg = String(e?.message || e);
  if (/cannot access|cannot be scripted|permission/i.test(msg)) return opErr(msg, 'restricted_page');
  if (/no tab with id|tab was closed/i.test(msg)) return opErr(msg, 'no_tab');
  return opErr(msg, 'node_vanished');
}

/** Send an op to the content script; inject it first if the page lacks it. */
async function sendToContent(tabId, op, args) {
  const msg = { pv: 1, op, args };
  try {
    return await chrome.tabs.sendMessage(tabId, msg);
  } catch {
    try {
      await chrome.scripting.executeScript({ target: { tabId, allFrames: false }, files: ['content/content.js'] });
      return await chrome.tabs.sendMessage(tabId, msg);
    } catch (e) {
      throw injectError(e);
    }
  }
}

/** Full DOM-op path: resolve tab, restrict-check, proxy, check version skew (E10). */
async function contentOp(args, op) {
  const tab = await resolveTab(args.tabId);
  guardTab(tab);
  const res = await sendToContent(tab.id, op, { ...args, tabId: undefined });
  if (!res || res.pv !== 1) throw opErr('content script version mismatch — reload the page', 'proto');
  if (!res.ok) throw opErr(res.error?.error || res.error?.code || 'content op failed', res.error?.code);
  return res.result;
}

/** Tag a result with the control plane that produced it (AC16 pin). */
const at = (path, result) => ({ ...result, path });

/** Trusted op → CDP call; cdp.js loads after this file, so reach it lazily. */
const TRUSTED = {
  click: (a, tab) => globalThis.faSw.cdp.trustedClick(tab.id, a.selector),
  type: (a, tab) => globalThis.faSw.cdp.trustedType(tab.id, a.selector, a.text, a.submit),
  press_key: (a, tab) => globalThis.faSw.cdp.trustedPressKey(tab.id, a.key),
};

/** DOM-op router: args.trusted → chrome.debugger (E23), else the quiet content path. */
async function domOp(args, op) {
  if (!args.trusted) return at('dom', await contentOp(args, op));
  const tab = await resolveTab(args.tabId);
  guardTab(tab);
  await globalThis.faSw.cdp.ensure(tab.id);
  return at('cdp', await TRUSTED[op](args, tab));
}

function waitComplete(tabId, ms = 28000) {
  return new Promise(async (resolve, reject) => {
    try {
      const t0 = await chrome.tabs.get(tabId);
      if (t0.status === 'complete') return resolve(t0);
    } catch { return reject(opErr(`no tab with id ${tabId}`, 'no_tab')); }
    const cleanup = () => {
      clearTimeout(timer);
      chrome.tabs.onUpdated.removeListener(onUpdated);
      chrome.tabs.onRemoved.removeListener(onRemoved);
    };
    const onUpdated = (id, info) => {
      if (id !== tabId || info.status !== 'complete') return;
      cleanup();
      chrome.tabs.get(tabId).then(resolve, () => resolve({ id: tabId }));
    };
    const onRemoved = (id) => {
      if (id !== tabId) return;
      cleanup();
      reject(opErr('tab closed during navigation', 'no_tab'));
    };
    const timer = setTimeout(() => {
      cleanup();
      chrome.tabs.get(tabId).then(resolve, () => resolve({ id: tabId }));
    }, ms);
    chrome.tabs.onUpdated.addListener(onUpdated);
    chrome.tabs.onRemoved.addListener(onRemoved);
  });
}

const OPS = {
  async navigate({ url, tabId }) {
    const why = restrictedReason(url);
    if (why) throw opErr(why, 'restricted_page');
    let tab;
    if (tabId !== undefined && tabId !== null) {
      try { tab = await chrome.tabs.update(tabId, { url }); } catch { throw opErr(`no tab with id ${tabId}`, 'no_tab'); }
    } else {
      tab = await chrome.tabs.create({ url });
      await trackCreated(tab); // only SW-opened tabs join the task group (AC17)
    }
    const done = await waitComplete(tab.id);
    return { tabId: done.id, url: done.url ?? url, title: done.title ?? '' };
  },

  async tabs() {
    const list = await chrome.tabs.query({});
    return {
      tabs: list.map((t) => ({
        id: t.id, url: t.url ?? '', title: t.title ?? '', active: !!t.active, groupId: t.groupId ?? -1,
      })),
    };
  },

  async switch_tab({ tabId }) {
    const tab = await resolveTab(tabId);
    await chrome.tabs.update(tab.id, { active: true });
    await chrome.windows.update(tab.windowId, { focused: true });
    return { tabId: tab.id };
  },

  click: (a) => domOp(a, 'click'),
  type: (a) => domOp(a, 'type'),
  press_key: (a) => domOp(a, 'press_key'),
  select: (a) => contentOp(a, 'select'),
  read_dom: (a) => contentOp(a, 'read_dom'),
  wait_for: (a) => contentOp(a, 'wait_for'),
  eval: (a) => contentOp(a, 'eval'),

  async screenshot(a) {
    const tab = await resolveTab(a.tabId);
    guardTab(tab);
    if (a.trusted) {
      await globalThis.faSw.cdp.ensure(tab.id);
      return at('cdp', await globalThis.faSw.cdp.captureTab(tab.id)); // any tab, never activates (AC16)
    }
    if (!tab.active) await chrome.tabs.update(tab.id, { active: true });
    const dataUrl = await chrome.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
    return at('dom', { pngBase64: dataUrl.replace(/^data:image\/png;base64,/, ''), mimeType: 'image/png' });
  },

  async task_end() {
    await globalThis.faSw.cdp.detachAll().catch(() => {}); // drop debugger sessions too
    await taskEnd();
    return { cleaned: true };
  },
};

/** Entry point for bridge browserReq. Never throws; always one answer. */
async function dispatch(op, args = {}) {
  const fn = OPS[op];
  if (!fn) return fail(`unknown op "${op}"`, 'bad_args');
  try {
    return { ok: true, result: await withCap(Promise.resolve(fn(args))) };
  } catch (e) {
    return normalize(e);
  }
}

// Classic-SW module glue (see tabs.js).
globalThis.faSw = Object.assign(globalThis.faSw ?? {}, { restrictedReason, dispatch });
})();
