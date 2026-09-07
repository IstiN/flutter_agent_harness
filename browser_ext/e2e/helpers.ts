// Shared e2e harness: launches a REAL headless Chrome with the unpacked
// extension (the exact flag set test/browser_ext/chrome_driver.dart uses),
// serves test/browser_ext/fixture/ over loopback, and exposes the SW test
// seams (globalThis.faAgent / faSw).
import {
  chromium,
  expect,
  test as base,
  type BrowserContext,
  type Page,
  type Worker,
} from '@playwright/test';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const e2eDir = path.dirname(fileURLToPath(import.meta.url));
export const repoRoot = path.resolve(e2eDir, '..', '..');
const extDir = path.join(repoRoot, 'browser_ext');
const PATH_NAMES = ['google-chrome', 'chromium', 'chromium-browser'];
const fixtureRoot = path.join(repoRoot, 'test', 'browser_ext', 'fixture');

/** The agent test seam bound by sw/agent.js (dart2js). */
interface FaAgentSeam {
  boot(config: Record<string, unknown>): Promise<{ ok: boolean }>;
  sendUser(text: string): void;
  decide(id: string, allow: boolean): void;
  onEvent(cb: (event: FaEvent) => void): void;
  getState(): { booted: boolean } & Record<string, unknown>;
  selfTest(): Promise<Record<string, unknown>>;
}

export interface FaSwSeam {
  dispatch(op: string, args: Record<string, unknown>): Promise<FaEnvelope>;
  beginTask(id: string): Promise<void>;
  taskEnd(): Promise<number>;
  status(): { taskId?: string; groupId?: number; tracked?: number };
  bridge: { status(): { phase: string } & Record<string, unknown> };
}

/** One agent event relayed through faAgent.onEvent. */
export type FaEvent = {
  type: string;
  id?: string;
  toolName?: string;
  isError?: boolean;
  summary?: string;
  text?: string;
} & Record<string, unknown>;

/** faSw.dispatch envelope: {ok:true,result} | {ok:false,error,code?}. */
export type FaEnvelope = {
  ok: boolean;
  result?: { tabId?: number } & Record<string, unknown>;
  error?: unknown;
};

type SwGlobals = { faAgent: FaAgentSeam; faSw: FaSwSeam; __faEvents?: FaEvent[] };

/** The seams live on the SW's globalThis; types document, runtime provides. */

/**
 * Playwright's Worker.evaluate retyped once for the seam boundary — its
 * Unboxed<A> inference artifact does not fit plain serializable args.
 */
interface SwEvaluate {
  evaluate<R, A>(fn: (arg: A) => R | Promise<R>, arg: A): Promise<R>;
}
const sw = () => globalThis as unknown as SwGlobals;

/** chrome.* surface available inside the extension's own pages. */
interface ExtPage {
  chrome: {
    runtime: {
      connect(connectInfo: { name: string }): {
        onMessage: { addListener(cb: (m: unknown) => void): void };
        postMessage(m: unknown): void;
      };
      sendMessage(msg: Record<string, unknown>): Promise<unknown>;
    };
    storage: { local: { set(keys: Record<string, unknown>): Promise<void> } };
  };
}

const extPage = () => window as unknown as ExtPage;

/** $CHROME_PATH wins, then the usual PATH names; null when nothing exists. */
export function chromeBinary(): string | null {
  const env = process.env.CHROME_PATH;
  if (env && fs.existsSync(env)) return env;
  for (const name of PATH_NAMES) {
    for (const dir of (process.env.PATH ?? '').split(':')) {
      if (!dir) continue;
      const candidate = path.join(dir, name);
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  return null;
}

/** One loud skip line per spec when no Chrome binary exists. */
export function skipWithoutChrome(): void {
  test.skip(
    chromeBinary() == null,
    'no Chrome binary (looked at $CHROME_PATH, google-chrome, chromium, '
      + 'chromium-browser) — install Chrome for Testing or export CHROME_PATH',
  );
}

/**
 * The unpacked extension's pinned id — sha256 over the manifest "key"'s
 * DER SPKI, first 16 bytes hex, digits mapped a-p (Chrome's GenerateId;
 * same algorithm as chrome_driver.dart, so key and id cannot drift apart
 * silently).
 */
export function extensionId(): string {
  const src = fs.readFileSync(path.join(extDir, 'manifest.json'), 'utf8');
  const json = JSON.parse(src.replace(/^\s*\/\/.*$/gm, '')) as { key: string };
  const hex = createHash('sha256')
    .update(Buffer.from(json.key, 'base64'))
    .digest('hex');
  return hex
    .slice(0, 32)
    .split('')
    .map((c) => String.fromCharCode(0x61 + parseInt(c, 16)))
    .join('');
}

/** Tiny loopback static server for test/browser_ext/fixture/. */
export class FixtureServer {
  private server: http.Server | null = null;
  private boundPort = 0;

  get url(): string {
    return `http://127.0.0.1:${this.boundPort}/`;
  }

  start(): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    this.server = http.createServer((req, res) => {
      const rel = (req.url ?? '/').split('?')[0];
      const file = path.join(fixtureRoot, rel === '/' ? 'index.html' : rel);
      fs.readFile(file, (err, data) => {
        if (err) {
          res.statusCode = 404;
          res.end();
          return;
        }
        res.setHeader(
          'content-type',
          file.endsWith('.js')
            ? 'text/javascript; charset=utf-8'
            : 'text/html; charset=utf-8',
        );
        res.end(data);
      });
    });
    this.server.listen(0, '127.0.0.1', () => {
      this.boundPort = (this.server!.address() as { port: number }).port;
      resolve();
    });
    return promise;
  }

  stop(): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    this.server?.close(() => resolve());
    this.server = null;
    return promise;
  }
}

