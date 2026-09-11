// REGRESSION (sessions drawer): a session_new/session_open from ANY
// surface arrives as an attach broadcast; every connected page must
// adopt the new live session id (the drawer's relay filter otherwise
// hid the archived row and the active dot stayed on a stale row).
import fs from 'node:fs';
import path from 'node:path';
import { repoRoot, test, expect } from './helpers';

const appBundlePresent = fs.existsSync(
  path.join(repoRoot, 'browser_ext', 'panel', 'app', 'index.html'),
);

type Msg = Record<string, unknown>;

async function attachPort(page: import('@playwright/test').Page) {
  await page.evaluate(() => {
    const w = window as unknown as {
      chrome: { runtime: { connect(c: { name: string }): unknown } };
      __port?: { onMessage: { addListener: (cb: (m: unknown) => void) => void }; postMessage: (m: unknown) => void };
      __msgs?: Msg[];
    };
    w.__msgs = [];
    const port = w.chrome.runtime.connect({ name: 'fa-ui-v2' });
    w.__port = port as never;
    port.onMessage.addListener((m) => (w.__msgs as Msg[]).push(m as Msg));
    port.postMessage({ kind: 'hello', protoVersion: 2, capabilities: ['e2e'] });
  });
  await expect
    .poll(async () => {
      const msgs = (await page.evaluate(
        () => (window as unknown as { __msgs?: Msg[] }).__msgs ?? [],
      )) as Msg[];
      return msgs.some((m) => m['kind'] === 'hello_ack');
    }, { timeout: 30_000 })
    .toBe(true);
}

async function send(page: import('@playwright/test').Page, msg: Msg) {
  await page.evaluate((m) => {
    (
      window as unknown as { __port: { postMessage: (m: unknown) => void } }
    ).__port.postMessage(m);
  }, msg);
}

async function lastMsg(
  page: import('@playwright/test').Page,
  kind: string,
  timeout = 30_000,
): Promise<Msg> {
  let found: Msg | undefined;
  await expect
    .poll(async () => {
      const msgs = (await page.evaluate(
        () => (window as unknown as { __msgs?: Msg[] }).__msgs ?? [],
      )) as Msg[];
      found = [...msgs].reverse().find((m) => m['kind'] === kind);
      return found ?? null;
    }, { timeout })
    .not.toBeNull();
  return found!;
}

async function waitEcho(page: import('@playwright/test').Page) {
  await expect
    .poll(async () => {
      const msgs = (await page.evaluate(
        () => (window as unknown as { __msgs?: Msg[] }).__msgs ?? [],
      )) as Msg[];
      return msgs.some((m) => {
        if (m['kind'] !== 'message_done') return false;
        const msg = (m['message'] ?? m) as Msg;
        return (
          msg['role'] === 'assistant' &&
          String(msg['text'] ?? '').startsWith('fake:')
        );
      });
    }, { timeout: 45_000 })
    .toBe(true);
}

test('switch from a raw port: page adopts + drawer lists both', async ({
  fa,
}) => {
  test.skip(
    !appBundlePresent,
    'needs the --with-app build (browser_ext/panel/app/ missing)',
  );
  test.setTimeout(240_000);
  const consoleLines: string[] = [];
  fa.panel.on('console', (m) => consoleLines.push(m.text()));
  const page = fa.panel;
  await page.setViewportSize({ width: 500, height: 900 });
  await page.waitForURL('**/app/index.html', { timeout: 20_000 });
  await page.waitForTimeout(3_000);

  // The PAGE's own session (via its UI): create A through the drawer tile.
  await attachPort(page);
  await send(page, { kind: 'attach', sessionId: null, lastEventId: null });
  const a = await lastMsg(page, 'attached');
  const sessionA = a!['sessionId'] as string;
  await send(page, { kind: 'prompt', id: 's-a', text: 'привет А' });
  await waitEcho(page);

  // Create B + prompt (raw port = "another surface").
  await send(page, { kind: 'session_new' });
  const b = await lastMsg(page, 'attached');
  const sessionB = b!['sessionId'] as string;
  await send(page, { kind: 'prompt', id: 's-b', text: 'привет Б' });
  await waitEcho(page);
  await page.waitForTimeout(4_000); // broadcast adoption + 3s poll

  // Switch BACK to A from the raw port (session_open). Wait for an
  // attached BEYOND the ones already recorded (poll would otherwise
  // match the session_new-era broadcast instantly).
  const before = await page.evaluate(
    () =>
      (
        (window as unknown as { __msgs?: Msg[] }).__msgs ?? []
      ).filter((m) => m['kind'] === 'attached').length,
  );
  await send(page, { kind: 'session_open', sessionId: sessionA });
  let back: Msg | undefined;
  await expect
    .poll(async () => {
      const msgs = (await page.evaluate(
        () => (window as unknown as { __msgs?: Msg[] }).__msgs ?? [],
      )) as Msg[];
      const attached = msgs.filter((m) => m['kind'] === 'attached');
      back = attached[before]; // first attached after the session_open
      return back ?? null;
    }, { timeout: 30_000 })
    .not.toBeNull();
  expect(back!['sessionId']).toBe(sessionA);
  await page.waitForTimeout(4_000);

  const switchLogs = consoleLines.filter((l) =>
    l.includes('live session switched'),
  );
  console.log(
    'IDS', JSON.stringify({ a: sessionA, b: sessionB }),
    '\nSWITCH-LOGS:', JSON.stringify(switchLogs, null, 1),
  );
  // The page must have adopted BOTH the session_new (A→B) and the
  // session_open (B→A) broadcasts.
  expect(switchLogs.length).toBeGreaterThanOrEqual(2);
});
