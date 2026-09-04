// Isolated-world DOM ops for the fa bridge (injected by manifest and on demand).
// Every message gets exactly one answer: {pv:1, ok:true, result} | {pv:1, ok:false, error:{code,error}}.
(() => {
  if (globalThis.__faContentLoaded) return;
  globalThis.__faContentLoaded = true;

  const PV = 1;
  const TEXT_CAP = 120;
  const NODE_SOFT_CAP = 800;
  const NODE_HARD_CAP = 5000;
  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'LINK', 'META']);

  const faErr = (code, error) => Object.assign(new Error(error), { code });

  const qs = (sel) => {
    const el = document.querySelector(sel);
    if (!el) throw faErr('node_vanished', `selector not found: ${sel}`);
    return el;
  };

  function fire(el, type, init) {
    el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, composed: true, view: window, button: 0, ...init }));
  }

  const KEY_CODES = { Enter: 13, Tab: 9, Escape: 27, Backspace: 8, Delete: 46, Space: 32, ArrowUp: 38, ArrowDown: 40, ArrowLeft: 37, ArrowRight: 39 };

  function keyInit(key) {
    let code = '';
    if (KEY_CODES[key] !== undefined) code = key;
    else if (/^[a-z]$/i.test(key)) code = `Key${key.toUpperCase()}`;
    else if (/^[0-9]$/.test(key)) code = `Digit${key}`;
    const keyCode = KEY_CODES[code] ?? (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0);
    return { key, code, keyCode, which: keyCode };
  }

  function fireKey(el, type, init) {
    el.dispatchEvent(new KeyboardEvent(type, { bubbles: true, cancelable: true, composed: true, ...init }));
  }

  function isHidden(el) {
    if (el.hidden || el.getAttribute('aria-hidden') === 'true') return true;
    const cs = getComputedStyle(el);
    return cs.display === 'none' || cs.visibility === 'hidden';
  }

  function ownText(el) {
    const text = [...el.childNodes].filter((n) => n.nodeType === 3).map((n) => n.nodeValue.trim()).join(' ');
    return text.length > TEXT_CAP ? `${text.slice(0, TEXT_CAP)}…` : text;
  }

  function describe(el) {
    let s = el.tagName.toLowerCase();
    if (el.id) s += `#${el.id}`;
    for (const c of el.classList) s += `.${c}`;
    for (const a of ['role', 'aria-label']) {
      const v = el.getAttribute(a);
      if (v) s += `[${a}="${v}"]`;
    }
    const text = ownText(el);
    if (text) s += ` "${text}"`;
    return s;
  }

  // ponytail: nth-of-type css paths are ambiguous under dynamic siblings and
  // stop at shadow boundaries (marked `#shadow`) — real css-path resolution
  // comes with the CDP phase if needed.
  function serializeDom(root, maxNodes, includeShadow) {
    const budget = Math.min(Math.max(1, maxNodes), NODE_HARD_CAP);
    const lines = [];
    let count = 0;
    let truncated = false;
    const nthOfType = (el) => {
      let i = 1;
      for (let p = el.previousElementSibling; p; p = p.previousElementSibling) {
        if (p.tagName === el.tagName) i++;
      }
      return i;
    };
    const walk = (node, depth, path) => {
      if (count >= budget) { truncated = true; return; }
      if (node.nodeType !== 1 || SKIP_TAGS.has(node.tagName) || isHidden(node)) return;
      count++;
      const childPath = `${path} > ${node.tagName.toLowerCase()}:nth-of-type(${nthOfType(node)})`;
      lines.push(`${'  '.repeat(depth)}${describe(node)} @${childPath}`);
      for (const child of node.children) walk(child, depth + 1, childPath);
      // ponytail: one shadow level only, informational path (not querySelector-able).
      if (includeShadow && node.shadowRoot) {
        for (const child of node.shadowRoot.children) walk(child, depth + 1, `${childPath} #shadow`);
      }
    };
    walk(root, 0, '');
    return { dom: lines.join('\n'), nodeCount: count, truncated };
  }

  function waitOp({ selector, text, timeoutMs = 10000 }) {
    const deadline = Date.now() + Math.min(Number(timeoutMs) || 10000, 30000);
    const matches = () => {
      if (selector && document.querySelector(selector)) return true;
      if (text && (document.body?.innerText || document.body?.textContent || '').includes(text)) return true;
      return false;
    };
    return new Promise((resolve, reject) => {
      const start = Date.now();
      let settled = false;
      const mo = new MutationObserver(check);
      const finish = (found) => {
        if (settled) return;
        settled = true;
        mo.disconnect();
        clearInterval(poll);
        if (found) resolve({ found: true, waitedMs: Date.now() - start });
        else reject(faErr('timeout', `wait_for timed out after ${timeoutMs}ms`));
      };
      function check() { if (matches()) finish(true); }
      mo.observe(document.documentElement, { childList: true, subtree: true, attributes: true });
      const poll = setInterval(() => { if (Date.now() > deadline) finish(false); else check(); }, 100);
      check();
    });
  }

  // ponytail: clone depth/keys capped; deeper results collapse to String().
  function safeClone(v, depth = 0) {
    if (v === null || v === undefined || ['string', 'number', 'boolean'].includes(typeof v)) return v;
    if (depth > 4) return String(v);
    if (Array.isArray(v)) return v.map((x) => safeClone(x, depth + 1));
    if (typeof v === 'object') {
      const o = {};
      for (const k of Object.keys(v).slice(0, 100)) o[k] = safeClone(v[k], depth + 1);
      return o;
    }
    return String(v);
  }

  const OPS = {
    click({ selector }) {
      const el = qs(selector);
      el.scrollIntoView({ block: 'center' });
      el.focus?.();
      for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) fire(el, type);
      return { clicked: true };
    },

    type({ selector, text, submit }) {
      const el = qs(selector);
      el.focus();
      const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
      const setter = Object.getOwnPropertyDescriptor(proto, 'value')?.set;
      if (setter) setter.call(el, text); // native setter so framework listeners fire
      else el.value = text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      if (submit) {
        const enter = keyInit('Enter');
        fireKey(el, 'keydown', enter);
        fireKey(el, 'keyup', enter);
        if (el.form) el.form.requestSubmit ? el.form.requestSubmit() : el.form.submit();
      }
      return { typed: true };
    },

    press_key({ key, selector }) {
      const target = selector ? qs(selector) : document.activeElement || document.body;
      const init = keyInit(key);
      for (const type of ['keydown', 'keypress', 'keyup']) fireKey(target, type, init);
      return { pressed: true };
    },

    select({ selector, value }) {
      const el = qs(selector);
      el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
      if (el.value !== String(value)) throw faErr('node_vanished', `option not found: ${value}`);
      return { selected: true };
    },

    read_dom({ selector, maxNodes = NODE_SOFT_CAP, includeShadow = false }) {
      const root = selector ? qs(selector) : document.body;
      if (!root) throw faErr('node_vanished', 'no root element (document.body empty)');
      return serializeDom(root, maxNodes, includeShadow);
    },

    wait_for: waitOp,

    eval({ code }) {
      try {
        return { result: safeClone(eval(code)) };
      } catch (e) {
        const csp = e instanceof EvalError || /CSP|Content Security Policy/i.test(String(e));
        throw faErr(csp ? 'csp' : 'bad_args', String(e.message || e));
      }
    },
  };

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg?.pv !== PV || typeof msg.op !== 'string') return;
    Promise.resolve()
      .then(() => (OPS[msg.op] || (() => { throw faErr('bad_args', `unknown op "${msg.op}"`); }))(msg.args || {}))
      .then((result) => sendResponse({ pv: PV, ok: true, result }))
      .catch((e) => sendResponse({ pv: PV, ok: false, error: { code: e.code || 'bad_args', error: String(e.message || e) } }));
    return true; // async response
  });
})();
