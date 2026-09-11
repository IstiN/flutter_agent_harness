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
});
