// Unit proof for the gh-1300 FA_BIN seam: every PTY/CLI integration test
// spawns a fresh CLI, and on CI each spawn paid VM start + CFE kernel
// compile (~30 s on loaded ARM runners) before `main()` ran. The seam
// swaps the spawn for a prebuilt AOT binary (`dart build cli`, compiled
// ONCE per shard job) without changing any test's isolation shape.
//
// Top-level and pure (like `pollUntil`/`maskedValueRow`) so the
// command-resolution rule is provable without a PTY. Runs in the DEFAULT
// suite (no integration tag). Every case pins BOTH ambient inputs
// explicitly (`faBin` / `useAmbientFaBin` + `ambientFaBin`) — a CI shard
// exports FA_BIN for the whole leg, so a test that read the real
// environment would be order- and host-dependent.
@TestOn('vm')
library;

import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  group('faCliCommand', () {
    test('explicit faBin wins over the ambient environment', () {
      final cmd = faCliCommand(
        ['--model', 'm'],
        faBin: '/pinned/fa',
        ambientFaBin: '/ambient/fa',
      );
      expect(cmd, ['/pinned/fa', '--model', 'm']);
    });

    test('ambient FA_BIN applies when the caller pins nothing', () {
      final cmd = faCliCommand(
        ['--model', 'm'],
        ambientFaBin: '/ambient/fa',
      );
      expect(cmd, ['/ambient/fa', '--model', 'm']);
    });

    test('no FA_BIN anywhere falls back to the default JIT prefix', () {
      final cmd = faCliCommand(
        ['--model', 'm'],
        useAmbientFaBin: false,
      );
      expect(cmd, ['dart', 'bin/fah.dart', '--model', 'm']);
    });

    test('custom JIT prefix is preserved verbatim (dart run shape)', () {
      final cmd = faCliCommand(
        ['dap', 'status'],
        useAmbientFaBin: false,
        jitPrefix: ['dart', 'run', 'bin/fah.dart'],
      );
      expect(cmd, ['dart', 'run', 'bin/fah.dart', 'dap', 'status']);
    });

    test('JIT prefix may carry VM flags before the script path', () {
      final cmd = faCliCommand(
        const [],
        useAmbientFaBin: false,
        jitPrefix: [
          'dart',
          '--disable-service-auth-codes',
          '--observe=8123',
          '/repo/bin/fah.dart',
        ],
      );
      expect(
        cmd,
        ['dart', '--disable-service-auth-codes', '--observe=8123',
            '/repo/bin/fah.dart'],
      );
    });

    test('args are appended verbatim in the AOT shape (2+ items)', () {
      final cmd = faCliCommand(
        ['trajectory', 'view', 's1', '--session-root', '/tmp/s'],
        faBin: '/ambient/fa',
      );
      expect(cmd, [
        '/ambient/fa',
        'trajectory',
        'view',
        's1',
        '--session-root',
        '/tmp/s',
      ]);
    });

    test('empty args reduce to the binary itself', () {
      expect(faCliCommand(const [], faBin: '/ambient/fa'), ['/ambient/fa']);
      expect(
        faCliCommand(const [], useAmbientFaBin: false),
        ['dart', 'bin/fah.dart'],
      );
    });
  });
}