/**
 * One launched Chrome + extension context + panel page + fixture server.
 * The panel opens as a regular TAB (the side panel cannot open headless —
 * the documented stand-in); its chrome.runtime traffic wakes the MV3
 * service worker.
 */
export class FaHarness {
  private constructor(
    readonly context: BrowserContext,
    readonly extId: string,
    readonly fixture: FixtureServer,
    readonly panel: Page,
  ) {}

  static async start(): Promise<FaHarness> {
    const fixture = new FixtureServer();
    await fixture.start();
    // Extensions only load in a PERSISTENT context — contexts from
    // browser.newContext() get no extensions (ERR_BLOCKED_BY_CLIENT on
    // chrome-extension:// navigations). The one documented Playwright path.
    const userDataDir = await fs.promises.mkdtemp(
      path.join(tmpdir(), 'fa-e2e-'),
    );
    const context = await chromium.launchPersistentContext(userDataDir, {
      executablePath: chromeBinary()!,
      headless: true, // new headless loads MV3 extensions
      args: [
        '--no-sandbox',
        '--disable-dev-shm-usage',
        '--disable-gpu',
        `--disable-extensions-except=${extDir}`,
        `--load-extension=${extDir}`,
      ],
    });
    const panel = context.pages()[0] ?? (await context.newPage());
    await panel.goto(`chrome-extension://${extensionId()}/panel/panel.html`);
    return new FaHarness(context, extensionId(), fixture, panel);
  }

  /** The extension SW target, waking it first (it only exists while it runs). */
  async sw(timeout = 45_000): Promise<Worker> {
    const alive = this.context
      .serviceWorkers()
      .find((w) => w.url().endsWith('/sw/main.js'));
    if (alive) return alive;
    try {
      // Fire-and-forget on purpose (mirrors wakeServiceWorker): awaiting the
      // sendMessage promise can hang while the worker boots.
      await this.panel.evaluate(() => {
        const pending = extPage().chrome.runtime.sendMessage({ type: 'status' });
        pending?.catch(() => {});
      });
    } catch {
      // Panel may be closed (residency spec); waitForEvent still sees revival.
    }
    return this.context.waitForEvent('serviceworker', {
      predicate: (w) => w.url().endsWith('/sw/main.js'),
      timeout,
    });
  }

  /**
   * Evaluates in the SW; one re-wake + retry when MV3 idled it out mid-call.
   * The boundary cast retypes playwright's evaluate once — its Unboxed<A>
   * inference artifact does not fit the seam's plain serializable args.
   */
  async swEval<R, A = void>(
    fn: (arg: A) => R | Promise<R>,
    arg?: A,
  ): Promise<R> {
    const run = (worker: Worker): Promise<R> =>
      (worker as unknown as SwEvaluate).evaluate(fn, arg as A);
    const worker = await this.sw();
    try {
      return await run(worker);
    } catch {
      return await run(await this.sw());
    }
  }
  /** Boots the embedded agent with the deterministic fake: provider. */
  async bootAgent(): Promise<void> {
    await this.swEval((config) => sw().faAgent.boot(config), {
      approvalMode: 'unattended',
    });
    await expect
      .poll(() => this.swEval(() => sw().faAgent.getState().booted))
      .toBe(true);
  }

  /** Installs the event collector the specs poll (faAgent.onEvent is one cb). */
  async collectEvents(): Promise<void> {
    await this.swEval(() => {
      const w = sw();
      w.__faEvents = [];
      w.faAgent.onEvent((event) => w.__faEvents?.push(event));
    });
  }

  events(): Promise<FaEvent[]> {
    return this.swEval(() => sw().__faEvents ?? []);
  }

  /** First matching agent event, polling until it lands. */
  async waitEvent(
    pred: (event: FaEvent) => boolean,
    timeout = 45_000,
  ): Promise<FaEvent> {
    let found: FaEvent | undefined;
    await expect
      .poll(async () => {
        found = (await this.events()).find(pred);
        return found ?? null;
      }, { timeout })
      .not.toBeNull();
    return found!;
  }

  sendUser(text: string): Promise<void> {
    return this.swEval((t) => sw().faAgent.sendUser(t), text);
  }

  decide(id: string, allow = true): Promise<void> {
    return this.swEval(
      (payload: [string, boolean]) =>
        sw().faAgent.decide(payload[0], payload[1]),
      [id, allow],
    );
  }

  /** One browser op through faSw.dispatch → {ok, result} | {ok:false, error}. */
  dispatch(
    op: string,
    args: Record<string, unknown> = {},
  ): Promise<FaEnvelope> {
    return this.swEval(
      (payload: [string, Record<string, unknown>]) =>
        sw().faSw.dispatch(payload[0], payload[1]),
      [op, args],
    );
  }

  /** The (single) fixture page the agent opened, once it exists. */
  async fixturePage(): Promise<Page> {
    const { promise, resolve } = Promise.withResolvers<Page>();
    const deadline = Date.now() + 20_000;
    while (Date.now() < deadline) {
      const page = this.context
        .pages()
        .find((p) => p.url().startsWith(this.fixture.url));
      if (page) {
        resolve(page);
        break;
      }
      await new Promise((r) => setTimeout(r, 250));
    }
    return promise;
  }
}

export const test = base.extend<{ fa: FaHarness }>({
  fa: [
    async ({}, use) => {
      const fa = await FaHarness.start();
      await use(fa);
      await fa.context.close();
      await fa.fixture.stop();
    },
    { timeout: 300_000 },
  ],
});

export { expect };
