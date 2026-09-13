// E2E-steer (issue #314): steering a RUNNING stream must be delivered at
// the next step boundary — never kill the stream ("request aborted").
// Drives the REAL compiled sw/agent.js in headless Chrome: a local
// OpenAI-compatible SSE server streams a reply slowly, the test steers
// mid-stream through the same sendUser seam the panel composer uses, and
// the run must finish: first reply completes naturally, the steering
// becomes the next user step, its reply follows — with NO aborted error
// anywhere on the event stream.
import http from 'node:http';
import { expect, FaHarness, skipWithoutChrome, test } from './helpers';

/** One slow OpenAI chat-completions SSE response: 8 deltas, 250ms apart. */
async function startSlowSseServer(): Promise<{
  server: http.Server;
  url: string;
}> {
  const server = http.createServer((req, res) => {
    if (req.method === 'POST' && req.url?.endsWith('/chat/completions')) {
      req.resume();
      res.writeHead(200, { 'content-type': 'text/event-stream' });
      let i = 0;
      const chunk = (delta: Record<string, unknown>, finish: string | null) =>
        `data: ${JSON.stringify({
          id: 'chatcmpl-slow',
          object: 'chat.completion.chunk',
          created: 1,
          model: 'slow',
          choices: [{ index: 0, delta, finish_reason: finish }],
        })}\n\n`;
      const timer = setInterval(() => {
        i++;
        res.write(chunk({ content: `d${i} ` }, null));
        if (i >= 8) {
          clearInterval(timer);
          res.write(chunk({}, 'stop'));
          res.write('data: [DONE]\n\n');
          res.end();
        }
      }, 250);
      res.on('close', () => clearInterval(timer));
      return;
    }
    res.writeHead(404);
    res.end();
  });
  const listening = Promise.withResolvers<void>();
  server.listen(0, '127.0.0.1', listening.resolve);
  await listening.promise;
  return {
    server,
    url: `http://127.0.0.1:${(server.address() as { port: number }).port}`,
  };
}

type FaEventRecord = { type: string; role?: string; text?: string; error?: unknown };

async function bootWith(fa: FaHarness, url: string): Promise<void> {
  await fa.swEval((cfg) => {
    const sw = globalThis as unknown as {
      faAgent: {
        boot(config: Record<string, unknown>): Promise<{ ok: boolean }>;
      };
    };
    return sw.faAgent.boot(cfg);
  }, {
    approvalMode: 'unattended',
    provider: { baseUrl: url, apiKey: 'k', model: 'slow' },
  });
}

function isUserDone(e: FaEventRecord, needle: string): boolean {
  return e.type === 'message_done' && e.role === 'user'
    && String(e.text).includes(needle);
}

async function waitForAssistantCount(
  fa: FaHarness,
  count: number,
  after: number,
): Promise<void> {
  await expect.poll(async () => {
    const events = await fa.events();
    return events
      .slice(after + 1)
      .filter((e) => (e as FaEventRecord).type === 'message_done'
        && (e as FaEventRecord).role === 'assistant').length;
  }, { timeout: 60_000 }).toBe(count);
}

async function expectNoAborts(fa: FaHarness, after: number): Promise<void> {
  const events = await fa.events();
  const aborted = events
    .slice(after + 1)
    .filter((e) => String((e as FaEventRecord).error ?? '')
      .toLowerCase()
      .includes('abort'));
  expect(aborted, `aborted surfaced: ${JSON.stringify(aborted)}`).toHaveLength(0);
}

async function closeServer(server: http.Server): Promise<void> {
  const closed = Promise.withResolvers<void>();
  server.close(() => closed.resolve());
  await closed.promise;
}

test.describe('steering a streaming run (#314)', () => {
  skipWithoutChrome();

  test('E2E-steer: composer steering mid-stream lands at the boundary, '
      + 'the run never surfaces an aborted error', async ({ fa }) => {
        const { server, url } = await startSlowSseServer();
        try {
          await bootWith(fa, url);
          await fa.collectEvents();
          const before = (await fa.eventCount()) - 1;

          await fa.sendUser('hello there');
          // The reply is streaming…
          await fa.waitEvent(
            (e) => e.type === 'delta' && String(e.text).includes('d1'),
            30_000,
            before,
          );
          // …steer through the same seam the panel composer rides while
          // the agent is running.
          await fa.sendUser('STEER-NOW please continue');

          // …the surface immediately gets the neutral steer_queued event.
          const queued = await fa.waitEvent(
            (e) => e.type === 'steer_queued' && String(e.text).includes('STEER-NOW'),
            10_000,
            before,
          );
          expect(queued).toBeTruthy();

          // The first reply runs to NATURAL completion — all 8 deltas, a
          // message_done with no error.
          const firstDone = await fa.waitEvent(
            (e) =>
              e.type === 'message_done' &&
              e.role === 'assistant' &&
              String(e.text).includes('d8'),
            30_000,
            before,
          );
          expect(
            firstDone.error,
            `first reply must not error: ${JSON.stringify(firstDone)}`,
          ).toBeUndefined();

          // The steering is delivered as the next step's user message…
          const steered = await fa.waitEvent(
            (e) =>
              e.type === 'message_done' &&
              e.role === 'user' &&
              String(e.text).includes('STEER-NOW'),
            30_000,
            before,
          );
          expect(steered).toBeTruthy();

          // …and its own reply follows (a second assistant message_done).
          const secondDone = await fa.waitEvent(
            (e) =>
              e.type === 'message_done' &&
              e.role === 'assistant',
            30_000,
            before + 1,
          );
          expect(secondDone).toBeTruthy();

          // NO aborted text anywhere on the surface.
          const events = await fa.events();
          const aborted = events
            .slice(before + 1)
            .filter((e) =>
              String((e as { error?: unknown }).error ?? '')
                .toLowerCase()
                .includes('abort'),
            );
          expect(
            aborted,
            `aborted surfaced: ${JSON.stringify(aborted)}`,
          ).toHaveLength(0);
        } finally {
          await new Promise<void>((r) => server.close(() => r()));
        }
      }, 120_000);
});

