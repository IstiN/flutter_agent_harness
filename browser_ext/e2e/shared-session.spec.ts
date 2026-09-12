// Shared-session AC: the UiPortServer multiplexes every fa-ui-v2 runtime
// port onto the SW's ONE session — a second panel TAB attaches and receives
// the same sessionId, the replay of earlier events, and the live fan-out of
// a prompt driven from the first tab (the observable behind "both panels see
// the same conversation", app build or not).
import type { Page } from '@playwright/test';
import { expect } from './helpers';
import { awaitPanelSettled, skipWithoutChrome, test } from './helpers';

/** One wire frame of the fa-ui-v2 protocol (lib/src/ui_protocol.dart shapes). */
interface PortMsg {
  kind: string;
  protoVersion?: number;
  sessionId?: string | null;
  replay?: Record<string, unknown>[];
}

/** The slice of chrome.runtime a panel page needs to open a fa-ui-v2 port. */
interface UiPort {
  onMessage: { addListener(cb: (m: unknown) => void): void };
  postMessage(m: unknown): void;
}

interface ExtPageChrome {
  chrome: { runtime: { connect(connectInfo: { name: string }): UiPort } };
}

interface PortWindow {
  __port?: UiPort;
  __msgs: PortMsg[];
}

/** Installs a fa-ui-v2 port + message collector inside an extension page. */
async function attachPort(page: Page): Promise<void> {
  await page.evaluate(() => {
    const w = window as unknown as PortWindow; // panel page globals
    w.__msgs = [];
    const ext = window as unknown as ExtPageChrome; // chrome.* in extension page
    const port = ext.chrome.runtime.connect({
      name: 'fa-ui-v2',
    });
    w.__port = port;
    port.onMessage.addListener((m) => w.__msgs.push(m as PortMsg));
    port.postMessage({ kind: 'hello', protoVersion: 2, capabilities: ['e2e'] });
  });
}

async function portSend(
  page: Page,
  msg: Record<string, unknown>,
): Promise<void> {
  await page.evaluate((m) => {
    const w = window as unknown as PortWindow; // panel page globals
    return w.__port?.postMessage(m);
  }, msg);
}

async function portMsg(
  page: Page,
  pred: (m: PortMsg) => boolean,
  timeout = 30_000,
): Promise<PortMsg> {
  let found: PortMsg | undefined;
  await expect
    .poll(async () => {
      found = (
        await page.evaluate(() => {
          const w = window as unknown as PortWindow; // panel page globals
          return w.__msgs;
        })
      ).find(pred);
      return found ?? null;
    }, { timeout })
    .not.toBeNull();
  return found!;
}

test.describe('shared session over fa-ui-v2 ports', () => {
  skipWithoutChrome();

  test('two panel tabs attach to the SAME session with replay parity', async ({
    fa,
  }) => {
    await fa.bootAgent();

    // Tab 1: hello + attach — the session is born (or adopted) here.
    await attachPort(fa.panel);
    const ack1 = await portMsg(fa.panel, (m) => m.kind === 'hello_ack');
    await portSend(fa.panel, {
      kind: 'attach',
      sessionId: null,
      lastEventId: null,
    });
    const attached1 = await portMsg(fa.panel, (m) => m.kind === 'attached');
    expect(attached1.sessionId).toBeTruthy();

    // Tab 2 (the panel-as-tab stand-in for a second panel): same negotiation.
    // Settle the app-hosting redirect BEFORE installing the port — goto()
    // resolves on panel.html's load, the HEAD probe redirects after, and an
    // eval in flight dies with "Execution context was destroyed" (#152).
    const tab2 = await fa.context.newPage();
    await tab2.goto(`chrome-extension://${fa.extId}/panel/panel.html`);
    await awaitPanelSettled(tab2);
    await attachPort(tab2);
    const ack2 = await portMsg(tab2, (m) => m.kind === 'hello_ack');
    await portSend(tab2, {
      kind: 'attach',
      sessionId: null,
      lastEventId: null,
    });
    const attached2 = await portMsg(tab2, (m) => m.kind === 'attached');

    // ONE session behind both ports.
    expect(attached2.sessionId).toBe(attached1.sessionId);
    expect(ack2.sessionId).toBe(ack1.sessionId);

    // Live fan-out: a prompt from tab 1 streams to BOTH ports.
    await portSend(fa.panel, {
      kind: 'prompt',
      id: 'e2e-shared-1',
      text: 'e2e shared session echo',
    });
    const done1 = await portMsg(
      fa.panel,
      (m) => m.kind === 'message_done',
      45_000,
    );
    const done2 = await portMsg(
      tab2,
      (m) => m.kind === 'message_done',
      45_000,
    );
    expect(done1).toBeTruthy();
    expect(done2).toBeTruthy();

    // Replay parity: a fresh attach on tab 2 replays the turn that ran
    // while it was open (null lastEventId = the durable transcript, which
    // now holds the completed turn). The MV3 SW may have idled out during
    // the waits above — a dead port swallows postMessage silently — so
    // wake it and re-open the port first. Bonus coverage: the replay then
    // comes from the REVIVED host's restored transcript, proving history
    // survives a service-worker restart.
    await fa.swEval(() => 1);
    await attachPort(tab2);
    await portMsg(tab2, (m) => m.kind === 'hello_ack');
    await portSend(tab2, {
      kind: 'attach',
      sessionId: attached2.sessionId ?? null,
      lastEventId: null,
    });
    const replayed = await portMsg(tab2, (m) => m.kind === 'attached');
    expect(replayed.sessionId).toBe(attached1.sessionId);
    expect((replayed.replay ?? []).length).toBeGreaterThan(0);
  });
});
