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

  static async start(): Promise<HubProc> {
    const proc = spawn('dart', ['run', 'browser_ext/e2e/hub_server.dart'], {
      cwd: repoRoot,
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

  static start(home: string, mockPort: number): CliProc {
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
          DAP_MASTER_SECRET: 'e2e-dap-secret',
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
    // 1. Boot the extension agent onto the hub (fake provider — no LLM;
    //    dap config persists + connects via the boot path).
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
    const extAgentId = await fa.swEval(() => {
      const sw = globalThis as unknown as {
        faAgent: { getState(): { hub?: { agentId?: string } } };
      };
      return sw.faAgent.getState().hub?.agentId ?? '';
    });
    expect(extAgentId).toMatch(/^[0-9a-f]{16}$/);
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
      // The hub handshake needs a moment before the prompt's tool call can
      // send; the mock's first response only lands after a full boot anyway.
      await new Promise((r) => setTimeout(r, 5_000));
      cli.prompt('dm the extension agent');

      // 3. The hub routed CLI → ext …
      await expect
        .poll(
          () => hub.agentIds().find((id) => id !== extAgentId) ?? null,
          { timeout: 60_000 },
        )
        .not.toBeNull();
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
      //    against the mock, printing the marker.
      await expect
        .poll(() => cli.output(), { timeout: 120_000, intervals: [1_000] })
        .toContain('mock: cli done');
      expect(hub.relayTargets()).toContain(otherId);
    } finally {
      await cli.stop();
      fs.rmSync(home, { recursive: true, force: true });
    }
  });
});
