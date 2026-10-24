// #354/#357: setup-flutter-selfhosted is the only Flutter install path on
// the self-hosted legs, and BOTH build-macos matrix arch legs run it
// CONCURRENTLY on the ONE runner (the per-arch keychain fix in that same
// workflow proves the two-legs-one-runner topology). This suite pins:
//
//  1. the SDK-slot decision logic — the six scenarios the #357 PR review
//     verified ad-hoc, now committed so a refactor cannot drift them;
//  2. the sdk_slot.py primitives that make the concurrent-install race
//     impossible by construction (atomic rename install + atomic symlink
//     flip — no lock for readers);
//  3. a regression guard keeping `cache: true` off self-hosted legs —
//     the 14.5-min SDK churn #354 removed — plus the action's structural
//     contract (bounded download, no cache POST, no destructive slot
//     swap), following the store_automation_guard_test.dart pattern of
//     text-level asserts over the workflow YAML.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const slotPy = '.github/actions/setup-flutter-selfhosted/sdk_slot.py';
const actionYml = '.github/actions/setup-flutter-selfhosted/action.yml';

ProcessResult runSlot(List<String> args, {Map<String, String> env = const {}}) {
  return Process.runSync(
    'python3',
    [slotPy, ...args],
    environment: {...Platform.environment, ...env},
  );
}

ProcessResult resolve(
  String spec,
  String sdkRoot, {
  String? marker,
  String? manifest,
}) {
  File('$sdkRoot/.fah-version').writeAsStringSync(marker ?? '');
  return runSlot(
    ['resolve', spec, '$sdkRoot/.fah-version'],
    env: {'FAH_RELEASES_MANIFEST': ?manifest},
  );
}

/// A minimal releases_macos.json: stable 3.47.1/3.47.4/3.48.0 plus a beta
/// 3.47.9 — the beta pins the channel filter (SKIP must not resolve it).
String writeManifest(Directory dir) {
  final path = '${dir.path}/releases.json';
  File(path).writeAsStringSync(
    jsonEncode({
      'releases': [
        {'version': '3.48.0', 'channel': 'stable'},
        {'version': '3.47.9', 'channel': 'beta'},
        {'version': '3.47.4', 'channel': 'stable'},
        {'version': '3.47.1', 'channel': 'stable'},
      ],
    }),
  );
  return path;
}

Directory makeSdkRoot() {
  final dir = Directory.systemTemp.createTempSync('fah_sdk_slot');
  final sdk = Directory('${dir.path}/flutter-sdk')..createSync();
  addTearDown(() => dir.deleteSync(recursive: true));
  return sdk;
}

