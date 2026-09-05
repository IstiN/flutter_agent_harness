// CDP (chrome.debugger) transport — intentionally a stub this phase.
// Later phase fills the trusted-event attach/call path; permission already in manifest.

const cdpEnabled = false;

/** Placeholder for the future debugger-backed call path. */
async function cdpCall() {
  throw Object.assign(new Error('cdp not implemented in this phase'), { code: 'not_implemented' });
}

// Classic-SW module glue (see tabs.js).
globalThis.faSw = Object.assign(globalThis.faSw ?? {}, { cdpEnabled, cdpCall });
