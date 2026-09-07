// Service-worker residency (AC4b/AC4c tail) against a REAL bridge: pair the
// extension with an in-process-faithful bridge server (spawned
// browser_ext/e2e/bridge_server.dart — the same BridgeServer `fa serve
// --bridge` wraps), drive a tracked agent tab, then close every extension
// page and STOP the bridge so the MV3 worker runs out of reasons to stay
// alive. The keepalive alarm must revive it, the boot path must reconnect
// from the persisted pairing, and tabs.init must re-adopt the surviving
// task group.
//
// CI-only by default (FA_E2E_CI=1): the wall time rides Chrome's real
// ~30-60s idle shutdown plus a ≤1min alarm tick, which is flake-prone on
// developer machines.
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

  test('bridge survives SW death and revives via the keepalive alarm', async ({
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
      ([url, token]) => faBridge().connect(url, token),
      [bridge!.url, bridge!.token],
    );
    await expect
      .poll(() => fa.swEval(() => faBridge().status()), { timeout: 30_000 })
      .toMatchObject({ phase: 'connected' });

    // A tracked agent tab exists under the bridge task (beginTask ran on
    // `connected` inside main.js).
    const nav = await fa.dispatch('navigate', { url: fa.fixture.url });
    expect(nav.ok, JSON.stringify(nav.error)).toBe(true);

    // No reason to stay alive: close the last extension page, drop the WS.
    await fa.panel.close();
    bridge!.process.kill('SIGKILL');
    bridge = null;

    await expect
      .poll(() => fa.context.serviceWorkers().length, {
        timeout: 180_000,
      })
      .toBe(0);

    // The bridge is back before the next alarm tick reconnects to it.
    bridge = await startBridge(bridgePort, bridgeRoot);

    // Revival: the 1-minute keepalive alarm restarts the worker, main()'s
    // boot path reconnects from the persisted pairing.
    await expect
      .poll(() => fa.context.serviceWorkers().length, { timeout: 150_000 })
      .toBeGreaterThan(0);
    await expect
      .poll(() => fa.swEval(() => faBridge().status()), { timeout: 60_000 })
      .toMatchObject({ phase: 'connected' });

    // The agent booted again and tabs.init re-adopted the surviving group.
    await expect
      .poll(() => fa.swEval(() => faAgentBooted()), { timeout: 60_000 })
      .toBe(true);
    await expect
      .poll(() => fa.swEval(() => faTaskStatus()))
      .toMatchObject({ taskId: expect.any(String) });
    const fixtureTabs = await fa.swEval(
      async (base) =>
        (
          await (
            globalThis as unknown as {
              chrome: {
                tabs: { query(i: { url: string }): Promise<unknown[]> };
              };
            }
          ).chrome.tabs.query({ url: `${base}*` })
        ).length,
      fa.fixture.url,
    );
    expect(fixtureTabs).toBeGreaterThan(0);
  });
});

/** bridge seam on the fresh worker (faSw is reassembled by the js glue). */
function faBridge(): {
  connect(url: string, token: string): Promise<void>;
  status(): { phase: string } & Record<string, unknown>;
} {
  return (
    globalThis as unknown as {
      faSw: {
        bridge: {
          connect(url: string, token: string): Promise<void>;
          status(): { phase: string } & Record<string, unknown>;
        };
      };
    }
  ).faSw.bridge;
}

function faAgentBooted(): boolean {
  return Boolean(
    (globalThis as unknown as { faAgent?: { getState(): { booted: boolean } } })
      .faAgent?.getState().booted,
  );
}

function faTaskStatus(): { taskId?: string } {
  return (
    globalThis as unknown as { faSw?: { status(): { taskId?: string } } }
  ).faSw?.status() ?? {};
}

/** os.tmpdir()-rooted temp path prefix (kept tiny — mkdtemp needs a prefix). */
function path2Join(prefix: string): string {
  return `${os.tmpdir()}/${prefix}`;
}
