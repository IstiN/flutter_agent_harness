// CDP (chrome.debugger) transport — intentionally a stub this phase.
// Later phase fills the trusted-event attach/call path; permission already in manifest.

export const cdpEnabled = false;

/** Placeholder for the future debugger-backed call path. */
export async function cdpCall() {
  throw Object.assign(new Error('cdp not implemented in this phase'), { code: 'not_implemented' });
}
