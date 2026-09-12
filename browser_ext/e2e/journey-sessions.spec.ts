// USER-JOURNEY e2e: two sessions, messages in both, switch back and
// forth — each session's transcript must replay intact. Drives the REAL
// fa-ui-v2 protocol on the BUILT panel (app bundle present; the page
// lands on app/index.html).
import fs from 'node:fs';
import { appBundlePresent, expect, test } from './helpers';

// Needs the --with-app build: helpers.appBundlePresent probes the bundle
// (gitignored browser_ext/panel/app/); lean CI checkouts have no app page
// to drive. Runs locally and in the FA_E2E_WITH_APP job, skips otherwise.

type Msg = Record<string, unknown>;

interface ExtPageChrome {
  chrome: { runtime: { connect(connectInfo: { name: string }): UiPort } };
}
interface UiPort {
  onMessage: { addListener: (cb: (m: unknown) => void) => void };
  postMessage: (m: unknown) => void;
}
interface PortWindow {
  __port?: UiPort;
  __msgs: Msg[];
}

async function attachPort(page: import('@playwright/test').Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as PortWindow;
    w.__msgs = [];
    const ext = window as unknown as ExtPageChrome;
    const port = ext.chrome.runtime.connect({ name: 'fa-ui-v2' });
    w.__port = port;
    port.onMessage.addListener((m) => w.__msgs.push(m as Msg));
    port.postMessage({ kind: 'hello', protoVersion: 2, capabilities: ['e2e'] });
  });
}

async function portSend(
  page: import('@playwright/test').Page,
  msg: Msg,
): Promise<void> {
  await page.evaluate((m) => {
    const w = window as unknown as PortWindow;
    return w.__port?.postMessage(m);
  }, msg);
}

async function portMsg(
  page: import('@playwright/test').Page,
  kind: string,
  timeout = 30_000,
): Promise<Msg | null> {
  let found: Msg | undefined;
  await expect
    .poll(async () => {
      found = ((await page.evaluate(() => {
        const w = window as unknown as PortWindow;
        return w.__msgs ?? [];
      })) as Msg[]).find((m) => m['kind'] === kind);
      return found ?? null;
    }, { timeout })
    .not.toBeNull();
  return found!;
}

/** Waits for the assistant echo of the scripted fake (text starts "fake:"). */
async function waitAssistantEcho(page: import('@playwright/test').Page) {
  let found: Msg | undefined;
  await expect
    .poll(async () => {
      found = ((await page.evaluate(() => {
        const w = window as unknown as PortWindow;
        return w.__msgs ?? [];
      })) as Msg[]).find((m) => {
        if (m['kind'] !== 'message_done') return false;
        // Live rows nest the payload under `message`.
        const msg = (m['message'] ?? m) as Msg;
        return (
          msg['role'] === 'assistant' &&
          String(msg['text'] ?? '').startsWith('fake:')
        );
      });
      return found ?? null;
    }, { timeout: 45_000 })
    .not.toBeNull();
  return found!;
}

