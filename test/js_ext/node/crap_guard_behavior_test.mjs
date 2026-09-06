// Behavior tests for the bundled crap-guard extension's main.js, run by
// test/js_ext/bundled_crap_guard_node_test.dart, which runs
// `node --test test/js_ext/node/` when node is on PATH and skips when not.
//
// The jsr.ext.* surface is mocked here: hooks captured, session notes and
// follow-ups captured, fs.readFile served from a fixture map, exec.run
// scripted. Date.now is monkey-patched so the debounce window is
// deterministic. main.js is loaded fresh per test via (0, eval) — its state
// lives in the IIFE closure, so every load starts clean.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

// --- main.js extraction from the Dart const raw string ---------------------

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '../../..');
const dartSrc = readFileSync(
  join(repoRoot, 'lib/src/js_ext/bundled/crap_guard.dart'),
  'utf8',
);
const openMarker = "const String kCrapGuardMainJs = r'''";
const start = dartSrc.indexOf(openMarker);
assert(start >= 0, 'kCrapGuardMainJs marker not found in crap_guard.dart');
const bodyStart = start + openMarker.length;
const mainJs = dartSrc.slice(bodyStart, dartSrc.indexOf("'''", bodyStart));

// --- mock jsr.ext surface ----------------------------------------------------

function makeExt({ files = {}, exec } = {}) {
  const hooks = {};
  const notes = [];
  const followUps = [];
  const execCalls = [];
  const reads = [];
  const registered = { tools: 0, slash: 0, flows: 0 };
  const ext = {
    onHook: (event, fn) => {
      hooks[event] = fn;
      return 1;
    },
    registerTool: () => {
      registered.tools += 1;
      return 1;
    },
    registerSlashCommand: () => {
      registered.slash += 1;
      return 1;
    },
    menus: {
      registerProviderFlow: () => {
        registered.flows += 1;
        return 1;
      },
    },
    session: {
      appendNote: (text) => {
        notes.push(String(text));
        return Promise.resolve(null);
      },
      enqueueFollowUp: (text) => {
        followUps.push(String(text));
        return Promise.resolve(null);
      },
    },
    fs: {
      readFile: (p) => {
        reads.push(p);
        return p in files
          ? Promise.resolve(files[p])
          : Promise.reject(new Error('fs.readFile failed: ' + p));
      },
    },
    exec: {
      run: (opts) => {
        execCalls.push(opts);
        return exec
          ? exec(opts)
          : Promise.resolve({ exitCode: 0, stdout: '', stderr: '', timedOut: false });
      },
    },
    keys: { request: (name) => Promise.resolve({ granted: false, name }) },
    io: {
      write: () => Promise.resolve(null),
      writeln: () => Promise.resolve(null),
    },
    has: () => Promise.resolve(true),
  };
  return { ext, hooks, notes, followUps, execCalls, reads, registered };
}

function loadGuard(jsrExt) {
  globalThis.jsr = { ext: jsrExt };
  (0, eval)(mainJs);
}

/** Runs `fn(setClock)` with Date.now monkey-patched; restores afterwards. */
async function withClock(fn) {
  const real = Date.now;
  let now = 0;
  Date.now = () => now;
  try {
    await fn((t) => {
      now = t;
    });
  } finally {
    Date.now = real;
  }
}

const edit = (hooks, path, { tool = 'write', isError = false } = {}) =>
  hooks.afterToolCall({ tool, args: { path, content: '' }, result: 'ok', isError });

const dartLines = (n) =>
  Array.from({ length: n }, (_, i) => `// line ${i + 1}`).join('\n');

/** A realistic `crap4dart analyze` console report (see crap_report.dart). */
function crapOut(rows, threshold = 12.0) {
  return [
    'CRAP  COV%  BR%  CC  METHOD            FILE:LINE',
    '-'.repeat(66),
    ...rows,
    '',
    `Max CRAP: ${threshold.toFixed(2)} — FAIL (threshold: ${threshold.toFixed(2)})`,
    '',
  ].join('\n');
}

const ok = (stdout) => ({ exitCode: 0, stdout, stderr: '', timedOut: false });
const offenderRow = '15.50  0.0  N/A  4  Foo.bar  lib/foo.dart:10';
const naRow = 'N/A  N/A  N/A  45  X.y  lib/other.dart:5';
const MISSING_MSG =
  'crap-guard: crap4dart not activated — activate: dart pub global activate crap4dart 0.2.1 (checks idle until then)';

