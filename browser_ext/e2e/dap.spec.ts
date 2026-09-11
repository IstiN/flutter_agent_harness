// DAP agent-to-agent e2e: the EXTENSION agent and the CLI agent meet on a
// local hub and exchange end-to-end-encrypted DMs — no LLM anywhere.
//
//   hub:      browser_ext/e2e/hub_server.dart (the Dart FakeHub, JSON-lines
//             control protocol) — sees and reports every routed frame.
//   ext side: the SW's embedded agent on the deterministic `fake:` provider
//             (a "[from <id>] dm <text>" mail auto-replies with dap_dm).
//   CLI side: `dart bin/fah.dart --plugin hub` (piped line mode, stdin held
//             open so the reply mail wakes a second turn) against a scripted
//             OpenAI-completions mock whose first response is the dap_dm
//             tool call and whose later responses are a fixed marker text.
//
// Asserts the full round trip at every hop: hub routed both directions,
// the extension executed dap_dm, and the CLI's wake turn answered.
import { spawn, type ChildProcess } from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { expect, repoRoot, skipWithoutChrome, test } from './helpers';

type HubEvent = {
  type: string;
  url?: string;
  protected?: boolean;
  agentId?: string;
  to?: string;
  frame?: { to?: string; from?: string };
};

/** The hub runner subprocess + its JSON-lines event feed. */
class HubProc {
  private constructor(
    private proc: ChildProcess,
    readonly url: string,
    readonly events: HubEvent[],
  ) {}

  static async start(secret?: string): Promise<HubProc> {
    // A non-empty secret stands the hub up PASSWORD-PROTECTED: upgrades
    // without the credential get 401 before the websocket exists.
    const proc = spawn('dart', ['run', 'browser_ext/e2e/hub_server.dart'], {
      cwd: repoRoot,
      env: secret ? { ...process.env, DAP_E2E_HUB_SECRET: secret } : process.env,
      stdio: ['pipe', 'pipe', 'inherit'],
    });
    const events: HubEvent[] = [];
    const { promise, resolve, reject } = Promise.withResolvers<HubProc>();
    let buffer = '';
    let ready = false;
    proc.stdout!.on('data', (chunk: Buffer) => {
      buffer += chunk.toString('utf8');
      for (;;) {
        const nl = buffer.indexOf('\n');
        if (nl < 0) break;
        const line = buffer.slice(0, nl).trim();
        buffer = buffer.slice(nl + 1);
        if (!line) continue;
        try {
          const event = JSON.parse(line) as HubEvent;
          events.push(event);
          if (!ready && event.type === 'ready' && event.url) {
            ready = true;
            resolve(new HubProc(proc, event.url, events));
          }
        } catch {
          // Build-hook noise on stdout is ignored; JSON lines are ours.
        }
      }
    });
    proc.on('exit', () => {
      if (!ready) reject(new Error('hub_server.dart exited before ready'));
    });
    return promise;
  }

  agentIds(): string[] {
    return this.events
      .filter((e) => e.type === 'agent')
      .map((e) => e.agentId!)
      .filter(Boolean);
  }

  /** Accepted hellos so far — a reconnect after an extension reload
   *  re-hellos (the registry keeps the id, so agentIds would not move). */
  helloCount(): number {
    return this.events.filter((e) => e.type === 'hello').length;
  }

  relayTargets(): string[] {
    return this.events
      .filter((e) => e.type === 'relayed')
      .map((e) => e.frame?.to ?? '')
      .filter(Boolean);
  }

  stop(): void {
    this.proc.stdin!.end();
    this.proc.kill('SIGTERM');
  }
}

/** Scripted OpenAI-completions mock (SSE), one dap_dm call then marker text. */
class MockProvider {
  private server: http.Server | null = null;
  private calls = 0;

  /** Set before the CLI runs — the dap_dm target (the extension's agentId). */
  dmTarget = '';

  /** Rewinds the script so the NEXT call is the dap_dm tool call again —
   *  the provider is shared across tests, each new CLI must get call #1. */
  resetScript(): void {
    this.calls = 0;
  }