test.describe('steering edge semantics (#314)', () => {
  skipWithoutChrome();

  test('E2E-steer-multi: several steers during one stream queue in order '
      + 'and land one per boundary', async ({ fa }) => {
        const { server, url } = await startSlowSseServer();
        try {
          await bootWith(fa, url);
          await fa.collectEvents();
          const before = (await fa.eventCount()) - 1;

          await fa.sendUser('hello there');
          await fa.waitEvent(
            (e) => e.type === 'delta' && String(e.text).includes('d1'),
            30_000,
            before,
          );
          await fa.sendUser('STEER-ONE');
          await fa.sendUser('STEER-TWO');

          // Both steered messages land as user steps, in order…
          const first = await fa.waitEvent(
            (e) => isUserDone(e, 'STEER-ONE'),
            45_000,
            before,
          );
          const second = await fa.waitEvent(
            (e) => isUserDone(e, 'STEER-TWO'),
            45_000,
            before,
          );
          expect(first).toBeTruthy();
          expect(second).toBeTruthy();

          // …and every steered step got its own reply (3 assistants total).
          await waitForAssistantCount(fa, 3, before);
          await expectNoAborts(fa, before);
        } finally {
          await closeServer(server);
        }
      }, 180_000);

  test('E2E-steer-mail: bridge mail during a stream steers the run '
      + 'instead of aborting it', async ({ fa }) => {
        const { server, url } = await startSlowSseServer();
        try {
          await bootWith(fa, url);
          await fa.collectEvents();
          const before = (await fa.eventCount()) - 1;

          await fa.sendUser('hello there');
          await fa.waitEvent(
            (e) => e.type === 'delta' && String(e.text).includes('d1'),
            30_000,
            before,
          );
          await fa.swEval(() => {
            const sw = globalThis as unknown as {
              faAgent: {
                pushMail(from: string, text: string): void;
              };
            };
            sw.faAgent.pushMail('peer', 'mail steering mid-stream');
          });

          const steered = await fa.waitEvent(
            (e) => isUserDone(e, '[from peer] mail steering mid-stream'),
            45_000,
            before,
          );
          expect(steered).toBeTruthy();
          await expectNoAborts(fa, before);
        } finally {
          await closeServer(server);
        }
      }, 120_000);

  test('E2E-steer-indicator: the panel shows a neutral pending marker the '
      + 'moment a steer is queued, cleared when the message lands', async ({ fa }) => {
        const { server, url } = await startSlowSseServer();
        try {
          await bootWith(fa, url);
          // Drive the REAL composer UI: no collectEvents here, so the
          // sw/main.js panel fan-out listener stays armed.
          await fa.panel.fill('#prompt', 'hello there');
          await fa.panel.click('#sendPrompt');
          await fa.panel
            .waitForSelector('.bubble.assistant', { timeout: 30_000 });

          await fa.panel.fill('#prompt', 'STEER-VIA-PANEL');
          await fa.panel.click('#sendPrompt');
          const marker = await fa.panel.waitForSelector('.bubble.steer', {
            timeout: 10_000,
          });
          expect(marker).toBeTruthy();

          // The steered message lands at the boundary: its user bubble…
          await fa.panel.waitForFunction(
            () => [...document.querySelectorAll('.bubble.user')]
              .some((b) => b.textContent?.includes('STEER-VIA-PANEL')),
            { timeout: 45_000 },
          );
          // …consumes the marker…
          await expect
            .poll(() => fa.panel.$$('.bubble.steer').then((r) => r.length))
            .toBe(0);
          // …and no aborted error ever hit the panel log.
          const logText = await fa.panel.evaluate(
            () => document.querySelector('#log')?.textContent ?? '',
          );
          expect(logText.toLowerCase()).not.toContain('abort');
        } finally {
          await closeServer(server);
        }
      }, 120_000);
});