void main() {
  group('decision logic — the six #357 review scenarios', () {
    test('1. wildcard spec, marker at the newest stable match -> SKIP', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.47.x',
        sdk.path,
        marker: '3.47.4',
        manifest: writeManifest(sdk.parent),
      );
      expect(result.exitCode, 0, reason: result.stderr);
      // 3.47.9 is beta — the channel filter must keep it out of `wanted`.
      expect(result.stdout, 'SKIP 3.47.4\n');
    });

    test('2. wildcard spec, marker at an older match -> INSTALL the bump', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.47.x',
        sdk.path,
        marker: '3.47.1',
        manifest: writeManifest(sdk.parent),
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'INSTALL 3.47.4\n');
    });

    test('3. exact spec, marker at a different version -> INSTALL', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.48.0',
        sdk.path,
        marker: '3.47.4',
        manifest: writeManifest(sdk.parent),
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'INSTALL 3.48.0\n');
    });

    test('4. manifest unreachable, marker satisfies the spec -> REUSE', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.47.x',
        sdk.path,
        marker: '3.47.4',
        manifest: '${sdk.parent.path}/no-such-manifest.json',
      );
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'REUSE 3.47.4\n');
      expect(result.stderr, contains('manifest fetch failed'));
    });

    test('5. manifest unreachable, no marker -> hard error', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.47.x',
        sdk.path,
        manifest: '${sdk.parent.path}/no-such-manifest.json',
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('no stable release matches'));
    });

    test('6. manifest reachable, no stable match, marker unsatisfying -> '
        'hard error', () {
      final sdk = makeSdkRoot();
      final result = resolve(
        '3.99.x',
        sdk.path,
        marker: '3.47.4',
        manifest: writeManifest(sdk.parent),
      );
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('no stable release matches'));
    });
  });

  group('slot primitives — race-free by construction', () {
    test('install: rename(2) lands a complete tree in an empty slot', () {
      final sdk = makeSdkRoot();
      Directory(
        '${sdk.path}/.stage.abc/flutter/bin',
      ).createSync(recursive: true);
      File(
        '${sdk.path}/.stage.abc/flutter/bin/flutter',
      ).writeAsStringSync('#!/bin/sh\n');
      final result = runSlot([
        'install',
        '${sdk.path}/.stage.abc/flutter',
        '${sdk.path}/3.47.4',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(File('${sdk.path}/3.47.4/bin/flutter').existsSync(), isTrue);
      expect(Directory('${sdk.path}/.stage.abc/flutter').existsSync(), isFalse);
    });

    test('install: concurrent winner converges the loser — slot untouched, '
        'duplicate discarded (no BSD-mv nesting)', () {
      final sdk = makeSdkRoot();
      // The winner's tree is already slotted...
      Directory('${sdk.path}/3.47.4/bin').createSync(recursive: true);
      File('${sdk.path}/3.47.4/bin/flutter').writeAsStringSync('winner');
      // ...and the loser tries to mv its identical copy over it. BSD
      // `mv` would silently NEST flutter/ INSIDE 3.47.4/; os.rename
      // must refuse and the action must treat that as convergence.
      Directory(
        '${sdk.path}/.stage.loser/flutter/bin',
      ).createSync(recursive: true);
      File(
        '${sdk.path}/.stage.loser/flutter/bin/flutter',
      ).writeAsStringSync('loser');
      final result = runSlot([
        'install',
        '${sdk.path}/.stage.loser/flutter',
        '${sdk.path}/3.47.4',
      ]);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('concurrent leg'));
      expect(
        File('${sdk.path}/3.47.4/bin/flutter').readAsStringSync(),
        'winner',
        reason: 'the occupied slot must not be merged into or replaced',
      );
      expect(
        Directory('${sdk.path}/3.47.4/flutter').existsSync(),
        isFalse,
        reason: 'the duplicate must be discarded, not nested',
      );
      expect(
        Directory('${sdk.path}/.stage.loser/flutter').existsSync(),
        isFalse,
      );
    });

    test('flip: symlink swap is atomic per os.replace and keeps old trees', () {
      final sdk = makeSdkRoot();
      for (final v in ['3.47.4', '3.48.0']) {
        Directory('${sdk.path}/$v/bin').createSync(recursive: true);
        File('${sdk.path}/$v/bin/flutter').writeAsStringSync(v);
      }
      runSlot(['flip', '${sdk.path}/3.47.4', '${sdk.path}/current']);
      expect(Link('${sdk.path}/current').targetSync(), '${sdk.path}/3.47.4');
      // Flip again — readers resolving `current` mid-flip observe one
      // complete tree or the other; the swapped-out tree stays on disk
      // for in-flight legs until gc drains it.
      runSlot(['flip', '${sdk.path}/3.48.0', '${sdk.path}/current']);
      expect(Link('${sdk.path}/current').targetSync(), '${sdk.path}/3.48.0');
      expect(
        File('${sdk.path}/3.47.4/bin/flutter').existsSync(),
        isTrue,
        reason: 'flip must never delete the version it swaps away from',
      );
      expect(
        File('${sdk.path}/current/bin/flutter').readAsStringSync(),
        '3.48.0',
      );
    });

    test('flip: re-creating a missing link is idempotent', () {
      final sdk = makeSdkRoot();
      Directory('${sdk.path}/3.47.4/bin').createSync(recursive: true);
      for (final _ in [1, 2]) {
        final result = runSlot([
          'flip',
          '${sdk.path}/3.47.4',
          '${sdk.path}/current',
        ]);
        expect(result.exitCode, 0, reason: result.stderr);
      }
      expect(Link('${sdk.path}/current').targetSync(), '${sdk.path}/3.47.4');
    });

    test('migrate: legacy real-dir current moves into its marker slot', () {
      final sdk = makeSdkRoot();
      Directory('${sdk.path}/current/bin').createSync(recursive: true);
      File('${sdk.path}/current/bin/flutter').writeAsStringSync('legacy');
      File('${sdk.path}/.fah-version').writeAsStringSync('3.47.4');
      final result = runSlot(['migrate', sdk.path, '${sdk.path}/.fah-version']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        File('${sdk.path}/3.47.4/bin/flutter').readAsStringSync(),
        'legacy',
      );
      expect(
        Directory('${sdk.path}/current').existsSync(),
        isFalse,
        reason: 'the slot must be free for the symlink flip',
      );
    });

    test(
      'migrate: unmarked legacy dir is dropped, symlinked layout no-ops',
      () {
        final sdk = makeSdkRoot();
        Directory('${sdk.path}/current/bin').createSync(recursive: true);
        runSlot(['migrate', sdk.path, '${sdk.path}/.fah-version']);
        expect(Directory('${sdk.path}/current').existsSync(), isFalse);
        // Already-migrated layout: a symlink must survive migration.
        Directory('${sdk.path}/3.47.4/bin').createSync(recursive: true);
        Link('${sdk.path}/current').createSync('${sdk.path}/3.47.4');
        runSlot(['migrate', sdk.path, '${sdk.path}/.fah-version']);
        expect(Link('${sdk.path}/current').targetSync(), '${sdk.path}/3.47.4');
      },
    );

    test(
      'gc: keeps the live version, drains only old trees + stale stages',
      () {
        final sdk = makeSdkRoot();
        for (final v in ['3.46.0', '3.47.4']) {
          Directory('${sdk.path}/$v/bin').createSync(recursive: true);
          File('${sdk.path}/$v/bin/flutter').writeAsStringSync(v);
        }
        Directory('${sdk.path}/.stage.dead').createSync(recursive: true);
        Directory('${sdk.path}/.stage.fresh').createSync(recursive: true);
        // Backdate the gc-eligible dirs via os.utime — same python3 this
        // suite already depends on (Dart's setLastModifiedSync is File-only).
        for (final p in ['${sdk.path}/3.46.0', '${sdk.path}/.stage.dead']) {
          final res = Process.runSync('python3', [
            '-c',
            'import os, sys, time; t = time.time() - 3*86400; '
                'os.utime(sys.argv[1], (t, t))',
            p,
          ]);
          expect(res.exitCode, 0, reason: res.stderr);
        }
        final result = runSlot(['gc', sdk.path, '${sdk.path}/3.47.4', '2']);
        expect(result.exitCode, 0, reason: result.stderr);
        expect(
          Directory('${sdk.path}/3.47.4/bin').existsSync(),
          isTrue,
          reason: 'the live target is never eligible',
        );
        expect(Directory('${sdk.path}/3.46.0').existsSync(), isFalse);
        expect(Directory('${sdk.path}/.stage.dead').existsSync(), isFalse);
        expect(Directory('${sdk.path}/.stage.fresh').existsSync(), isTrue);
      },
    );
  });

  group('host-arch archive selection + slot arch stamp (gh-1736)', () {
    // gh-1736: the action downloaded the arch-less flutter_macos_<v> zip —
    // the X64 build per releases_macos.json — onto the arm64 self-hosted
    // host, so the slot's dart binary died with "Bad CPU type in
    // executable" (exit 126). The archive name must come from the HOST
    // arch: both matrix legs run on the ONE runner and share one SDK slot
    // (the matrix arch only steers FLUTTER_XCODE_ARCHS), and the manifest
    // convention is `_arm64` infix for arm64, no infix for x64.
    test('archive: arm64 host -> arm64-qualified zip name', () {
      final result = runSlot(['archive', '3.47.7', 'arm64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        result.stdout,
        'flutter_macos_arm64_3.47.7-stable.zip\n',
        reason:
            'releases_macos.json: dart_sdk_arch=arm64 -> '
            'flutter_macos_arm64_3.47.7-stable.zip',
      );
    });

    test('archive: x86_64 host -> unqualified (x64) zip name', () {
      final result = runSlot(['archive', '3.47.7', 'x86_64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(
        result.stdout,
        'flutter_macos_3.47.7-stable.zip\n',
        reason:
            'releases_macos.json: dart_sdk_arch=x64 -> '
            'flutter_macos_3.47.7-stable.zip (no infix)',
      );
    });

    test('archive: unknown host arch is a hard error, never a silent x64', () {
      final result = runSlot(['archive', '3.47.7', 'sparc64']);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('sparc64'));
    });

    test('ensure_arch: stamped matching slot stays (ok)', () {
      final sdk = makeSdkRoot();
      Directory('${sdk.path}/3.47.7/bin').createSync(recursive: true);
      File('${sdk.path}/3.47.7/.fah-arch').writeAsStringSync('arm64');
      final result = runSlot(['ensure_arch', '${sdk.path}/3.47.7', 'arm64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'ok\n');
      expect(Directory('${sdk.path}/3.47.7/bin').existsSync(), isTrue);
    });

    test('ensure_arch: raw uname stamp round-trips on x86_64 hosts '
        '(gh-1736 review) — no prune, no re-download', () {
      // action.yml stamps every staged tree with the RAW `uname -m`
      // output, while ensure_arch compares against the NORMALISED
      // manifest vocabulary. On x86_64 the two spellings differ
      // (`x86_64` vs `x64`) — before the round-trip fix this exact
      // state (the stamp the action just wrote) was answered
      // `reinstall`, pruning the slot and costing a ~1GB re-download
      // on EVERY run. The stamp must round-trip at both arches: the
      // arm64 spelling (raw == normalised) is pinned by the
      // 'stamped matching slot stays (ok)' test above.
      final sdk = makeSdkRoot();
      Directory('${sdk.path}/3.47.7/bin').createSync(recursive: true);
      File('${sdk.path}/3.47.7/.fah-arch').writeAsStringSync('x86_64');
      final result = runSlot(['ensure_arch', '${sdk.path}/3.47.7', 'x86_64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'ok\n');
      expect(
        Directory('${sdk.path}/3.47.7/bin').existsSync(),
        isTrue,
        reason:
            'a freshly stamped slot must survive ensure_arch — '
            'pruning it re-downloads ~1GB on every single run',
      );
    });

    test('ensure_arch: unstamped slot (the gh-1736 poisoned runner state) '
        'is pruned for reinstall', () {
      final sdk = makeSdkRoot();
      // What the runner holds right now: an x64 3.47.7 installed by the
      // pre-fix action — no arch stamp, and the marker already reads
      // 3.47.7, so resolve() answers SKIP and only an arch self-heal can
      // un-brick the slot.
      Directory('${sdk.path}/3.47.7/bin').createSync(recursive: true);
      File('${sdk.path}/3.47.7/bin/flutter').writeAsStringSync('x64 sdk');
      final result = runSlot(['ensure_arch', '${sdk.path}/3.47.7', 'arm64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, startsWith('reinstall'));
      expect(
        Directory('${sdk.path}/3.47.7').existsSync(),
        isFalse,
        reason: 'the wrong-arch slot must go so INSTALL rebuilds it',
      );
    });

    test('ensure_arch: mismatched stamp is pruned for reinstall', () {
      final sdk = makeSdkRoot();
      Directory('${sdk.path}/3.47.7/bin').createSync(recursive: true);
      File('${sdk.path}/3.47.7/.fah-arch').writeAsStringSync('x64');
      final result = runSlot(['ensure_arch', '${sdk.path}/3.47.7', 'arm64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, startsWith('reinstall'));
      expect(Directory('${sdk.path}/3.47.7').existsSync(), isFalse);
    });

    test('ensure_arch: missing slot is a no-op ok (install creates it)', () {
      final sdk = makeSdkRoot();
      final result = runSlot(['ensure_arch', '${sdk.path}/3.47.7', 'arm64']);
      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, 'ok\n');
    });
  });

  group('self-hosted SDK regression guard (#354/#357)', () {
    final workflows = Directory('.github/workflows')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.yml'))
        .toList();

    /// A job's runner labels, resolving `${{ matrix.* }}` against the
    /// strategy's include entries so matrix-driven runners are covered.
    List<String> runnerLabels(Map job) {
      final runsOn = job['runs-on'];
      if (runsOn is List) return runsOn.map((e) => '$e').toList();
      if (runsOn is! String) return const [];
      final m = RegExp(r'^\$\{\{\s*matrix\.(\w+)\s*\}\}$').firstMatch(runsOn);
      if (m == null) return [runsOn];
      final labels = <String>[];
      final matrix = (job['strategy'] as Map?)?['matrix'];
      Object? includes = matrix is Map ? matrix[m.group(1)] : null;
      if (matrix is Map && matrix['include'] is Iterable) {
        for (final inc in matrix['include'] as Iterable) {
          if (inc is Map && inc.containsKey(m.group(1))) {
            includes = inc[m.group(1)];
          }
        }
      }
      if (includes is Iterable) {
        labels.addAll(includes.map((e) => '$e'));
      } else if (includes != null) {
        labels.add('$includes');
      }
      return labels.isEmpty ? [runsOn] : labels;
    }

    test('no self-hosted leg may pair subosito/flutter-action with cache: '
        'true', () {
      // The #354 numbers: 5m39s untar + 8m47s re-tar POST = 14.5 of
      // 19.7 min per job on the persistent runner. `cache: true` must
      // never come back on a self-hosted leg (GitHub-hosted legs keep it
      // — there it is a genuine win).
      var checked = 0;
      for (final file in workflows) {
        final yaml = loadYaml(File(file.path).readAsStringSync()) as Map;
        for (final entry in (yaml['jobs'] as Map? ?? {}).entries) {
          final job = entry.value as Map;
          final selfHosted = runnerLabels(job).contains('self-hosted');
          if (!selfHosted) continue;
          checked++;
          for (final step in (job['steps'] as Iterable)) {
            final uses = (step as Map)['uses'];
            if (uses is String && uses.startsWith('subosito/flutter-action')) {
              // '$cache' normalizes YAML bools: bare `cache: true` loads as
              // bool true, and isNot('true') on the raw value would pass.
              final cache = (step['with'] as Map?)?['cache'];
              expect(
                '$cache',
                isNot('true'),
                reason:
                    '${file.path} job `${entry.key}` runs on a self-hosted '
                    'runner — subosito/flutter-action with cache: true '
                    're-introduces the 14.5-min SDK churn #354/#357 removed; '
                    'use ./.github/actions/setup-flutter-selfhosted instead',
              );
            }
          }
        }
      }
      expect(
        checked,
        greaterThanOrEqualTo(3),
        reason:
            'expected the three known self-hosted jobs — the workflow '
            'topology changed and this guard scanned nothing',
      );
    });

    test(
      'the self-hosted build legs set Flutter up via the composite action',
      () {
        for (final path in [
          '.github/workflows/build-mobile.yml',
          '.github/workflows/build-macos.yml',
        ]) {
          expect(
            File(path).readAsStringSync(),
            contains('uses: ./.github/actions/setup-flutter-selfhosted'),
            reason:
                '$path self-hosted legs must use the persistent pinned '
                'SDK action (#354), not an ephemeral install',
          );
        }
      },
    );

    test('self-hosted legs pin an EXACT Flutter patch, never a wildcard '
        '(gh-1826)', () {
      const pinnedVersion = '3.47.7';
      for (final entry in const {
        '.github/workflows/build-mobile.yml': 'build-ios',
        '.github/workflows/build-macos.yml': 'build-macos',
      }.entries) {
        final steps = ((loadYaml(
          File(entry.key).readAsStringSync(),
        )['jobs'] as YamlMap)[entry.value] as YamlMap)['steps'] as YamlList;
        final setup = steps.whereType<YamlMap>().firstWhere(
          (s) => (s['uses']?.toString() ?? '')
              .contains('setup-flutter-selfhosted'),
        );
        final version =
            ((setup['with'] as YamlMap?)?['flutter-version'] ?? '')
                .toString();
        expect(
          version,
          pinnedVersion,
          reason:
              '${entry.key} ${entry.value}: a wildcard spec (3.47.x) '
              're-resolves a freshly released patch the fa-m5 runners '
              'have not cached — run 40066130883 (2026-10-24) resolved '
              '3.47.x to 3.47.8 and the TestFlight leg died downloading '
              'the 2.27 GB SDK inside the bounded curl budget '
              '(600s/attempt, 900s total) with 1.48 GB received. '
              'Exact-patch discipline (#1431): the pin moves consciously, '
              'in a PR, matching the desktop lane.',
        );
      }
    });

    test('action contract: bounded download, no cache POST, no slot swap', () {
      final action = File(actionYml).readAsStringSync();
      // Slice out the actual curl invocation — asserting on the whole
      // file would be satisfiable by the failure-message text alone.
      final curlStart = action.indexOf('if ! curl');
      final curlEnd = action.indexOf('; then', curlStart);
      expect(
        curlStart,
        isNonNegative,
        reason: 'the SDK download must go through a single curl step',
      );
      final curl = action.substring(curlStart, curlEnd);
      expect(
        curl,
        contains('--max-time 600'),
        reason: 'the ~1GB SDK download must be bounded (#357 should-have)',
      );
      expect(
        curl,
        contains('--retry-max-time 900'),
        reason: 'the retry cycle as a whole must be bounded too',
      );
      expect(
        action,
        isNot(contains(RegExp(r'uses:\s*actions/cache'))),
        reason: 'an actions/cache step re-adds the POST-step SDK re-tar (#354)',
      );
      expect(
        action,
        isNot(contains('/next')),
        reason:
            'the rm-then-mv next/current swap was the #357 blocker — '
            'per-version dirs + atomic symlink flip replaced it',
      );
      expect(
        action,
        isNot(contains(r'rm -rf "$CURRENT"')),
        reason:
            'the live slot must never be deleted from under in-flight '
            'readers; only gc removes drained, superseded version dirs',
      );
      expect(
        action,
        contains('sdk_slot.py'),
        reason: 'slot mutations must go through the tested primitives',
      );
    });
    test(
      'action contract: the SDK download is host-arch qualified (gh-1736)',
      () {
        final action = File(actionYml).readAsStringSync();
        final curlStart = action.indexOf('if ! curl');
        final curlEnd = action.indexOf('; then', curlStart);
        expect(curlStart, isNonNegative);
        final curl = action.substring(curlStart, curlEnd);
        // gh-1736: the arch-less flutter_macos_${VER}-stable.zip is the X64
        // archive — on the arm64 self-hosted host its dart binary dies with
        // "Bad CPU type in executable" (exit 126). The archive name must be
        // resolved through the tested sdk_slot.py archive primitive.
        expect(
          curl,
          contains(r'$ARCHIVE'),
          reason: r'the curl URL must download the arch-resolved "$ARCHIVE"',
        );
        expect(
          action,
          contains(r'"$SLOT" archive'),
          reason:
              'archive-name resolution must go through the tested primitive',
        );
        expect(
          action,
          isNot(contains(r'flutter_macos_${VER}-stable.zip')),
          reason: 'the arch-less URL is the x64 build — the gh-1736 bug',
        );
      },
    );

    test('action contract: a failed ensure_arch is a loud error, never a '
        'silent fall-through to reusing the slot (gh-1736 review)', () {
      final action = File(actionYml).readAsStringSync();
      final healStart = action.indexOf(
        r'if [[ "$DECISION" != INSTALL* ]]; then',
      );
      final healEnd = action.indexOf('\n        fi', healStart);
      expect(
        healStart,
        isNonNegative,
        reason: 'the self-heal block must guard every non-INSTALL verdict',
      );
      final heal = action.substring(healStart, healEnd);
      final callIdx = heal.indexOf(r'ensure_arch "$DEST" "$HOST_ARCH")');
      expect(
        callIdx,
        isNonNegative,
        reason: 'the self-heal must consult the ensure_arch primitive',
      );
      final callLine = heal.substring(
        heal.lastIndexOf('\n', callIdx) + 1,
        heal.indexOf('\n', callIdx),
      );
      // The old shape — `elif [[ "$(python3 … ensure_arch …)" == reinstall* ]]`
      // — turns any nonzero exit into an empty string and a false `==`: the
      // failure silently falls through to trusting the existing slot. The
      // verdict must be captured with its exit code checked explicitly, and
      // a failure must fail the step loudly.
      expect(
        callLine,
        isNot(contains('elif [[')),
        reason:
            'ensure_arch must not be consulted through a bare `elif '
            r'[[ "$( … )" == … ]]` command substitution — a nonzero exit '
            'degrades to an empty verdict and a silent slot reuse',
      );
      expect(
        callLine,
        contains('|| {'),
        reason:
            'the ensure_arch verdict must be captured with an explicit '
            'exit-code check',
      );
      expect(
        heal,
        contains('::error::'),
        reason:
            'an ensure_arch failure must surface as a step error '
            'annotation, not as a silently skipped self-heal',
      );
      expect(
        heal,
        contains('exit 1'),
        reason: 'an ensure_arch failure must fail the step',
      );
    });

    test('action.yml and the touched workflows parse as YAML', () {
      loadYaml(File(actionYml).readAsStringSync());
      for (final path in [
        '.github/workflows/build-mobile.yml',
        '.github/workflows/build-macos.yml',
      ]) {
        loadYaml(File(path).readAsStringSync());
      }
    });
  });
}