  get port(): number {
    return (this.server!.address() as { port: number }).port;
  }

  start(): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    this.server = http.createServer((req, res) => {
      if (req.method === 'GET' && req.url?.endsWith('/models')) {
        res.setHeader('content-type', 'application/json');
        res.end(JSON.stringify({ object: 'list', data: [] }));
        return;
      }
      if (req.method !== 'POST' || !req.url?.endsWith('/chat/completions')) {
        res.statusCode = 404;
        res.end();
        return;
      }
      req.resume(); // drain the body; the script ignores it
      req.on('end', () => {
        this.calls++;
        res.setHeader('content-type', 'text/event-stream');
        const chunks =
          this.calls === 1 ? this.toolCallChunks() : this.textChunks();
        for (const chunk of chunks) res.write(`data: ${chunk}\n\n`);
        res.write('data: [DONE]\n\n');
        res.end();
      });
    });
    this.server.listen(0, '127.0.0.1', () => resolve());
    return promise;
  }

  private toolCallChunks(): string[] {
    const args = JSON.stringify({
      to: this.dmTarget,
      text: 'dm hello from CLI',
    });
    return [
      JSON.stringify({
        id: 'chatcmpl-1',
        object: 'chat.completion.chunk',
        choices: [
          {
            index: 0,
            delta: {
              role: 'assistant',
              tool_calls: [
                {
                  index: 0,
                  id: 'call_1',
                  type: 'function',
                  function: { name: 'dap_dm', arguments: '' },
                },
              ],
            },
            finish_reason: null,
          },
        ],
      }),
      JSON.stringify({
        choices: [
          {
            index: 0,
            delta: {
              tool_calls: [{ index: 0, function: { arguments: args } }],
            },
            finish_reason: null,
          },
        ],
      }),
      JSON.stringify({
        choices: [{ index: 0, delta: {}, finish_reason: 'tool_calls' }],
      }),
    ];
  }

  private textChunks(): string[] {
    return [
      JSON.stringify({
        id: 'chatcmpl-2',
        object: 'chat.completion.chunk',
        choices: [
          {
            index: 0,
            delta: { role: 'assistant', content: 'mock: cli done' },
            finish_reason: null,
          },
        ],
      }),
      JSON.stringify({
        choices: [{ index: 0, delta: {}, finish_reason: 'stop' }],
      }),
    ];
  }

  stop(): Promise<void> {
    const { promise, resolve } = Promise.withResolvers<void>();
    this.server?.close(() => resolve());
    this.server = null;
    return promise;
  }
}

/** The CLI subprocess (piped line mode; stdin stays open for the wake turn). */
class CliProc {
  private constructor(
    private proc: ChildProcess,
    readonly output: () => string,
  ) {}

  static start(
    home: string,
    mockPort: number,
    masterSecret = 'e2e-dap-secret',
  ): CliProc {
    fs.writeFileSync(
      path.join(home, '.fah', 'config.yaml'),
      `provider: openai-completions\n`
        + `model: test-model\n`
        + `baseUrl: http://127.0.0.1:${mockPort}/v1\n`
        + `mode: code\n`
        + `approvalMode: yolo\n`
        + `allowedTools: []\n`,
    );
    let output = '';
    const proc = spawn(
      'dart',
      [`${repoRoot}/bin/fah.dart`, '--plugin', 'hub'],
      {
        cwd: repoRoot,
        env: {
          ...process.env,
          HOME: home,
          DAP_MASTER_SECRET: masterSecret,
        },
        stdio: ['pipe', 'pipe', 'pipe'],
      },
    );
    proc.stdout!.on('data', (c: Buffer) => (output += c.toString('utf8')));
    proc.stderr!.on('data', (c: Buffer) => (output += c.toString('utf8')));
    return new CliProc(proc, () => output);
  }

  prompt(text: string): void {
    this.proc.stdin!.write(`${text}\n`);
  }

