// gh-2055 (2026-11-04): the daily-publish `cli` leg went red in
// "Build macOS release (x86_64)" — `Error running pod install`. The log
// (run 41778615815, job 126405040660) shows the exact sequence:
//
//   ✓ Restore vendored WasmRun macOS framework  — actions/cache hit
//     (wasmrun-xcframework-v0.1.0), "Using framework already in place",
//     Info.plist + macos-arm64_x86_64 verified on disk at 06:09:21;
//   ✗ Build macOS release (x86_64) — pod install evaluated the backtick
//     shell block in vendor/wasm_run_flutter/macos/wasm_run_flutter.podspec,
//     whose guard is `if [ ! -f wasm_run-v0.1.0.zip ]` — keyed on the
//     downloaded-zip MARKER, not on the framework. A fresh clone never has
//     the marker, so the block ran despite the restored framework:
//     `rm -rf WasmRun.xcframework` deleted the digest-verified framework,
//     a bare `curl -L` (no --fail, no resume, no cap) crawled to ~3 MB of
//     the 92.7 MB asset at ~36 KB/s and died with
//     `curl: (56) Recv failure: Connection reset by peer`; the failure was
//     ignored, `unzip` hit "End-of-central-directory signature not found",
//     and pod install continued with NO framework on disk — the Podfile
//     post_install hook then ran `nm -gU -arch arm64` on the missing
//     macos-arm64_x86_64/libwasm_run_dart.a and the leg went red.
//
// The hardened download path (build-macos.yml "Restore vendored WasmRun
// macOS framework", gh-1149/gh-1759: cache → local copy → digest-verified
// resumable curl) already guarantees the framework is in place before pod
// install. The podspec block must therefore be keyed on the artifact pod
// install actually consumes — WasmRun.xcframework/macos-arm64_x86_64/
// libwasm_run_dart.a, the exact path the Podfile force_loads and nm-checks
// — and must never delete a framework whose consuming artifact exists.
// When the block does run (truly cold, local dev), its curl must carry
// --fail so HTTP errors never masquerade as a zip (the gh-1149 posture
// wasmrun_restore_budget_test.dart pins for the workflow step), AND the
// block must abort at the curl step when the download fails
// (`|| { echo … >&2; exit 1; }` — a swallowed status fell through to
// unzip/truncate, the block still exited 0, and pod install died at the
// Podfile nm check with the root cause masked; the review round on this
// PR replayed exactly that with a stubbed curl exiting 60).
//
// Behavioral reproduction: the podspec's real shell block is extracted,
// its Ruby interpolations resolved, and executed in a sandbox with a
// stubbed `curl` (never the network) — mirroring the CI sequence; the
// stub's chmod is asserted so a silent stub failure cannot fall through
// PATH to the REAL curl. The behavioral group is POSIX-only
// (sh/chmod/#!/bin/sh stub) and skips elsewhere; the static lints run
// everywhere. Static lint over the vendored pod, same style as
// wasmrun_macos_pod_link_test.dart.
import 'dart:io';

import 'package:test/test.dart';

const podspecPath = 'vendor/wasm_run_flutter/macos/wasm_run_flutter.podspec';
const podfilePath = 'flutter_app/macos/Podfile';

/// The archive slice the macOS build consumes: Podfile force_loads and
/// nm-checks exactly this file (see $podfilePath macos_slice).
const consumedArchive =
    'WasmRun.xcframework/macos-arm64_x86_64/libwasm_run_dart.a';

String read(String path) => File(path).readAsStringSync();

/// The backtick shell block of the podspec: everything between the two
/// standalone backtick fence lines.
String shellBlock(String podspec) {
  final lines = podspec.split('\n');
  final fences = <int>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == '`') fences.add(i);
  }
  expect(
    fences,
    hasLength(2),
    reason: '$podspecPath must keep exactly one backtick shell block',
  );
  return lines.sublist(fences[0] + 1, fences[1]).join('\n');
}

/// Resolve the podspec's Ruby variables (`name = 'literal'` and
/// `name = "…#{var}…"`) and substitute every `#{var}` in [text].
String interpolate(String text, String podspec) {
  final vars = <String, String>{};
  final single = RegExp(r"^(\w+)\s*=\s*'([^']*)'");
  final double = RegExp(r'^(\w+)\s*=\s*"([^"]*)"');
  for (final line in podspec.split('\n')) {
    final m = single.firstMatch(line);
    if (m != null) vars[m.group(1)!] = m.group(2)!;
  }
  for (final line in podspec.split('\n')) {
    final m = double.firstMatch(line);
    if (m != null) {
      vars[m.group(1)!] = m
          .group(2)!
          .replaceAllMapped(
            RegExp(r'#\{(\w+)\}'),
            (x) => vars[x.group(1)] ?? '',
          );
    }
  }
  return text.replaceAllMapped(RegExp(r'#\{(\w+)\}'), (x) {
    final v = vars[x.group(1)];
    expect(
      v,
      isNotNull,
      reason: 'unresolved podspec variable #{${x.group(1)}}',
    );
    return v!;
  });
}

