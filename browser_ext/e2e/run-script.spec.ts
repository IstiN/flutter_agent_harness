// run_script end to end: the fake provider's scripted directive reaches the
// REAL offscreen-hosted interpreters (vendored quickjs + pyodide — extension
// CSP forbids remote scripts) through the agent loop, and the interpreter
// reply comes back as the tool result:
//   python     → CPython via pyodide (WASM boot on first call — slow);
//   javascript → quickjs-emscripten;
//   script-level errors → ok:false + the interpreter's error text (a RESULT,
//   not a tool failure).
import { expect } from './helpers';
import { FaHarness, skipWithoutChrome, test } from './helpers';

/** Runs one run_script directive and waits for its tool_result. */
async function runScript(
  fa: FaHarness,
  language: string,
  code: string,
): Promise<{ isError: boolean; text: string }> {
  const after = (await fa.eventCount()) - 1;
  await fa.sendUser(`run_script ${language} ${code}`);
  // The first python call boots pyodide (~10MB wasm + stdlib) — generous
  // timeout; the SW keep-alive inside waitEvent covers the idle-out trap.
  const result = await fa.waitEvent(
    (e) => e.type === 'tool_result' && e.toolName === 'run_script',
    120_000,
    after,
  );
  return { isError: result.isError === true, text: String(result.text ?? '') };
}

test.describe('run_script', () => {
  skipWithoutChrome();

  test('javascript runs in vendored quickjs and returns stdout', async ({
    fa,
  }) => {
    await fa.bootAgent('unattended');
    await fa.collectEvents();

    const result = await runScript(fa, 'javascript', 'console.log(6 * 7)');
    expect(result.isError, result.text).toBe(false);
    const parsed = JSON.parse(result.text) as {
      ok: boolean;
      stdout: string;
    };
    expect(parsed.ok).toBe(true);
    expect(parsed.stdout).toContain('42');
  });

  test('python runs in vendored pyodide and returns stdout', async ({
    fa,
  }) => {
    await fa.bootAgent('unattended');
    await fa.collectEvents();

    const result = await runScript(
      fa,
      'python',
      'import sys\nprint("py", sys.version_info[0])',
    );
    expect(result.isError, result.text).toBe(false);
    const parsed = JSON.parse(result.text) as {
      ok: boolean;
      stdout: string;
    };
    expect(parsed.ok).toBe(true);
    expect(parsed.stdout).toContain('py 3');
  });

  test('a script-level python error is a result, not a tool failure', async ({
    fa,
  }) => {
    await fa.bootAgent('unattended');
    await fa.collectEvents();

    const result = await runScript(fa, 'python', 'undefined_name');
    expect(result.isError, result.text).toBe(false);
    const parsed = JSON.parse(result.text) as {
      ok: boolean;
      error?: string;
    };
    expect(parsed.ok).toBe(false);
    expect(parsed.error ?? '').toContain('NameError');
  });

  test.describe('network (CORS-free via extension host permissions)', () => {
    let server: import('node:http').Server;
    let baseUrl = '';

    test.beforeAll(async () => {
      const http = await import('node:http');
      server = http.createServer((req, res) => {
        if (req.url === '/echo') {
          res.writeHead(200, { 'content-type': 'application/json' });
          res.end(JSON.stringify({ method: req.method, path: req.url }));
          return;
        }
        res.writeHead(404);
        res.end('nope');
      });
      await new Promise<void>((resolve) =>
        server.listen(0, '127.0.0.1', resolve),
      );
      const address = server.address();
      baseUrl = `http://127.0.0.1:${
        typeof address === 'object' && address ? address.port : 0
      }`;
    });

    test.afterAll(async () => {
      await new Promise((resolve) => server.close(resolve));
    });

    test('web_fetch tool is wired and CORS-free from the SW', async ({
      fa,
    }) => {
      await fa.bootAgent('unattended');
      await fa.collectEvents();

      const after = (await fa.eventCount()) - 1;
      await fa.sendUser(`tool web_fetch {"url": "${baseUrl}/echo"}`);
      const result = await fa.waitEvent(
        (e) => e.type === 'tool_result' && e.toolName === 'web_fetch',
        60_000,
        after,
      );
      expect(result.isError, String(result.text ?? '')).not.toBe(true);
      expect(String(result.text ?? '')).toContain('/echo');
    });

    test('javascript fetch reaches a local HTTP server', async ({ fa }) => {
      await fa.bootAgent('unattended');
      await fa.collectEvents();

      const result = await runScript(
        fa,
        'javascript',
        `const r = await fetch('${baseUrl}/echo');\n` +
          'console.log("status", r.status);\n' +
          'console.log("body", r.body);',
      );
      expect(result.isError, result.text).toBe(false);
      const parsed = JSON.parse(result.text) as {
        ok: boolean;
        stdout: string;
        error?: string;
      };
      expect(parsed.ok, parsed.error ?? '').toBe(true);
      expect(parsed.stdout).toContain('status 200');
      expect(parsed.stdout).toContain('/echo');
    });

    test('python fetch reaches a local HTTP server', async ({ fa }) => {
      await fa.bootAgent('unattended');
      await fa.collectEvents();

      const result = await runScript(
        fa,
        'python',
        `r = await fetch("${baseUrl}/echo")\n` +
          'print("status", r["status"])\n' +
          'print("body", r["body"])',
      );
      expect(result.isError, result.text).toBe(false);
      const parsed = JSON.parse(result.text) as {
        ok: boolean;
        stdout: string;
        error?: string;
      };
      expect(parsed.ok, parsed.error ?? '').toBe(true);
      expect(parsed.stdout).toContain('status 200');
      expect(parsed.stdout).toContain('/echo');
    });
  });
});
