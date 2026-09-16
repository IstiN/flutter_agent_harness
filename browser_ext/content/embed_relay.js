(() => { // Isolated-world relay for the embedded fa pane (issue #470).
// The office taskpane is the fa web app at fa1.dev, framed inside the
// Outlook/OWA tab. Page JS cannot reach chrome.* — but WE run in every frame
// (manifest content_scripts, all_frames), so this relay carries the pane's
// provider HTTP across: page →(window.postMessage)→ here →(runtime Port)→
// the SW fetch bridge (sw/fetch_bridge.js) → back. Frames carry a reqId the
// page correlates; everything else is ignored, so the relay stays inert on
// every ordinary page.
//
// One transport: 'stream' — head/chunk/end frames flow as they happen, so
// provider SSE arrives incrementally and the tail chunk is never dropped
// (AC2). 'abort' tears the upstream port down, which aborts the SW fetch
// (the sender never retries into a dead frame).

if (globalThis.__faEmbedRelay) return;
globalThis.__faEmbedRelay = true;

const streams = new Map(); // reqId -> Port (live streams only)

function reply(reqId, fields) {
  try {
    window.postMessage({ __faEmbedRes: 1, reqId, ...fields }, window.location.origin);
  } catch {}
}

window.addEventListener('message', (event) => {
  if (event.source !== window) return;
  const m = event.data;
  if (!m || m.__faEmbed !== 1) return;

  if (m.kind === 'ping') {
    reply(m.reqId, { pong: true });
    return;
  }

  if (m.kind === 'stream') {
    const reqId = m.reqId;
    let port;
    try {
      port = chrome.runtime.connect({ name: 'fa.http.stream' });
    } catch (e) {
      reply(reqId, { frame: { t: 'err', error: String(e?.message || e) } });
      return;
    }
    streams.set(reqId, port);
    port.onMessage.addListener((frame) => {
      reply(reqId, { frame });
      if (frame?.t === 'end' || frame?.t === 'err') {
        try { port.disconnect(); } catch {}
        streams.delete(reqId);
      }
    });
    port.onDisconnect.addListener(() => {
      if (streams.delete(reqId)) reply(reqId, { frame: { t: 'err', error: 'bridge port closed' } });
    });
    try {
      port.postMessage({ t: 'req', req: m.req });
    } catch (e) {
      streams.delete(reqId);
      try { port.disconnect(); } catch {}
      reply(reqId, { frame: { t: 'err', error: String(e?.message || e) } });
    }
    return;
  }

  if (m.kind === 'abort') {
    const port = streams.get(m.reqId);
    if (port) {
      streams.delete(m.reqId);
      try { port.disconnect(); } catch {} // SW side aborts the fetch on disconnect
    }
  }
});
})();
