// SMOKE (sw/main.js hub.* handlers): bookmarks list — save preserves it,
// hub.connections.set overwrites it, hub.switch re-points faDap with the
// entry's secret semantics (open bookmark clears the stored password).
import { test, expect } from './helpers';

type Msg = Record<string, unknown>;

test('multi-hub bookmarks: set / preserve / switch / secret semantics', async ({
  fa,
}) => {
  test.setTimeout(120_000);
  const page = fa.panel;
  await page.waitForURL('**/app/index.html', { timeout: 20_000 });
  await page.waitForTimeout(2_000);

  const send = (msg: Msg) =>
    page.evaluate(
      (m) =>
        (
          window as unknown as {
            chrome: {
              runtime: { sendMessage: (m: unknown) => Promise<unknown> };
            };
          }
        ).chrome.runtime.sendMessage(m),
      msg,
    );
  const store = () =>
    page.evaluate(() =>
      (
        window as unknown as {
          chrome: {
            storage: {
              local: { get: (k: string) => Promise<Record<string, unknown>> };
            };
          };
        }
      ).chrome.storage.local.get('faDap'),
    );

  // 1. Save the first (active) connection.
  const saved = (await send({
    type: 'hub.save',
    url: 'ws://127.0.0.1:9999/ws',
    name: 'One',
    secret: 'pw1',
  })) as Msg;
  expect(saved['ok']).toBe(true);

  // 2. Bookmark three connections.
  const set = (await send({
    type: 'hub.connections.set',
    list: [
      { url: 'ws://127.0.0.1:9999/ws', name: 'One', secret: 'pw1' },
      { url: 'ws://127.0.0.1:8888/ws', name: 'Two', secret: 'pw2' },
      { url: 'ws://127.0.0.1:7777/ws', name: 'Open' },
    ],
  })) as Msg;
  expect(set['ok']).toBe(true);
  expect(set['count']).toBe(3);

  // 3. Re-saving the active connection (blank secret) PRESERVES the list.
  await send({ type: 'hub.save', url: 'ws://127.0.0.1:9999/ws', name: 'One' });
  let dap = ((await store()) as { faDap: Msg })['faDap'];
  expect((dap['savedConnections'] as unknown[]).length).toBe(3);
  expect(dap['secret']).toBe('pw1'); // kept — blank means keep

  // 4. Switch to Two: secret comes from the bookmark.
  const sw = (await send({
    type: 'hub.switch',
    url: 'ws://127.0.0.1:8888/ws',
  })) as Msg;
  expect(sw['ok']).toBe(true);
  dap = ((await store()) as { faDap: Msg })['faDap'];
  expect(dap['url']).toBe('ws://127.0.0.1:8888/ws');
  expect(dap['secret']).toBe('pw2');

  // 5. Switch to the open bookmark: the stored password is CLEARED.
  await send({ type: 'hub.switch', url: 'ws://127.0.0.1:7777/ws' });
  dap = ((await store()) as { faDap: Msg })['faDap'];
  expect(dap['url']).toBe('ws://127.0.0.1:7777/ws');
  expect('secret' in dap).toBe(false);

  // 6. Switching to an unknown url refuses.
  const bad = (await send({
    type: 'hub.switch',
    url: 'ws://127.0.0.1:6666/ws',
  })) as Msg;
  expect(bad['ok']).toBe(false);
});
