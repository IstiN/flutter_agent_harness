// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// gh-1393 WS-1 AC1 — the POSIX conformance oracle: ONE table of commands
// runs through LocalShell (real `sh -c`, the reference), the web
// MemoryShell and the WasiSandboxShell, asserting identical stdout and
// exit code. Every gh-1393 field defect is a row (glob expansion,
// grep semantics via the MemoryShell's Dart grep, per-exec-cwd cd,
// /dev/null + 2>&1). This suite is the merge gate for shell-semantics
// changes and doubles as the REG guard for LocalShell behavior.
//
// Skip list (documented, per AC1):
//  - Windows: LocalShell needs POSIX `sh`; rows skip on Windows.
//  - WasiSandboxShell rows are restricted to commands the shell executes
//    as DART builtins (tac/tr/expr/cd/pwd/test + the redirect machinery).
//    Rows whose command rides coreutils.wasm (echo/ls/cat) or the rg.wasm
//    grep alias cannot run against scripted modules — they are covered by
//    the argv-level pins in sandbox_shell_parity_test.dart and, with real
//    cores, by test/wasm_sandbox_toolchain_test.dart (--tags integration).
//  - `pwd`-shaped rows: LocalShell prints the HOST cwd (a real path), the
//    sandbox shells print their sandbox-absolute form — path FORMS differ
//    by design, so the table uses `cd X && <command>` instead and pins
//    cross-stage cwd only.
//  - grep -r output ORDER: POSIX leaves directory-walk order unspecified;
//    order-sensitive rows normalize by sorting lines before comparing.
library;

import 'dart:io' as io;

import 'package:fa/sandbox/memory_shell.dart';
import 'package:fa/sandbox/wasm_shell.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart' show LocalShell;
import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';

/// One conformance row: a command over a relative-path fixture.
final class ConformanceRow {
  const ConformanceRow(
    this.name,
    this.command, {
    this.files = const {
      'in.txt': 'alpha\nbeta\n',
      'work/notes.txt': 'note one\nnote two\n',
      'apps/2048/app.json': '{"tap":true}\n',
      'apps/notes/app.json': '{"other":1}\n',
    },
    this.normalize = false,
    this.wasi = true,
    this.note,
  });

  /// Row label (the pinned behavior).
  final String name;

  /// The command — RELATIVE paths only (each shell roots the same tree at
  /// its own origin).
  final String command;

  /// Fixture files written before the run (relative path → content).
  final Map<String, String> files;

  /// Optional output normalization for rows whose order POSIX leaves
  /// unspecified (grep -r walks). Lines are sorted before comparing.
  final bool normalize;

  /// Whether the WASI shell joins the row (Dart-builtin commands only —
  /// see the skip list).
  final bool wasi;

  /// Why a shell is skipped, for the failure reason.
  final String? note;
}

final conformanceTable = <ConformanceRow>[
  // ── evidence rows (gh-1393) ───────────────────────────────────────────
  ConformanceRow(
    'AC3 /dev/null stdout sink discards and does not leak',
    'tr a b < in.txt > /dev/null',
  ),
  ConformanceRow(
    'AC3 /dev/null stderr sink keeps the exit code',
    'cat nope.txt 2> /dev/null',
  ),
  ConformanceRow(
    'AC3 2>&1 folds stderr into stdout',
    'cat nope.txt 2>&1',
  ),
  ConformanceRow(
    'AC2 cd inside one command line redirects later stages',
    'cd work && tr a b < notes.txt',
    files: const {
      'work/notes.txt': 'note one\nnote two\n',
    },
  ),
  ConformanceRow(
    'AC1 apps/ fixture paths resolve identically (glob expansion itself is '
    'pinned at the argv layer in sandbox_shell_parity_test)',
    'tr a b < apps/2048/app.json',
  ),
  // ── core pipeline semantics ───────────────────────────────────────────
  const ConformanceRow('stdin redirect', 'tr a b < in.txt'),
  const ConformanceRow(
    'stdout redirect truncates',
    'tr a b < in.txt > out.txt; tr x y < out.txt',
  ),
  const ConformanceRow(
    'stdout append accumulates',
    'tr a b < in.txt > out.txt; tr a b < in.txt >> out.txt; tr x y < out.txt',
  ),
  const ConformanceRow('pipe chains two stages', 'tr a b < in.txt | tr b c'),
  const ConformanceRow(
    'stderr redirect captures tool errors',
    'cat nope.txt 2> err.txt; cat err.txt',
  ),
  const ConformanceRow(
    '&& short-circuits on failure',
    'cat nope.txt && tac < in.txt',
  ),
  const ConformanceRow(
    '|| fallback runs on failure',
    'cat nope.txt || tr a b < in.txt',
  ),
  const ConformanceRow(
    'exit code is the last stage',
    'tr a b < in.txt > /dev/null; test -f in.txt',
  ),
  const ConformanceRow(
    'test predicate exit codes match',
    'test -f in.txt',
  ),
  const ConformanceRow(
    'missing file test fails identically',
    'test -f nope.txt',
  ),
];

