(() => { // Classic-SW module scope: nothing leaks into the shared importScripts global.
// SW fetch bridge (issue #470): the office pane (fa1.dev inside the Outlook
// tab) is page-context JS — provider fetches there die on CORS (z.ai et al.
// send no ACAO headers). This service worker owns host_permissions
// (<all_urls>) and fetches CORS-free, so the pane routes its provider HTTP
// through: page →(postMessage)→ content/embed_relay.js →(runtime Port)→ here
// → fetch → back, chunked. Additive and context-gated: only the embedded pane
// asks (embed_relay.js is the only caller); the plain-web tab and the side
// panel (extension origin, already CORS-free) keep their direct transports.
//
// One transport for every call — a `fa.http.stream` Port: the first frame is
// the request, the answer is a head frame, then chunk frames, then exactly one
// end/err frame (AC2: the tail chunk is never dropped — the end frame is
// asserted in test/fetch_bridge.test.mjs). Revoked-host and dead-port
// failures surface as one clean err frame (E2/E4), never a hang.

const frameErr = (error) => ({ t: 'err', error: String(error?.message || error) });

/** ArrayBuffer/TypedArray → base64 (chunked — String.fromCharCode.apply on a
 *  whole multi-MB body overflows the arg-count stack). */
function bufToB64(bytes) {
  const u8 = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let out = '';
  for (let i = 0; i < u8.length; i += 0x8000) {
    out += String.fromCharCode.apply(null, u8.subarray(i, i + 0x8000));
  }
  return btoa(out);
}

/** base64 → request body bytes. */
function b64ToBytes(b64) {
  const bin = atob(b64);
  const u8 = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
  return u8;
}

/** Safe port write: OWA rewrites its frames constantly and a port can die
 *  between our reads — a throw here must never become an uncaught rejection. */
function post(port, frame) {
  try {
    port.postMessage(frame);
  } catch {}
}

// Issue #633 E2: Port activity every 25 s keeps the MV3 worker alive
// through provider streams longer than the idle limit. Test seam: the
// sandbox can shorten it via FA_KEEPALIVE_MS.
const KEEPALIVE_MS = Number(globalThis.FA_KEEPALIVE_MS) || 25_000;

/** One bridged fetch. `emit(frame)` streams head/chunks; resolves when the
 *  stream is fully consumed (or rejects only on pre-response failure — the
 *  caller turns everything into one final err frame either way).
 *
 *  Issue #633 E2: a provider that streams for minutes (or pauses >30 s)
 *  would otherwise let the MV3 service worker idle-kill mid-stream — the
 *  Port dies, the pane hangs. A keepalive frame every `keepAliveMs` counts
 *  as Port activity and resets the idle timer; the client ignores the
 *  frame (unknown frame type), the relay forwards it untouched. */
async function streamFetch(req, emit, signal, keepAliveMs = KEEPALIVE_MS) {
  const keepalive = setInterval(
    () => emit({ t: 'keepalive' }),
    keepAliveMs,
  );
  try {
    const res = await fetch(req.url, {
      method: req.method || 'GET',
      headers: req.headers || {},
      body: req.bodyB64 != null ? b64ToBytes(req.bodyB64) : undefined,
      // Provider traffic rides cookies on cookie-auth hosts (CodeMie et al. —
      // same default as dart/src/fetch_client_web.dart in the SW agent).
      credentials: req.credentials === 'omit' ? 'omit' : 'include',
      signal,
    });
    emit({ t: 'head', status: res.status, headers: Object.fromEntries(res.headers.entries()) });
    if (!res.body) {
      emit({ t: 'end' });
      return;
    }
    const reader = res.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      emit({ t: 'chunk', b64: bufToB64(value) });
    }
    emit({ t: 'end' });
  } finally {
    clearInterval(keepalive);
  }
}

/** Port pump: request frame in, head/chunk/end frames out. The port dying
 *  (E4: OWA nuked the frame mid-stream) aborts the upstream fetch — the
 *  sender never keeps retrying into a corpse. */
function pump(port) {
  const ctrl = new AbortController();
  port.onMessage.addListener((msg) => {
    if (msg?.t !== 'req') return;
    streamFetch(msg.req ?? {}, (frame) => post(port, frame), ctrl.signal)
      .catch((e) => post(port, frameErr(e)));
  });
  port.onDisconnect.addListener(() => ctrl.abort());
}

chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== 'fa.http.stream') return;
  pump(port);
});

// Test seam (vm-loaded by test/fetch_bridge.test.mjs); harmless in the SW.
globalThis.faSw = Object.assign(globalThis.faSw ?? {}, { fetchBridge: { bufToB64, b64ToBytes, streamFetch } });
})();
