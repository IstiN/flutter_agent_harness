// Issue #313: pasting LONG text into the v1 panel composer stages it into
// the SW agent's uploads/ sandbox over `agent.stageUpload` and sends a
// short path-reference — the full relay hop is proven when the agent's
// `read` tool returns the staged content from its own sandbox. The
// oversized paste is refused locally with the shared core wording.
//
// The composer under test lives in the legacy fallback UI (#prompt,
// #sendPrompt, #legacy) — same scope as panel-focus.spec.ts.
import type { Page } from '@playwright/test';
import { appBundlePresent, expect, skipWithoutChrome, test } from './helpers';

const MARKER = 'PASTE-STAGING-MARKER-9f2c1a';
// >200 KB of multi-line text (the shape that used to hit the
// UnsupportedError), marker on line 1 so any result truncation keeps it.
const LONG = [
  MARKER,
  ...Array.from({ length: 3500 }, (_, i) => `line-${i} ${'x'.repeat(50)}`),
].join('\n');

/**
 * Dispatches a REAL paste event with the given text into #prompt.
 * Returns whether the composer consumed it (preventDefault): the DOM
 * dispatchEvent contract is inverted — it returns FALSE when a cancelable
 * event was prevented, which is exactly the staging path.
 */
async function pasteText(page: Page, text: string): Promise<boolean> {
  const dispatched = await page.evaluate((payload) => {
    const dt = new DataTransfer();
    dt.setData('text/plain', payload);
    const ev = new ClipboardEvent('paste', {
      bubbles: true,
      cancelable: true,
    });
    Object.defineProperty(ev, 'clipboardData', { value: dt });
    return document.getElementById('prompt')!.dispatchEvent(ev);
  }, text);
  return !dispatched;
}

function logText(page: Page): Promise<string> {
  return page.evaluate(
    () => document.getElementById('log')?.textContent ?? '',
  );
}

test.describe('panel paste staging (issue #313)', () => {
  skipWithoutChrome();
  test.skip(
    appBundlePresent,
    'legacy composer only — the app build redirects the panel to app/',
  );

  test('long paste stages to the SW sandbox; the agent reads it back', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();
    await fa.panel.locator('#legacy').waitFor({ state: 'visible' });

    // 1. Paste: consumed by staging, composer cleared, path logged.
    expect(await pasteText(fa.panel, LONG)).toBe(true);
    await expect
      .poll(() => logText(fa.panel))
      .toContain('staged paste -> uploads/pasted-');
    await expect(fa.panel.locator('#prompt')).toHaveValue('');

    // 2. Ask the agent to read the staged file back — over the SAME env
    //    the staging wrote to (one SW hop, no phase-2 uploads surface).
    //    (The outgoing-turn FORMAT — one `[attached file: …]` reference
    //    line instead of the 200 KB inline — is pinned by the vm suite,
    //    test/panel_paste_test.mjs; the SW event stream carries only the
    //    assistant side, so the user turn is not observable here.)
    const staged = /staged paste -> (uploads\/pasted-\d+\.txt)/.exec(
      await logText(fa.panel),
    )![1];
    const after = (await fa.eventCount()) - 1;
    await fa.panel.fill('#prompt', `tool read {"path": "${staged}"}`);
    await fa.panel.click('#sendPrompt');

    // 3. The read tool result proves the hop end to end: the SW agent
    //    read the REAL staged bytes from its sandbox.
    const result = await fa.waitEvent(
      (e) => e.type === 'tool_result' && e.toolName === 'read',
      45_000,
      after,
    );
    expect(result.isError).toBeFalsy();
    expect(String(result.text)).toContain(MARKER);
  });

  test('oversized paste is refused locally with the shared wording', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();
    await fa.panel.locator('#legacy').waitFor({ state: 'visible' });

    // 20 MB staging cap + one byte, multi-line so the paste path engages.
    const big = `x\n${'y'.repeat(20 * 1024 * 1024)}`;
    expect(await pasteText(fa.panel, big)).toBe(true);
    await expect
      .poll(() => logText(fa.panel))
      .toContain(
        `paste rejected: ${big.length} bytes exceeds the 20 MB staging cap`,
      );
    // Nothing staged, nothing inline: the composer stays empty.
    expect(await logText(fa.panel)).not.toContain('staged paste ->');
    await expect(fa.panel.locator('#prompt')).toHaveValue('');

    // Send is a no-op with neither text nor staged files: no user turn.
    const after = (await fa.eventCount()) - 1;
    await fa.panel.click('#sendPrompt');
    let userTurns = 0;
    try {
      await fa.waitEvent(
        (e) => e.type === 'message_done' && e.role === 'user',
        5_000,
        after,
      );
      userTurns = 1;
    } catch {
      userTurns = 0; // expected: nothing was sent
    }
    expect(userTurns).toBe(0);
  });
});
