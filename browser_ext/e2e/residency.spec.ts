// Bridge resilience (AC4b/AC4c tail) against a REAL bridge: pair the
// extension with an in-process-faithful bridge server (spawned
// browser_ext/e2e/bridge_server.dart — the same BridgeServer `fa serve
// --bridge` wraps), drive a tracked agent tab, then KILL the bridge and
// bring it back: the reconnect retry budget must re-establish the session
// and the persisted pairing + keepalive alarm must still be in place (the
// SW-death revival mechanism).
//
// Why not a real SW kill: under an attached automation client Chrome never
// idle-stops a debugged service worker, and chrome.runtime.reload()
// PERMANENTLY unloads a --load-extension extension in a persistent context
// (probe: workers=0, chrome-extension:// blocked forever after). The
// observable contract — disconnect, then reconnect from persisted state —
// is what this spec pins; the alarm leg is asserted as "armed".
//
// CI-only by default (FA_E2E_CI=1): the retry cadence rides real socket
// timing that is flake-prone on developer machines.
import { spawn, type ChildProcess } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import { expect } from './helpers';
import { repoRoot, skipWithoutChrome, test } from './helpers';

const ciOnly = process.env.FA_E2E_CI === '1';

/** One free loopback port (reserve-then-release; tiny race, acceptable). */
async function freePort(): Promise<number> {
  const { promise, resolve, reject } = Promise.withResolvers<number>();
  const server = net.createServer();
  server.listen(0, '127.0.0.1', () => {
    const port = (server.address() as { port: number }).port;
    server.close(() => resolve(port));
  });
  server.on('error', reject);
  return promise;
}

interface BridgeHandle {
  process: ChildProcess;
  url: string;
  token: string;
  root: string;
  port: number;
}

/** Spawns the dart bridge server on a fixed port; resolves on its ready line. */
async function startBridge(port: number, root: string): Promise<BridgeHandle> {
  const { promise, resolve, reject } =
    Promise.withResolvers<BridgeHandle>();
  const child = spawn(
    'dart',
    ['run', 'browser_ext/e2e/bridge_server.dart', root, String(port)],
    { cwd: repoRoot, stdio: ['ignore', 'pipe', 'inherit'] },
  );
  let out = '';
  child.stdout!.on('data', (chunk: Buffer) => {
    out += chunk.toString('utf8');
    const line = out.split('\n').find((l) => l.startsWith('{'));
    if (line) {
      const ready = JSON.parse(line) as { url: string; token: string };
      resolve({ process: child, url: ready.url, token: ready.token, root, port });
    }
  });
  child.on('exit', (code) =>
    reject(new Error(`bridge_server.dart exited early (${code}): ${out}`)),
  );
  return promise;
}

test.describe('service worker residency', () => {
  skipWithoutChrome();
  test.skip(
    !ciOnly,
    'rides real MV3 idle shutdown + alarm revival — CI only (FA_E2E_CI=1)',
  );

  let bridgeRoot = '';
  let bridgePort = 0;
  let bridge: BridgeHandle | null = null;

  test.beforeAll(async () => {
    bridgeRoot = await mkdtemp(path2Join('fa-e2e-bridge-'));
    bridgePort = await freePort();
    bridge = await startBridge(bridgePort, bridgeRoot);
  });

  test.afterAll(async () => {
    bridge?.process.kill('SIGKILL');
    if (bridgeRoot) await rm(bridgeRoot, { recursive: true, force: true });
  });

  test('bridge reconnects after a bridge bounce (retry budget + armed keepalive)', async ({
    fa,
  }) => {
    // Pair exactly like the panel's connect handler: storage cfg + connect.
    await fa.swEval(
      async ([url, token]) => {
        const chromeApi = (
          globalThis as unknown as {
            chrome: {
              storage: {
                local: { set(k: Record<string, unknown>): Promise<void> };
              };
            };
          }
        ).chrome;
        await chromeApi.storage.local.set({ bridgeUrl: url, token });
      },
      [bridge!.url, bridge!.token],
    );
    await fa.swEval(
      ([url, token]) => {
        const seams = globalThis as unknown as BridgeHost; // seams bound by sw/agent.js
        return seams.faSw.bridge.connect(url, token);
      },
      [bridge!.url, bridge!.token],
    );
    await expect
      .poll(
        () =>
          fa.swEval(() => {
            const seams = globalThis as unknown as BridgeHost; // seams bound by sw/agent.js
            return seams.faSw.bridge.status();
          }),
        { timeout: 30_000 },
      )
      .toMatchObject({ phase: 'connected' });

    // A tracked agent tab exists under the bridge task (beginTask ran on
    // `connected` inside main.js).
    const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
    expect(nav.ok, JSON.stringify(nav.error)).toBe(true);

    // The bounce: bridge dies, the SW enters reconnecting (backoff within
    // its in-worker retry budget), the bridge returns on the same port —
    // the next scheduled retry (or the 1-min alarm once the budget stops
    // in-worker timers) must land on `connected` with the SAME task group.
    await fa.panel.close();
    bridge!.process.kill('SIGKILL');
    bridge = null;
    await expect
      .poll(
        () =>
          fa.swEval(() => {
            const seams = globalThis as unknown as BridgeHost; // seams bound by sw/agent.js
            return seams.faSw.bridge.status();
          }),
        { timeout: 20_000 },
      )
      .toMatchObject({ phase: 'reconnecting' });
    bridge = await startBridge(bridgePort, bridgeRoot);

    // Reconnected: same pairing, task group still adopted, agent still
    // booted (the SW never died — everything survived the bridge bounce).
    await expect
      .poll(
        () =>
          fa.swEval(() => {
            const seams = globalThis as unknown as BridgeHost; // seams bound by sw/agent.js
            return seams.faSw.bridge.status();
          }),
        { timeout: 120_000 },
      )
      .toMatchObject({ phase: 'connected' });
    // The revival mechanism is armed: the 1-minute keepalive alarm owns
    // retries once the in-worker budget stops (bridge.js RETRY_TIMER_ATTEMPTS).
    const alarms = await fa.swEval(async () => {
      const ext = globalThis as unknown as {
        chrome: { alarms: { getAll(): Promise<{ name: string }[]> } };
      };
      return (await ext.chrome.alarms.getAll()).map((a) => a.name);
    });
    expect(alarms).toContain('fa-bridge-keepalive');
    await expect
      .poll(
        () =>
          fa.swEval(() => {
            const seams = globalThis as unknown as BootedHost; // seams bound by sw/agent.js
            return Boolean(seams.faAgent?.getState().booted);
          }),
        { timeout: 60_000 },
      )
      .toBe(true);
    await expect
      .poll(
        () =>
          fa.swEval(() => {
            const seams = globalThis as unknown as TaskStatusHost; // seams bound by sw/agent.js
            return seams.faSw?.status() ?? {};
          }),
      )
      .toMatchObject({ taskId: expect.any(String) });
  });
});

/** bridge seam on the worker (faSw is reassembled by the js glue). */
interface BridgeSeam {
  connect(url: string, token: string): Promise<void>;
  status(): { phase: string } & Record<string, unknown>;
}
/** SW runtime seam hosts (bound by sw/agent.js; faSw reassembled by glue). */
type BridgeHost = { faSw: { bridge: BridgeSeam } };
type BootedHost = { faAgent?: { getState(): { booted: boolean } } };
type TaskStatusHost = { faSw?: { status(): { taskId?: string } } };

/** os.tmpdir()-rooted temp path prefix (kept tiny — mkdtemp needs a prefix). */
function path2Join(prefix: string): string {
  return `${os.tmpdir()}/${prefix}`;
}
