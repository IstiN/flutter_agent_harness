// gh-1832 regression guards: release v1.0.635 published without
// fa-extension.zip because the tag train (ci.yml release-provenance)
// publishes whatever the release happens to carry and the extension's only
// producer (build-macos.yml `Build Chrome extension`) attaches to a tag it
// derives as "latest+1 at its own dispatch moment". Guards:
//   1. one required-assets list (single source of truth) exists and is
//      well-formed;
//   2. the tag train's publish point (`gh release edit --draft=false
//      --latest`) is gated by scripts/assert_release_assets.sh — a missing
//      asset blocks the publish loudly (release stays draft);
//   3. a post-publish smoke job probes every landing-page release link and
//      the full required set (red on 404);
//   4. behavioral rehearsal: a release whose asset set is missing
//      fa-extension.zip FAILS the gate (the AC4 dry-run "extension leg
//      artificially absent → release blocked"), a complete one passes, and
//      the smoke/landing modes go red on a 404 link.
// Static lint + stubbed-gh/HTTP harness in the same style as
// release_empty_latest_guard_test.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap workflowYaml(String path) => loadYaml(read(path)) as YamlMap;

/// All `steps[]` of a job as typed maps.
List<YamlMap> jobSteps(String workflowPath, String jobId) {
  final jobs = workflowYaml(workflowPath)['jobs'] as YamlMap;
  return ((jobs[jobId] as YamlMap)['steps'] as YamlList)
      .whereType<YamlMap>()
      .toList();
}

const requiredAssets = <String>[
  'fa-extension.zip',
  'fa-linux-arm64.tar.gz',
  'fa-linux-x64.tar.gz',
  'fa-macos-arm64.tar.gz',
  'fa-macos-x64.tar.gz',
  'fa-web-spa.zip',
  'fa-windows-x64.zip',
];

const gateScript = 'scripts/assert_release_assets.sh';
const requiredList = 'scripts/release_required_assets.txt';