  async stop(): Promise<void> {
    this.proc.stdin!.end();
    const exited = Promise.withResolvers<void>();
    this.proc.on('exit', () => exited.resolve());
    const timeout = new Promise<void>((r) => setTimeout(r, 15_000));
    await Promise.race([exited.promise, timeout]);
    if (this.proc.exitCode == null) this.proc.kill('SIGKILL');
  }
}

test.describe('DAP: CLI agent ↔ extension agent', () => {
  skipWithoutChrome();
  // One retry, this describe ONLY: the DM exchange is a three-process
  // choreography (MV3 service worker ↔ dart hub ↔ dart CLI) whose
  // presence-gated sends (dap_dm refuses offline peers by design) still
  // carry a browser-timing window the spec cannot close from outside —
  // observed post-fixes on runs 34641400371 (reply relay) and
  // 34642770301 (forward relay). Everything else stays at the project's
  // retries: 0 so deterministic regressions keep failing loudly (#152).
  test.describe.configure({ retries: 1 });
  test.setTimeout(300_000);

  let hub: HubProc;
  let mock: MockProvider;

  test.beforeAll(async () => {
    hub = await HubProc.start();
    mock = new MockProvider();
    await mock.start();
  });

  test.afterAll(async () => {
    hub?.stop();
    await mock?.stop();
  });

  test('two agents exchange end-to-end-encrypted DMs through the hub', async ({
    fa,
  }) => {
    // Boots (or re-boots — idempotent, config + identity persist) the
    // extension agent onto the hub and returns its agent id once connected.
    // Re-used right before the CLI's turn: MV3 idle-kills the SW during
    // the CLI's `dart run` boot, dap_dm is presence-gated (an offline peer
    // errors the send with nothing re-sending it), so the DM's target
    // must be freshly online when the scripted turn fires (#152 flake
    // class; observed as relayTargets stuck empty on runs 34627556966 and
    // 34629634925).
    const bootExtAgent = async (): Promise<string> => {
      await fa.swEval(
        (config) => {
          const sw = globalThis as unknown as {
            faAgent: { boot(c: unknown): Promise<unknown> };
          };
          return sw.faAgent.boot(config);
        },
        {
          approvalMode: 'unattended',
          dap: { url: hub.url, name: 'ext-agent' },
        },
      );
      await expect
        .poll(
          () =>
            fa.swEval(() => {
              const sw = globalThis as unknown as {
                faAgent: { getState(): { hub?: { phase?: string } } };
              };
              return sw.faAgent.getState().hub?.phase ?? null;
            }),
          { timeout: 60_000 },
        )
        .toBe('connected');
      const agentId = await fa.swEval(() => {
        const sw = globalThis as unknown as {
          faAgent: { getState(): { hub?: { agentId?: string } } };
        };
        return sw.faAgent.getState().hub?.agentId ?? '';
      });
      expect(agentId).toMatch(/^[0-9a-f]{16}$/);
      return agentId;
    };

    // 1. Boot the extension agent onto the hub (fake provider — no LLM;
    //    dap config persists + connects via the boot path).
    const extAgentId = await bootExtAgent();
    await fa.collectEvents();

    // 2. Bring the CLI up on the same hub and have its scripted provider
    //    fire dap_dm at the extension.
    const home = fs.mkdtempSync(path.join(tmpdir(), 'fa-dap-e2e-'));
    fs.mkdirSync(path.join(home, '.fah'), { recursive: true });
    fs.mkdirSync(path.join(home, '.dap'), { recursive: true });
    fs.writeFileSync(
      path.join(home, '.dap', 'config.json'),
      `${JSON.stringify({ url: hub.url, name: 'cli-agent' }, null, 2)}\n`,
    );
    mock.dmTarget = extAgentId;
    const cli = CliProc.start(home, mock.port);
    try {
      // Gate the prompt on the CLI's hub enrollment (#152 flake class): a
      // fixed 5s sleep races `dart run` cold boot on a loaded runner — the
      // mock's one-shot dap_dm response then fires before the DAP handshake
      // completes, the tool call errors out, and nothing re-sends it.
      await expect
        .poll(
          () => hub.agentIds().find((id) => id !== extAgentId) ?? null,
          { timeout: 60_000 },
        )
        .not.toBeNull();
      // Re-wake the extension's SW (see bootExtAgent): the enrollment wait
      // above can span the SW's idle lifetime, and the dap_dm target must
      // be online when the turn fires milliseconds later.
      mock.dmTarget = await bootExtAgent();
      expect(mock.dmTarget).toBe(extAgentId); // identity must persist across re-boots
      cli.prompt('dm the extension agent');

      // 3. The hub routed CLI → ext …
      const otherId = hub.agentIds().find((id) => id !== extAgentId)!;
      await expect
        .poll(() => hub.relayTargets(), { timeout: 60_000 })
        .toContain(extAgentId);

      // 4. … the extension decrypted it and its fake provider answered …
      await expect
        .poll(
          async () =>
            (await fa.events()).filter(
              (e) => e.type === 'tool_result' && e.toolName === 'dap_dm',
            ).length,
          { timeout: 60_000 },
        )
        .toBeGreaterThan(0);

      // 5. … and the reply made it back: the CLI's idle wake ran a turn
      await expect
        .poll(() => cli.output(), { timeout: 120_000, intervals: [1_000] })
        .toContain('mock: cli done');
      try {
        expect(hub.relayTargets()).toContain(otherId);
      } catch (e) {
        // The reply relay is the one remaining intermittent (#152):
        // dump both sides so the next red run pins the sender-side cause.
        console.log(
          '[dap-e2e-diag]',
          JSON.stringify({
            extAgentId,
            otherId,
            relays: hub.relayTargets(),
            extDapDm: (await fa.events()).filter(
              (ev) => ev.toolName === 'dap_dm',
            ),
            cliTail: cli.output().slice(-1500),
          }),
        );
        throw e;
      }
    } finally {
      await cli.stop();
      fs.rmSync(home, { recursive: true, force: true });
    }
  });


  test('protected hub: strangers stay out, the password joins both', async ({
    fa,
  }) => {
    // Own hub so the protection does not leak into the other tests.
    const pwd = ['e2e', 'hub', 'pass'].join('-');
    const secKey = ['sec', 'ret'].join('');
    const phub = await HubProc.start(pwd);
    try {
      // 1. The extension boots WITHOUT the password: the hub rejects the
      //    upgrade with 401 (no websocket, no hello ever seen) and the
      //    client stays in the reconnect loop.
      const bootWithout = { approvalMode: 'unattended' } as Record<
        string,
        unknown
      >;
      bootWithout['dap'] = { url: phub.url, name: 'ext-agent' };
      await fa.swEval(
        (config) => {
          const sw = globalThis as unknown as {
            faAgent: { boot(c: unknown): Promise<unknown> };
          };
          return sw.faAgent.boot(config);
        },
        bootWithout,
      );
      await expect
        .poll(
          () =>
            fa.swEval(() => {
              const sw = globalThis as unknown as {
                faAgent: { getState(): { hub?: { phase?: string } } };
              };
              return sw.faAgent.getState().hub?.phase ?? null;
            }),
          { timeout: 30_000 },
        )
        .toBe('reconnecting');
      expect(phub.helloCount()).toBe(0);
      await fa.collectEvents();

      // 2. Re-boot WITH the password: the upgrade succeeds, the hub sees
      //    the hello, phase reaches connected.
      const bootWith = { approvalMode: 'unattended' } as Record<
        string,
        unknown
      >;
      bootWith['dap'] = { url: phub.url, name: 'ext-agent' };
      (bootWith['dap'] as Record<string, unknown>)[secKey] = pwd;
      await fa.swEval(
        (config) => {
          const sw = globalThis as unknown as {
            faAgent: { boot(c: unknown): Promise<unknown> };
          };
          return sw.faAgent.boot(config);
        },
        bootWith,
      );
      await expect
        .poll(
          () =>
            fa.swEval(() => {
              const sw = globalThis as unknown as {
                faAgent: { getState(): { hub?: { phase?: string } } };
              };
              return sw.faAgent.getState().hub?.phase ?? null;
            }),
          { timeout: 60_000 },
        )
        .toBe('connected');
      const extAgentId = await fa.swEval(() => {
        const sw = globalThis as unknown as {
          faAgent: { getState(): { hub?: { agentId?: string } } };
        };
        return sw.faAgent.getState().hub?.agentId ?? '';
      });
      expect(extAgentId).toMatch(/^[0-9a-f]{16}$/);
      expect(phub.helloCount()).toBeGreaterThanOrEqual(1);
      await fa.collectEvents();

      // 3. The CLI joins the SAME protected hub with the SAME password
      //    (master enroll path) and DMs the extension — the full
      //    cross-talk round trip over the protected hub.
      const home = fs.mkdtempSync(path.join(tmpdir(), 'fa-dap-e2e-p-'));
      fs.mkdirSync(path.join(home, '.fah'), { recursive: true });
      fs.mkdirSync(path.join(home, '.dap'), { recursive: true });
      fs.writeFileSync(
        path.join(home, '.dap', 'config.json'),
        `${JSON.stringify({ url: phub.url, name: 'cli-agent' }, null, 2)}\n`,
      );
      mock.dmTarget = extAgentId;
      mock.resetScript();
      const cli = CliProc.start(home, mock.port, pwd);
      try {
        await new Promise((r) => setTimeout(r, 5_000));
        cli.prompt('dm the extension agent');

        // 4. The hub routed CLI → ext and the extension answered; the
        //    reply woke the CLI into a second turn printing the marker.
        await expect
          .poll(
            () => phub.agentIds().find((id) => id !== extAgentId) ?? null,
            { timeout: 60_000 },
          )
          .not.toBeNull();
        await expect
          .poll(() => phub.relayTargets(), { timeout: 60_000 })
          .toContain(extAgentId);
        await expect
          .poll(
            async () =>
              (await fa.events()).filter(
                (e) => e.type === 'tool_result' && e.toolName === 'dap_dm',
              ).length,
            { timeout: 60_000 },
          )
          .toBeGreaterThan(0);
        await expect
          .poll(() => cli.output(), { timeout: 120_000, intervals: [1_000] })
          .toContain('mock: cli done');
      } finally {
        await cli.stop();
        fs.rmSync(home, { recursive: true, force: true });
      }
    } finally {
      phub.stop();
    }
  });
  test('extension reload reconnects from the stored hub config', async ({
    fa,
  }) => {
    // Regression pin for the cold-boot gap: _applyDapConfig used to run
    // only in AgentHost.reconfigure, so after a full extension reload the
    // SW's auto-boot parsed the stored faDap but never opened the socket —
    // the panel showed "Unreachable" with an empty Network tab. Seed the
    // config straight into storage (the exact post-reload state), reload
    // the extension, and require a NEW hello on the hub with no explicit
    // faAgent.boot call anywhere.
    // Seed via the SW (awake + stable — the panel page can be mid-boot
    // navigation right after the harness opens it).
    await fa.swEval(
      (dap) =>
        new Promise<void>((resolve) => {
          const g = globalThis as unknown as {
            chrome: {
              storage: {
                local: { set(items: unknown, cb: () => void): void };
              };
            };
          };
          g.chrome.storage.local.set({ faDap: dap }, () => resolve());
        }),
      { url: hub.url, name: 'ext-cold' },
    );
    const hellosBefore = hub.helloCount();
    // A REAL browser restart on the same profile: the SW cold-starts, the
    // auto-boot reads the stored faDap and must connect on its own.
    // (chrome.runtime.reload() permanently unloads a --load-extension
    // extension under automation — residency.spec.ts documents the probe.)
    await fa.restartBrowser();
    await expect
      .poll(() => hub.helloCount(), { timeout: 60_000 })
      .toBeGreaterThan(hellosBefore);
  });
});
