// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Unit tests for the pasteboard text writer (`/provider export`,
// gh-1606). Every platform path funnels through an injected
// [ClipboardWriteRunner] — the tests script the pasteboard instead of
// touching a real one. The credential text must ride STDIN, never argv.
import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/clipboard_writer.dart';
import 'package:test/test.dart';

/// Records one write attempt; the scripted exit code decides the outcome.
final class _RecordingRunner {
  _RecordingRunner(this.exitCode, {this.throwOn});

  final List<(String executable, List<String> args, String stdinText)> calls =
      [];
  final int exitCode;

  /// The 0-based call index that throws instead of returning (simulates a
  /// missing executable).
  final int? throwOn;

  Future<ProcessResult> call(
    String executable,
    List<String> args,
    String stdinText,
  ) async {
    calls.add((executable, args, stdinText));
    if (throwOn == calls.length - 1) throw const ProcessException('x', []);
    return ProcessResult(1, exitCode, null, null);
  }
}

void main() {
  group('writeClipboardText', () {
    test('macos: pipes the text into pbcopy via stdin', () async {
      final runner = _RecordingRunner(0);

      final result = await writeClipboardText(
        'github_pat_TOKEN',
        runner: runner.call,
        platform: 'macos',
      );

      expect(result, isA<PasteboardWriteOk>());
      expect(runner.calls, hasLength(1));
      expect(runner.calls.single.$1, 'pbcopy');
      expect(runner.calls.single.$2, isEmpty);
      // Credential rides stdin, never argv (process listings leak args).
      expect(runner.calls.single.$3, 'github_pat_TOKEN');
    });

    test('linux: tries xclip, falls back to wl-copy', () async {
      final runner = _RecordingRunner(0);

      final result = await writeClipboardText(
        'gho_TOKEN',
        runner: runner.call,
        platform: 'linux',
      );

      expect(result, isA<PasteboardWriteOk>());
      expect(runner.calls.single.$1, 'xclip');
      expect(runner.calls.single.$2, ['-selection', 'clipboard']);
      expect(runner.calls.single.$3, 'gho_TOKEN');
    });

    test('linux: a missing xclip falls through to wl-copy', () async {
      final runner = _RecordingRunner(0, throwOn: 0);

      final result = await writeClipboardText(
        'gho_TOKEN',
        runner: runner.call,
        platform: 'linux',
      );

      expect(result, isA<PasteboardWriteOk>());
      expect(runner.calls.map((c) => c.$1), ['xclip', 'wl-copy']);
      expect(runner.calls.last.$3, 'gho_TOKEN');
    });

    test('windows: pipes the text into clip', () async {
      final runner = _RecordingRunner(0);

      final result = await writeClipboardText(
        'gho_TOKEN',
        runner: runner.call,
        platform: 'windows',
      );

      expect(result, isA<PasteboardWriteOk>());
      expect(runner.calls.single.$1, 'clip');
      expect(runner.calls.single.$3, 'gho_TOKEN');
    });

    test('every path failing becomes a named unavailable', () async {
      final runner = _RecordingRunner(1);

      final result = await writeClipboardText(
        'tok',
        runner: runner.call,
        platform: 'linux',
      );

      expect(result, isA<PasteboardWriteUnavailable>());
      expect(
        (result as PasteboardWriteUnavailable).reason,
        contains('clipboard writer'),
      );
      // All fallback paths were tried before giving up.
      expect(runner.calls, hasLength(2));
    });

    test(
      'an unknown platform is unavailable without running anything',
      () async {
        final runner = _RecordingRunner(0);

        final result = await writeClipboardText(
          'tok',
          runner: runner.call,
          platform: 'templeos',
        );

        expect(result, isA<PasteboardWriteUnavailable>());
        expect(runner.calls, isEmpty);
      },
    );

    test(
      'no platform pin: the host platform resolves the clipboard path',
      () async {
        // Exercises the host-[Platform] fallback arm of the platform
        // resolution (every other test pins `platform:` explicitly, so the
        // macOS/Linux/Windows detection never ran — CRAP 15.55 on the
        // merged-shard lcov, CI guards leg). The runner stays injected:
        // no real pasteboard is touched on any dev host.
        final runner = _RecordingRunner(0);

        final result = await writeClipboardText(
          'gho_TOKEN',
          runner: runner.call,
        );

        expect(result, isA<PasteboardWriteOk>());
        expect(runner.calls, hasLength(1));
        final expected = Platform.isMacOS
            ? 'pbcopy'
            : Platform.isWindows
            ? 'clip'
            : 'xclip';
        expect(runner.calls.single.$1, expected);
        // The credential rides stdin regardless of which arm ran.
        expect(runner.calls.single.$3, 'gho_TOKEN');
      },
    );

    test(
      'a wedged writer times out into the named unavailable (gh-1606 '
      'review: an unbounded writer holds the /provider flow gate shut)',
      () async {
        // A pasteboard binary that never exits (a shadowed pbcopy script,
        // xclip on a dead $DISPLAY): the write must degrade to the named
        // timeout result instead of hanging the export flow forever.
        Future<ProcessResult> hang(
          String executable,
          List<String> args,
          String stdinText,
        ) => Completer<ProcessResult>().future;

        final result = await writeClipboardText(
          'tok',
          runner: hang,
          platform: 'macos',
          processTimeout: const Duration(milliseconds: 50),
        );

        expect(result, isA<PasteboardWriteUnavailable>());
        expect(
          (result as PasteboardWriteUnavailable).reason,
          'clipboard writer timed out',
        );
      },
    );

    test('a timed-out path falls through to the next one (the wedge does not '
        'block the fallback writer)', () async {
      final calls = <String>[];
      Future<ProcessResult> hangFirst(
        String executable,
        List<String> args,
        String stdinText,
      ) async {
        calls.add(executable);
        if (calls.length == 1) return Completer<ProcessResult>().future;
        return ProcessResult(1, 0, null, null);
      }

      final result = await writeClipboardText(
        'gho_TOKEN',
        runner: hangFirst,
        platform: 'linux',
        processTimeout: const Duration(milliseconds: 50),
      );

      expect(result, isA<PasteboardWriteOk>());
      expect(calls, ['xclip', 'wl-copy']);
    });
  });
}
