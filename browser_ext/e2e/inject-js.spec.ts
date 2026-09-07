// inject_js end to end (the always-prompting tool): the fake provider's
// scripted directive reaches the REAL chrome.debugger-backed tool through
// the agent loop, the approval gate prompts on EVERY call, and the two
// script worlds stay separated:
//   MAIN     → the page's own JS world (what page.evaluate sees);
//   ISOLATED → shares the DOM but not window; invisible from MAIN and the
//              other way around.
// A bad world fails cleanly with the tool's `bad_world` error (E2), never a
// throw into the agent loop.
import { expect } from './helpers';
import { FaHarness, skipWithoutChrome, test } from './helpers';

/** Runs one inject_js directive and shepherds it through the approval gate. */
async function inject(
  fa: FaHarness,
  tabId: number,
  world: string,
  code: string,
): Promise<{ isError: boolean; text: string }> {
  await fa.sendUser(`inject_js ${tabId} ${world} ${code}`);
  const request = await fa.waitEvent(
    (e) => e.type === 'approval_request' && String(e.summary).includes('inject_js'),
  );
  await fa.decide(request.id!, true);
  const result = await fa.waitEvent(
    (e) => e.type === 'tool_result' && e.toolName === 'inject_js',
  );
  return { isError: result.isError === true, text: String(result.text ?? '') };
}

/** Navigates the agent to the fixture and returns the tab id it opened. */
async function fixtureTab(fa: Awaited<Parameters<typeof inject>[0]>): Promise<number> {
  const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
  expect(nav.ok, JSON.stringify(nav.error)).toBe(true);
  return nav.result!.tabId!;
}

test.describe('inject_js worlds', () => {
  skipWithoutChrome();

  test('MAIN writes land in the page world the tab evaluates', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();
    const tabId = await fixtureTab(fa);

    const result = await inject(fa, tabId, 'MAIN', 'window.__faMain = 42');
    expect(result.isError, result.text).toBe(false);

    const page = await fa.fixturePage();
    expect(await page.evaluate(() => (window as unknown as { __faMain?: number }).__faMain)).toBe(42);
  });

  test('ISOLATED shares the DOM but not window — both directions', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();
    const tabId = await fixtureTab(fa);

    // ISOLATED global + DOM marker in one shot.
    const iso = await inject(
      fa,
      tabId,
      'ISOLATED',
      `window.__faIso = 'iso'; document.documentElement.dataset.faIso = '1'`,
    );
    expect(iso.isError, iso.text).toBe(false);

    const page = await fa.fixturePage();
    // MAIN cannot see the ISOLATED world's window global…
    expect(
      await page.evaluate(() => (window as unknown as { __faIso?: string }).__faIso),
    ).toBeUndefined();
    // …but the DOM write is visible (shared document).
    expect(await page.evaluate(() => document.documentElement.dataset.faIso)).toBe('1');

    // And the reverse: ISOLATED cannot see MAIN's window global either —
    // typeof (not a throw) because a missing global reads as undefined.
    const probe = await inject(fa, tabId, 'ISOLATED', 'typeof window.__faMain');
    expect(probe.isError, probe.text).toBe(false);
    expect(probe.text).toContain('undefined');
  });

  test('bad world → clean bad_world error, no code executed', async ({
    fa,
  }) => {
    await fa.bootAgent();
    await fa.collectEvents();
    const tabId = await fixtureTab(fa);

    const result = await inject(fa, tabId, 'SIDEWORLD', 'window.__faBad = 1');
    expect(result.isError, result.text).toBe(true);
    expect(result.text).toContain('bad_world');

    const page = await fa.fixturePage();
    expect(
      await page.evaluate(() => (window as unknown as { __faBad?: number }).__faBad),
    ).toBeUndefined();
  });
});