test.describe('user journey: two sessions, switch, history intact', () => {
  test('create A → привет, create B → вкладки, switch A↔B', async ({ fa }) => {
    test.skip(
      !appBundlePresent,
      'needs the --with-app build (browser_ext/panel/app/ missing)',
    );
    test.setTimeout(180_000);
    fs.mkdirSync('/tmp/fa-shots', { recursive: true });
    const page = fa.panel;
    await page.waitForURL('**/app/index.html', { timeout: 20_000 });
    await page.waitForTimeout(2_500); // app boot + its own relay attach

    await attachPort(page);
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'attach', sessionId: null, lastEventId: null });
    const a = await portMsg(page, 'attached');
    const sessionA = a?.['sessionId'] as string;
    expect(sessionA).toBeTruthy();

    // Session A: "привет".
    await portSend(page, { kind: 'prompt', id: 'j-a', text: 'привет' });
    const doneA = await waitAssistantEcho(page);
    const doneMsg = (doneA?.['message'] ?? doneA) as Msg | undefined;
    expect(String(doneMsg?.['text'] ?? '')).toContain('привет');

    // Session B: "какие вкладки ты видишь". Fresh collector FIRST — the
    // accumulated one still holds A's `attached`, a stale match returns
    // before host.newSession() lands, and the attach below then re-adopts
    // A (flaky sessionB==sessionA, #152). Both `attached` rows carry the
    // same sessionId+replay, so whichever find() sees first is correct.
    await attachPort(page);
    await portSend(page, { kind: 'session_new' });
    await portMsg(page, 'attached');
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'attach', sessionId: null, lastEventId: null });
    const b = await portMsg(page, 'attached');
    const sessionB = b?.['sessionId'] as string;
    expect(sessionB).toBeTruthy();
    expect(sessionB).not.toBe(sessionA);
    await portSend(page, {
      kind: 'prompt',
      id: 'j-b',
      text: 'какие вкладки ты видишь',
    });
    await waitAssistantEcho(page);

    // ── Switch back to A ──
    // Fresh collector BEFORE the op (stale-row race, #152): portMsg must
    // await THIS switch's ack, not an earlier `attached`.
    await attachPort(page);
    await portSend(page, { kind: 'session_open', sessionId: sessionA });
    await portMsg(page, 'attached');
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'attach', sessionId: null, lastEventId: null });
    const ra = await portMsg(page, 'attached');
    const replayA = JSON.stringify(ra?.['replay'] ?? []);
    expect(replayA).toContain('привет');
    expect(replayA).not.toContain('вкладки');

    // ── Switch to B ──
    await attachPort(page); // fresh collector FIRST (stale-row race, #152)
    await portSend(page, { kind: 'session_open', sessionId: sessionB });
    await portMsg(page, 'attached');
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'attach', sessionId: null, lastEventId: null });
    const rb = await portMsg(page, 'attached');
    const replayB = JSON.stringify(rb?.['replay'] ?? []);
    expect(replayB).toContain('вкладки');
    expect(replayB).not.toContain('привет');

    // The APP UI itself: reload on A → its relay attaches to the live
    // session and renders the transcript visually.
    await attachPort(page); // fresh collector FIRST (stale-row race, #152)
    await portSend(page, { kind: 'session_open', sessionId: sessionA });
    await portMsg(page, 'attached');
    await page.reload();
    await page.waitForTimeout(4_000);
    await page.screenshot({ path: '/tmp/fa-shots/journey-session-A.png' });
    // Back to B, screenshot as well.
    await attachPort(page);
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'session_open', sessionId: sessionB });
    await portMsg(page, 'attached');
    await page.reload();
    await page.waitForTimeout(4_000);
    await page.screenshot({ path: '/tmp/fa-shots/journey-live.png' });

    // The sessions DRAWER: after the A↔B dance the list must show BOTH
    // (live B + archived A) — "нет прошлой сессии" regression guard.
    await attachPort(page);
    await portMsg(page, 'hello_ack');
    await portSend(page, { kind: 'sessions_query' });
    const sq = await portMsg(page, 'sessions_result');
    const ids = ((sq?.['sessions'] ?? []) as Msg[]).map((r) =>
      String(r['id']),
    );
    // eslint-disable-next-line no-console
    console.log('SESSION IDS:', JSON.stringify(ids));
    expect(ids).toContain(sessionA);
    expect(ids).toContain(sessionB);
    // No twins: a restored session must be listed once, not live+archive.
    expect(ids.filter((id) => id === sessionB)).toHaveLength(1);
    // eslint-disable-next-line no-console
    console.log(
      'JOURNEY OK:',
      JSON.stringify({
        sessionA: sessionA.slice(0, 8),
        sessionB: sessionB.slice(0, 8),
      }),
    );
  });
});