// --- tests -------------------------------------------------------------------

test('registers exactly the two hooks and nothing else', () => {
  const m = makeExt();
  loadGuard(m.ext);
  assert.deepEqual(Object.keys(m.hooks).sort(), ['afterToolCall', 'onSessionEnd']);
  assert.equal(m.registered.tools, 0);
  assert.equal(m.registered.slash, 0);
  assert.equal(m.registered.flows, 0);
});

test('skips non-write/edit tools, errors, and excluded paths', async () => {
  const m = makeExt();
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    await edit(m.hooks, 'lib/a.dart', { tool: 'bash' });
    await edit(m.hooks, 'lib/a.dart', { isError: true });
    await edit(m.hooks, 'lib/a.g.dart');
    await edit(m.hooks, 'lib/b.freezed.dart');
    await edit(m.hooks, 'vendor/v.dart');
    await edit(m.hooks, 'nested/vendor/v.dart');
    await edit(m.hooks, 'build/b.dart');
    await edit(m.hooks, 'x/build/b.dart');
    await edit(m.hooks, 'lib/notes.md');
    await edit(m.hooks, 'lib/noargs.txt'); // args.path missing is covered below
    const noPath = m.hooks.afterToolCall({
      tool: 'write',
      args: { content: 'x' },
      result: 'ok',
      isError: false,
    });
    assert.equal(noPath, undefined);
    assert.equal(m.execCalls.length, 0);
    assert.equal(m.reads.length, 0);

    // One guarded edit fires the check.
    await edit(m.hooks, 'lib/ok.dart');
    assert.equal(m.execCalls.length, 1);
  });
});

test('over-2800-lines file produces the split-the-file append', async () => {
  const m = makeExt({ files: { 'lib/big.dart': dartLines(2801) } });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const res = await edit(m.hooks, 'lib/big.dart');
    assert.equal(
      res.append,
      '1 files over threshold: lib/big.dart: 2801 lines (max 2800) — split the file',
    );
  });
});

test('CRAP offender row produces the regression append (fallback threshold 12)', async () => {
  // No crap4dart.yaml in the fixture map => readFile rejects => 12.0 fallback.
  const m = makeExt({
    files: { 'lib/foo.dart': 'void f() {}\n' },
    exec: () => Promise.resolve(ok(crapOut([offenderRow]))),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const res = await edit(m.hooks, 'lib/foo.dart');
    assert.equal(
      res.append,
      '1 files over threshold: CRAP regression in Foo.bar: score 15.50 (max 12) — simplify or add tests',
    );
  });
});

test('threshold is read from the crap4dart.yaml fixture', async () => {
  const m = makeExt({
    files: {
      'lib/foo.dart': 'void f() {}\n',
      'crap4dart.yaml': 'sources: [lib, bin]\ncrap:\n  threshold: 20.0\n',
    },
    exec: () => Promise.resolve(ok(crapOut([offenderRow]))),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const res = await edit(m.hooks, 'lib/foo.dart'); // 15.50 <= 20 => clean
    assert.equal(res, undefined);
  });
});

test('absolute edited paths still match relative analyze rows', async () => {
  const m = makeExt({
    files: { 'lib/foo.dart': 'void f() {}\n' },
    exec: () => Promise.resolve(ok(crapOut([offenderRow]))),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const res = await edit(m.hooks, '/work/repo/lib/foo.dart');
    assert.match(res.append, /CRAP regression in Foo\.bar/);
  });
});

test('debounce collapses an edit burst into one aggregated check', async () => {
  const m = makeExt({
    files: {
      'lib/a.dart': dartLines(2801),
      'lib/b.dart': 'void b() {}\n',
      'lib/c.dart': 'void c() {}\n',
      'lib/d.dart': 'void d() {}\n',
    },
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(1000);
    assert.equal(await edit(m.hooks, 'lib/a.dart'), undefined); // within first window
    clock(1500);
    assert.equal(await edit(m.hooks, 'lib/b.dart'), undefined); // still accumulating
    assert.equal(m.execCalls.length, 0);

    clock(3000);
    const res = await edit(m.hooks, 'lib/c.dart'); // window closed: check a+b+c
    assert.equal(m.execCalls.length, 1);
    assert.equal(
      res.append,
      '1 files over threshold: lib/a.dart: 2801 lines (max 2800) — split the file',
    );
    assert.ok(m.reads.includes('crap4dart.yaml'));
    for (const p of ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']) {
      assert.ok(m.reads.includes(p), `expected readFile(${p})`);
    }

    clock(3001);
    assert.equal(await edit(m.hooks, 'lib/d.dart'), undefined); // new window
    assert.equal(m.execCalls.length, 1); // no second check inside the window
  });
});