void main() {
  // ── 1. the single source of truth ───────────────────────────────────────
  group('gh-1832: required-assets list (single source of truth)', () {
    test('$requiredList exists and carries the v1.0.634 fa-* set', () {
      final lines = read(requiredList)
          .split('\n')
          .map((l) {
            final i = l.indexOf('#');
            return (i < 0 ? l : l.substring(0, i)).trim();
          })
          .where((l) => l.isNotEmpty)
          .toList();
      for (final asset in requiredAssets) {
        expect(lines, contains(asset),
            reason: '$requiredList must list $asset');
      }
      expect(lines.length, requiredAssets.length,
          reason: 'the list is the release gate — every entry must be a '
              'deliberate, named asset (no extras)');
    });

    test('every entry is a concrete fa-* archive name (no globs/junk)', () {
      final lines = read(requiredList)
          .split('\n')
          .map((l) {
            final i = l.indexOf('#');
            return (i < 0 ? l : l.substring(0, i)).trim();
          })
          .where((l) => l.isNotEmpty)
          .toList();
      for (final line in lines) {
        expect(RegExp(r'^fa-[a-z0-9.-]+\.(zip|tar\.gz)$').hasMatch(line), isTrue,
            reason: 'entry "$line" is not a literal asset name — the gate '
                'matches exact names, globs would silently pass');
      }
    });

    test('site/index.html links fa-extension.zip on the latest alias', () {
      expect(
        read('site/index.html'),
        contains(
            'https://github.com/IstiN/flutter_agent_harness/releases/latest/download/fa-extension.zip'),
        reason: 'the landing link is the smoke subject — if the page '
            'changes shape, the link-check contract must be revisited',
      );
    });
  });

  // ── 2. AC2: the publish point is gated ──────────────────────────────────
  group('gh-1832 AC2: release-provenance publish is asset-gated', () {
    final steps = jobSteps('.github/workflows/ci.yml', 'release-provenance');

    int stepIndex(bool Function(YamlMap) predicate, String what) {
      final i = steps.indexWhere(predicate);
      expect(i, isNonNegative, reason: 'ci.yml release-provenance lacks $what');
      return i;
    }

    test('a gate step invokes assert_release_assets.sh before the flip', () {
      final gate = stepIndex(
        (s) => s['run']?.toString().contains(gateScript) ?? false,
        'the required-assets gate step ($gateScript)',
      );
      final publish = stepIndex(
        (s) => s['run']?.toString().contains('--draft=false --latest') ?? false,
        'the --draft=false --latest publish flip',
      );
      expect(gate < publish, isTrue,
          reason: 'the gate MUST run before the publish flip — a missing '
              'asset must leave the release a draft (previous stays latest) '
              'and go red, never publish a partial release (gh-1832)');
    });

    test('the gate step reads the checked-in list via the script, not a '
        'private copy', () {
      final gate = steps
          .firstWhere((s) => s['run']?.toString().contains(gateScript) ?? false);
      expect(gate['run'].toString(), contains('assert_release_assets.sh'));
      // No inline asset enumeration in the step: the single source of
      // truth is the list file, consumed inside the script.
      for (final asset in requiredAssets) {
        expect(gate['run'].toString(), isNot(contains(asset)),
            reason: 'the gate step must not duplicate the asset list — '
                'keep the one list in $requiredList');
      }
    });
  });

  // ── 3. AC3: post-publish smoke job ──────────────────────────────────────
  group('gh-1832 AC3: release-asset-smoke job', () {
    final jobs = workflowYaml('.github/workflows/ci.yml')['jobs'] as YamlMap;
    final smoke = jobs['release-asset-smoke'] as YamlMap?;

    test('exists, needs release-provenance, and is tag-train-only', () {
      expect(smoke, isNotNull,
          reason: 'ci.yml must carry a release-asset-smoke job (gh-1832)');
      expect((smoke!['needs'] as YamlList).toList(), contains('release-provenance'));
      final cond = smoke['if'].toString();
      expect(cond, contains("startsWith(github.ref, 'refs/tags/v')"),
          reason: 'the smoke rides the tag train — PR runs must not probe '
              'release URLs');
    });

    test('probes BOTH the landing-page links and the full required set', () {
      final runs = (smoke!['steps'] as YamlList)
          .whereType<YamlMap>()
          .map((s) => s['run']?.toString() ?? '')
          .toList();
      expect(runs.any((r) => r.contains('--landing')), isTrue,
          reason: 'the landing page must gain a CI link-check over the '
              'release URLs it exposes (gh-1832 AC3)');
      expect(runs.any((r) => r.contains('--smoke')), isTrue,
          reason: 'the smoke must download the full required set, not only '
              'the links the landing page happens to expose');
    });

    test('smoke job checks out the repo (needs site/index.html + script)', () {
      final uses = (smoke!['steps'] as YamlList)
          .whereType<YamlMap>()
          .map((s) => s['uses']?.toString() ?? '')
          .toList();
      expect(uses.any((u) => u.startsWith('actions/checkout')), isTrue);
    });
  });

  // ── 4. behavioral: gate + smoke against stubbed gh / local HTTP ────────
  group('gh-1832 behavioral (stubbed gh, local HTTP)', () {
    late Directory root;
    late String bin;

    setUp(() {
      root = Directory.systemTemp.createTempSync('gh1832-gate-');
      bin = '${root.path}/bin';
      Directory(bin).createSync();
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    /// Run the gate script with a stubbed `gh` whose `release view --json
    /// assets --jq '.assets[].name'` prints [assets].
    ProcessResult runGate(List<String> assets) {
      final fixture = '${root.path}/assets.txt';
      File(fixture).writeAsStringSync(assets.isEmpty ? '' : '${assets.join('\n')}\n');
      File('$bin/gh').writeAsStringSync(
        '#!/usr/bin/env bash\n'
        'case "\$1 \$2" in\n'
        '  "release view") cat "\$FA_GH_ASSETS_FIXTURE" ;;\n'
        '  *) echo "unexpected gh call: \$*" >> "\$FA_GH_ASSETS_FIXTURE"; exit 64 ;;\n'
        'esac\n',
      );
      Process.runSync('chmod', ['+x', '$bin/gh']);
      return Process.runSync(
        'bash',
        [gateScript, 'v9.9.9'],
        environment: {
          'PATH': '$bin:${Platform.environment['PATH']}',
          'GITHUB_REPOSITORY': 'OWNER/REPO',
          'GH_TOKEN': 'stub',
          'FA_GH_ASSETS_FIXTURE': fixture,
        },
        includeParentEnvironment: false,
        workingDirectory: Directory.current.path,
      );
    }

    test('AC4 rehearsal: extension leg artificially absent → release blocked',
        () {
      final complete = [...requiredAssets]..remove('fa-extension.zip');
      final res = runGate(complete);
      final out = '${res.stdout}${res.stderr}';
      expect(res.exitCode, isNot(0),
          reason: 'a release missing fa-extension.zip must FAIL the gate '
              '(v1.0.635 published exactly this way)');
      expect(out, contains('fa-extension.zip'),
          reason: 'the gate must name the missing asset');
    });

    test('complete asset set passes the gate', () {
      final res = runGate(requiredAssets);
      expect(res.exitCode, 0,
          reason: '${res.stdout}${res.stderr}');
    });

    Future<HttpServer> bindServer(Map<String, int> statusByPath) async {
      final server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final status = statusByPath[req.uri.path] ?? 500;
        req.response.statusCode = status;
        req.response.add(Uint8List.fromList(const [0x50, 0x4b]));
        await req.response.close();
      });
      return server;
    }

    test('--smoke goes red on a 404 asset, green when all serve', () async {
      final server = await bindServer({
        for (final a in requiredAssets) '/OWNER/REPO/releases/download/v9.9.9/$a': 200,
      });
      final base = 'http://127.0.0.1:${server.port}';
      // Process.run (NOT runSync): the fixture HttpServer lives in THIS
      // isolate's event loop — a synchronous run would block accepts while
      // the script's curl waits, deadlocking to curl's --max-time.
      Future<ProcessResult> run(String tag) => Process.run(
            'bash',
            [gateScript, '--smoke', tag],
            environment: {
              'PATH': Platform.environment['PATH']!,
              'GITHUB_REPOSITORY': 'OWNER/REPO',
              'FA_RELEASE_DOWNLOAD_BASE': base,
            },
            includeParentEnvironment: false,
            workingDirectory: Directory.current.path,
          );
      expect((await run('v9.9.9')).exitCode, 0,
          reason: 'all assets serve → green');

      // Now fa-extension.zip 404s (the v1.0.635 condition).
      await server.close(force: true);
      final server2 = await bindServer({
        for (final a in requiredAssets)
          if (a != 'fa-extension.zip')
            '/OWNER/REPO/releases/download/v9.9.9/$a': 200,
        '/OWNER/REPO/releases/download/v9.9.9/fa-extension.zip': 404,
      });
      final res = await Process.run(
        'bash',
        [gateScript, '--smoke', 'v9.9.9'],
        environment: {
          'PATH': Platform.environment['PATH']!,
          'GITHUB_REPOSITORY': 'OWNER/REPO',
          'FA_RELEASE_DOWNLOAD_BASE': 'http://127.0.0.1:${server2.port}',
        },
        includeParentEnvironment: false,
        workingDirectory: Directory.current.path,
      );
      await server2.close(force: true);
      final out = '${res.stdout}${res.stderr}';
      expect(res.exitCode, isNot(0), reason: 'a 404 asset must go red');
      expect(out, contains('fa-extension.zip'));
    });

    test('--landing probes every release link on the page, red on 404',
        () async {
      final page = '${root.path}/landing.html';
      Future<HttpServer> serverWith(bool extension404) async {
        return bindServer({
          '/IstiN/flutter_agent_harness/releases/latest/download/fa-extension.zip':
              extension404 ? 404 : 200,
          '/IstiN/flutter_agent_harness/releases/download/v9.9.9/fa-web-spa.zip':
              200,
        });
      }

      var server = await serverWith(false);
      File(page).writeAsStringSync('<a class="btn" id="extension-download" '
          'href="http://127.0.0.1:${server.port}/IstiN/flutter_agent_harness/releases/latest/download/fa-extension.zip">'
          'Download</a> and '
          'href="http://127.0.0.1:${server.port}/IstiN/flutter_agent_harness/releases/download/v9.9.9/fa-web-spa.zip". '
          'Trailing-comma guard: .../fa-extension.zip,\n');
      // Async run — see the --smoke note: runSync starves the server.
      final res = await Process.run(
        'bash',
        [gateScript, '--landing', page],
        environment: {'PATH': Platform.environment['PATH']!},
        includeParentEnvironment: false,
        workingDirectory: Directory.current.path,
      );
      expect(res.exitCode, 0, reason: '${res.stdout}${res.stderr}');

      // Same page, but the extension link now 404s (v1.0.635 incident).
      await server.close(force: true);
      server = await serverWith(true);
      File(page).writeAsStringSync('<a href="http://127.0.0.1:${server.port}'
          '/IstiN/flutter_agent_harness/releases/latest/download/fa-extension.zip">d</a>\n');
      final res2 = await Process.run(
        'bash',
        [gateScript, '--landing', page],
        environment: {'PATH': Platform.environment['PATH']!},
        includeParentEnvironment: false,
        workingDirectory: Directory.current.path,
      );
      await server.close(force: true);
      expect(res2.exitCode, isNot(0),
          reason: 'a 404 landing link must go red (the owner-facing symptom)');
    });
  });
}