/// Runs [script] in [cwd] with a stubbed `curl` first on PATH. The stub
/// records its invocation into `$CURL_STUB_LOG` and exits non-zero, so a
/// download attempt is observable WITHOUT touching the network.
ProcessResult runBlock(String script, String cwd, String stubDir, String log) {
  final bin = Directory(stubDir)..createSync(recursive: true);
  final stub = File('${bin.path}/curl');
  stub.writeAsStringSync(
    '#!/bin/sh\necho "curl \$*" >> "\$CURL_STUB_LOG"\nexit 60\n',
  );
  final chmod = Process.runSync('chmod', ['+x', stub.path]);
  expect(
    chmod.exitCode,
    0,
    reason:
        'curl stub must be executable — PATH resolution skips '
        'non-executable entries and would fall through to the REAL curl, '
        'sending these tests to the network instead of the stub',
  );
  final path = Platform.environment['PATH'] ?? '/usr/bin:/bin';
  return Process.runSync(
    'sh',
    ['-c', script],
    workingDirectory: cwd,
    environment: {'PATH': '$stubDir:$path', 'CURL_STUB_LOG': log},
  );
}

void main() {
  // The behavioral sandbox shells out to `sh`, `chmod` and a `#!/bin/sh`
  // curl stub — POSIX-bound (the CI root Dart suite runs on ubuntu). On
  // other platforms the behavioral group SKIPS so a Windows dev running
  // `dart test` locally neither fails nor risks a ProcessException from
  // `chmod`; the static lints below stay unskipped everywhere
  // (same pattern as test/cli/clipboard_reader_test.dart).
  final posixSandbox = Platform.isLinux || Platform.isMacOS;

  group('wasm_run_flutter macOS podspec download guard (gh-2055)', () {
    group(
      'behavioral — the podspec shell block in a stubbed-curl sandbox',
      () {
        test(
          'block is a NO-OP when the consumed archive is present — a restored '
          'framework must survive pod install even with no zip marker',
          () {
            final tmp = Directory.systemTemp.createTempSync('gh2055-');
            addTearDown(() => tmp.deleteSync(recursive: true));
            final work = Directory('${tmp.path}/work')..createSync();
            final framework = File('${work.path}/Frameworks/$consumedArchive');
            framework.createSync(recursive: true);
            framework.writeAsStringSync('fixture archive\n');

            final block = interpolate(
              shellBlock(read(podspecPath)),
              read(podspecPath),
            );
            final log = '${tmp.path}/stub.log';
            final r = runBlock(block, work.path, '${tmp.path}/bin', log);

            expect(
              r.exitCode,
              0,
              reason: 'no-op path must not fail pod install',
            );
            expect(
              framework.existsSync(),
              isTrue,
              reason:
                  'THE gh-2055 failure: the block must not `rm -rf` the '
                  'framework the restore step (cache/local/digest-verified '
                  'download) already placed — pod install deleted a valid '
                  'WasmRun.xcframework, then its own unverified download died '
                  'mid-transfer (curl 56) and the nm check found no '
                  'libwasm_run_dart.a (run 41778615815)',
            );
            expect(
              File(log).existsSync(),
              isFalse,
              reason:
                  'the 92.7 MB release asset must NOT re-download on every '
                  'build — with the framework in place the block must skip '
                  'entirely (the guard must key on the archive, not the '
                  'wasm_run-v0.1.0.zip marker)',
            );
          },
        );

        test('block still downloads when the archive is genuinely absent '
            '(guard must not be over-broad)', () {
          final tmp = Directory.systemTemp.createTempSync('gh2055-');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final work = '${tmp.path}/work';
          Directory('$work/Frameworks').createSync(recursive: true);

          final block = interpolate(
            shellBlock(read(podspecPath)),
            read(podspecPath),
          );
          final log = '${tmp.path}/stub.log';
          runBlock(block, work, '${tmp.path}/bin', log);

          expect(
            File(log).existsSync(),
            isTrue,
            reason:
                'with no framework on disk the block must attempt the '
                'download — keying the guard on the archive must not '
                'turn it into a silent no-op for the truly-cold path',
          );
        });

        test('a stale 0-byte zip marker (left by truncate after a failed run) '
            'must not suppress a download while the archive is missing', () {
          final tmp = Directory.systemTemp.createTempSync('gh2055-');
          addTearDown(() => tmp.deleteSync(recursive: true));
          final work = '${tmp.path}/work';
          // The exact residue the old block left after a failed download:
          // no framework, but a truncated (0-byte) wasm_run-v0.1.0.zip.
          Directory('$work/Frameworks').createSync(recursive: true);
          File('$work/Frameworks/wasm_run-v0.1.0.zip').writeAsStringSync('');

          final block = interpolate(
            shellBlock(read(podspecPath)),
            read(podspecPath),
          );
          final log = '${tmp.path}/stub.log';
          runBlock(block, work, '${tmp.path}/bin', log);

          expect(
            File(log).existsSync(),
            isTrue,
            reason:
                'the guard must not trust the zip marker: the truncated '
                'zip left behind by a previous failed run must not skip '
                'the download — under the old marker guard this state '
                'replayed the nm failure on every pod install',
          );
        });

        test(
          'a failed fallback download aborts the block with a non-zero exit — '
          'the failure must surface at the curl step, not be swallowed into the '
          'downstream nm diagnostic',
          () {
            final tmp = Directory.systemTemp.createTempSync('gh2055-');
            addTearDown(() => tmp.deleteSync(recursive: true));
            final work = '${tmp.path}/work';
            Directory('$work/Frameworks').createSync(recursive: true);

            final block = interpolate(
              shellBlock(read(podspecPath)),
              read(podspecPath),
            );
            final log = '${tmp.path}/stub.log';
            final r = runBlock(block, work, '${tmp.path}/bin', log);

            expect(
              r.exitCode,
              isNot(0),
              reason:
                  'the block must fail at the step that failed: curl already '
                  'carries --fail, but an ignored exit status falls through to '
                  'unzip (misleading "not a zip" error) and the shell block '
                  'still exits 0 — pod install then dies at the Podfile nm '
                  'check with the curl root cause masked. Same '
                  '"fail loudly at the failing step" posture the gh-1149 '
                  'restore step is linted for.',
            );
            expect(
              File(log).existsSync(),
              isTrue,
              reason: 'the download must have been attempted before failing',
            );
          },
        );
      },
      skip: posixSandbox
          ? null
          : 'behavioral sandbox shells out to sh/chmod — POSIX only; '
                'static lints below still run everywhere',
    );

    group('static lint — pure text invariants, no sandbox', () {
      test(
        'guard keys on the archive the Podfile consumes, not the zip marker',
        () {
          final podspec = read(podspecPath);
          final block = interpolate(shellBlock(podspec), podspec);
          // Anchor POSITIVELY on the consumed-archive path, not on "the first
          // line starting with `if `" — a second, unrelated `if` above the
          // guard would silently re-latch the old anchor while the real guard
          // regresses to the zip marker. singleWhere also fails if the archive
          // path appears in more than one place, itself a drift signal.
          final guardLine = block
              .split('\n')
              .singleWhere(
                (l) => l.contains(consumedArchive),
                orElse: () => fail(
                  'the podspec shell block no longer keys its guard on '
                  '$consumedArchive — the wasm_run-v0.1.0.zip-marker guard made '
                  'the block run (and `rm -rf` the restored framework) on every '
                  'fresh CI clone (gh-2055)',
                ),
              );
          expect(
            guardLine.trimLeft().startsWith('if '),
            isTrue,
            reason:
                'the archive-keyed line must be the if-guard itself, not a '
                'mention elsewhere in the block',
          );
          expect(
            guardLine.contains('[ ! -f'),
            isTrue,
            reason:
                'the guard must TEST for the archive\'s presence '
                '("if [ ! -f … ]"), not merely reference it',
          );
        },
      );

      test(
        'curl fails on HTTP errors AND aborts the block — gh-1149 posture',
        () {
          final block = shellBlock(read(podspecPath));
          final curlLine = block
              .split('\n')
              .singleWhere(
                (l) => l.trimLeft().startsWith('curl '),
                orElse: () => fail(
                  'no curl line in the podspec shell block — the cold-tree '
                  'download fallback vanished',
                ),
              );
          expect(
            curlLine,
            contains('--fail'),
            reason:
                'without --fail curl exits 0 on HTTP 404/5xx and writes the '
                'error page into the zip; unzip then fails with a misleading '
                '"not a zip" error. Same invariant '
                'wasmrun_restore_budget_test.dart pins for the workflow '
                'restore step.',
          );
          expect(
            curlLine,
            contains('exit 1'),
            reason:
                'an ignored curl exit status falls through to unzip/truncate '
                'and the shell block still exits 0 — pod install then dies at '
                'the Podfile nm check with the curl root cause masked (the '
                'gh-2055 review replay: stubbed curl exiting 60, block exit '
                '0). The || guard fails the block AT the curl step.',
          );
        },
      );

      test('the consumed archive path matches the Podfile slice', () {
        final podfile = read(podfilePath);
        final slice = RegExp(
          r"macos_slice = '[^']*libwasm_run_dart\.a'",
        ).firstMatch(podfile)!.group(0)!;
        expect(
          slice,
          contains('Frameworks/$consumedArchive'),
          reason:
              'the guard and the consumer must agree on one path — the '
              'podspec skip-condition exists precisely to protect the file '
              '$podfilePath reads',
        );
      });
    });
  });
}