void main() {
  test('the conformance table covers the gh-1393 evidence rows', () {
    final names = conformanceTable.map((r) => r.name).toSet();
    expect(names, contains('AC3 /dev/null stdout sink discards and does not leak'));
    expect(names, contains('AC3 2>&1 folds stderr into stdout'));
    expect(names, contains('AC2 cd inside one command line redirects later stages'));
  });

  group('conformance: MemoryShell vs LocalShell oracle', () {
    for (final row in conformanceTable) {
      test('${row.name} — `${row.command.trim()}`', () async {
        if (io.Platform.isWindows) {
          // Documented skip: LocalShell needs POSIX sh.
          return;
        }
        final oracle = await _runLocal(row);
        expect(oracle.isOk, isTrue,
            reason: 'oracle (sh -c) failed: ${oracle.errorOrNull}');
        final expected = oracle.valueOrNull!;

        final memory = await _runMemory(row);
        expect(memory.isOk, isTrue, reason: '${memory.errorOrNull}');
        _assertSame(
          expected,
          memory.valueOrNull!,
          'MemoryShell',
          normalize: row.normalize,
        );
      });
    }
  });

  group('conformance: WasiSandboxShell (Dart-builtin rows)', () {
    for (final row in conformanceTable) {
      if (!row.wasi) continue;
      test('${row.name} — `${row.command.trim()}`', () async {
        if (io.Platform.isWindows) return;
        final oracle = await _runLocal(row);
        expect(oracle.isOk, isTrue,
            reason: 'oracle (sh -c) failed: ${oracle.errorOrNull}');
        final expected = oracle.valueOrNull!;

        final wasi = await _runWasi(row);
        expect(wasi.isOk, isTrue, reason: '${wasi.errorOrNull}');
        _assertSame(
          expected,
          wasi.valueOrNull!,
          'WasiSandboxShell',
          normalize: row.normalize,
        );
      });
    }
  });
}

/// Runs a row through the reference shell (`sh -c` in a temp fixture dir).
Future<Result<ShellExecResult, ExecutionError>> _runLocal(
  ConformanceRow row,
) async {
  final dir = await io.Directory.systemTemp.createTemp('fah_1393_conf');
  try {
    for (final entry in row.files.entries) {
      final file = io.File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    return await const LocalShell().exec(
      row.command,
      options: ShellExecOptions(cwd: dir.path),
    );
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Runs a row through the web MemoryShell rooted at `/`.
Future<Result<ShellExecResult, ExecutionError>> _runMemory(
  ConformanceRow row,
) async {
  final shell = MemoryShell();
  final env = MemoryExecutionEnv(cwd: '/', shell: shell);
  shell.attach(env);
  for (final entry in row.files.entries) {
    final write = await env.writeFile('/${entry.key}', entry.value);
    expect(write.isOk, isTrue, reason: '${write.errorOrNull}');
  }
  return env.exec(row.command);
}

/// Scripted WASM slots: the WASI rows only use Dart builtins, so no module
/// ever builds (a queued-but-unused builder fails loudly if one does —
/// that is the skip-list contract being asserted).
class _NoWasmModule extends Fake implements WasmModule {
  @override
  WasmInstanceBuilder builder({
    WasiConfig? wasiConfig,
    WorkersConfig? workersConfig,
  }) {
    throw StateError('conformance row reached a WASM core (skip-list bug)');
  }
}

Future<Result<ShellExecResult, ExecutionError>> _runWasi(
  ConformanceRow row,
) async {
  final dir = await io.Directory.systemTemp.createTemp('fah_1393_conf_wasi');
  try {
    for (final entry in row.files.entries) {
      final file = io.File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final shell = WasiSandboxShell(
      coreutils: _NoWasmModule(),
      rg: _NoWasmModule(),
      find: _NoWasmModule(),
      sed: _NoWasmModule(),
      awk: _NoWasmModule(),
      tar: _NoWasmModule(),
      gzip: _NoWasmModule(),
      zip: _NoWasmModule(),
      python: _NoWasmModule(),
      qjs: _NoWasmModule(),
      sqlite3: _NoWasmModule(),
      lua: _NoWasmModule(),
      sandboxHostPath: dir.path,
    );
    return shell.exec(row.command);
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Compares stdout (optionally order-normalized) and exit code.
void _assertSame(
  ShellExecResult expected,
  ShellExecResult actual,
  String label, {
  required bool normalize,
}) {
  String shape(ShellExecResult r) {
    var stdout = r.stdout;
    if (normalize) {
      final lines = stdout
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList()
        ..sort();
      stdout = lines.join('\n');
    }
    return 'exit=${r.exitCode} stdout=<${stdout.trim()}> stderr=<${r.stderr.trim()}>';
  }

  expect(
    shape(actual),
    shape(expected),
    reason:
        '$label diverged from the sh -c oracle '
        '(oracle: ${shape(expected)})',
  );
}