test('exec.run is invoked as dart pub global run crap4dart analyze (180s)', async () => {
  const m = makeExt({ files: { 'lib/foo.dart': 'void f() {}\n' } });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    await edit(m.hooks, 'lib/foo.dart');
    assert.deepEqual(m.execCalls[0], {
      command: 'dart',
      args: ['pub', 'global', 'run', 'crap4dart', 'analyze'],
      timeoutMs: 180000,
    });
  });
});

test('missing tool: one append note (E17), then silent — also at sessionEnd', async () => {
  const m = makeExt({
    files: { 'lib/foo.dart': 'void f() {}\n' },
    exec: () =>
      Promise.resolve({ exitCode: 127, stdout: '', stderr: 'sh: dart: command not found' }),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const first = await edit(m.hooks, 'lib/foo.dart');
    assert.equal(first.append, MISSING_MSG);
    clock(10000 + 2001);
    const second = await edit(m.hooks, 'lib/foo.dart');
    assert.equal(second, undefined); // E17: silent after the first note

    await m.hooks.onSessionEnd({});
    assert.deepEqual(m.notes, []); // already noted via afterToolCall — idle
  });
});

test('sessionEnd missing-tool note fires once when never noted before', async () => {
  let call = 0;
  const m = makeExt({
    files: { 'lib/foo.dart': 'void f() {}\n' },
    exec: () =>
      ++call === 1
        ? Promise.resolve(ok(crapOut([])))
        : Promise.resolve({ exitCode: 127, stdout: '', stderr: 'dart: not found' }),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    await edit(m.hooks, 'lib/foo.dart'); // clean check
    await m.hooks.onSessionEnd({});
    assert.deepEqual(m.notes, [MISSING_MSG]);
    await m.hooks.onSessionEnd({});
    assert.deepEqual(m.notes, [MISSING_MSG]); // still one — idle afterwards
  });
});

test('sessionEnd reports offenders via note + follow-up', async () => {
  let call = 0;
  const m = makeExt({
    files: { 'lib/foo.dart': 'void f() {}\n' },
    exec: () =>
      Promise.resolve(
        ok(
          crapOut(
            ++call === 1
              ? []
              : [offenderRow, '99.00  0.0  N/A  10  Baz.qux  lib/foo.dart:20'],
          ),
        ),
      ),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    await edit(m.hooks, 'lib/foo.dart');
    await m.hooks.onSessionEnd({});
    assert.deepEqual(m.notes, [
      'crap-guard session report:\n' +
        'CRAP regression in Foo.bar: score 15.50 (max 12) — simplify or add tests\n' +
        'CRAP regression in Baz.qux: score 99.00 (max 12) — simplify or add tests',
    ]);
    assert.deepEqual(m.followUps, [
      'CRAP regressions: Foo.bar, Baz.qux — fix before next session',
    ]);
  });
});

test('no guarded edits => sessionEnd is a no-op (no analyze run)', async () => {
  const m = makeExt({ exec: () => Promise.resolve(ok(crapOut([offenderRow]))) });
  loadGuard(m.ext);
  await withClock(async () => {
    await m.hooks.onSessionEnd({});
    assert.equal(m.execCalls.length, 0);
    assert.deepEqual(m.notes, []);
    assert.deepEqual(m.followUps, []);
  });
});

test('coverage-stale complexity-only note appears once per session', async () => {
  const m = makeExt({
    files: { 'lib/x.dart': 'void x() {}\n' },
    exec: () =>
      Promise.resolve(ok(crapOut(['15.50  0.0  N/A  4  Foo.bar  lib/x.dart:10', naRow]))),
  });
  loadGuard(m.ext);
  await withClock(async (clock) => {
    clock(10000);
    const first = await edit(m.hooks, 'lib/x.dart');
    assert.match(first.append, /CRAP regression in Foo\.bar/);
    assert.match(first.append, /\(complexity-only: coverage stale\)$/);

    clock(10000 + 2001);
    const second = await edit(m.hooks, 'lib/x.dart');
    assert.match(second.append, /CRAP regression in Foo\.bar/);
    assert.doesNotMatch(second.append, /coverage stale/); // noted once
  });
});
