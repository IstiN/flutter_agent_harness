// gh-1801 regression guards: (1) the build-mobile concurrency group must
// carry the leg/content discriminator (Play = android-only vs TestFlight =
// iOS-only dispatches must never share a cancel domain), and (2) no step in
// the release train may PUBLISH a GitHub release without assets — an empty
// `latest` release is the `fa update` HTTP-404 breaker (v1.0.630 window,
// 2026-10-23). Static workflow/script lint + behavioral shell-harness of
// auto_release.sh and release_attach_or_create.sh against a stubbed `gh`
// (same style as release_hygiene_test.dart / release_flow_race_test.dart).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

YamlMap workflowYaml(String path) => loadYaml(read(path)) as YamlMap;

/// Strip `-` comments so a comment mentioning a command never matches.
String stripComments(String text) => text
    .split('\n')
    .map((l) {
      final i = l.indexOf('#');
      return i < 0 ? l : l.substring(0, i);
    })
    .join('\n');

/// Every `gh release create ...` command (backslash continuations joined),
/// one entry per command, comments stripped.
List<String> extractCreateCommands(String text) {
  final lines = stripComments(text).split('\n');
  final cmds = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (!RegExp(r'gh\s+release\s+create\b').hasMatch(lines[i])) continue;
    final parts = <String>[lines[i]];
    while (parts.last.trimRight().endsWith(r'\') && i < lines.length - 1) {
      i++;
      parts.add(lines[i]);
    }
    cmds.add(parts.map((p) => p.replaceAll(r'\', ' ').trim()).join(' ').trim());
  }
  return cmds;
}

/// All `steps[].run` bodies of a workflow keyed by `jobs.<id>.<name>`.
Map<String, String> runBlocks(String workflowPath) {
  final jobs = workflowYaml(workflowPath)['jobs'] as YamlMap;
  final blocks = <String, String>{};
  jobs.forEach((jobId, job) {
    for (final step in (job as YamlMap)['steps'] as YamlList) {
      if (step is YamlMap && step.containsKey('run')) {
        blocks['$jobId/${step['name'] ?? '?'}'] = step['run'].toString();
      }
    }
  });
  return blocks;
}

void main() {
  // ── AC-3 REG: build-mobile concurrency discriminator ────────────────────
  group('gh-1801 AC-3: build-mobile concurrency key', () {
    final y = workflowYaml('.github/workflows/build-mobile.yml');
    final concurrency = y['concurrency'] as YamlMap;
    final group = concurrency['group'].toString();

    test('the group carries the leg/content discriminator', () {
      expect(
        group,
        contains('inputs.android_content'),
        reason:
            'the Play (android-only) and TestFlight (iOS-only) dispatches '
            'must never resolve into one cancel domain — the key must '
            'include the leg/content selection (gh-1801)',
      );
      expect(group, contains('inputs.ios_content'));
    });

    test(
      'the group stays per-dispatch (run_id) and never cancels in progress',
      () {
        expect(
          group,
          contains('github.run_id'),
          reason:
              '#351: every dispatch is its own group — no run may cancel '
              'or queue behind another',
        );
        expect(
          concurrency['cancel-in-progress'].toString(),
          'false',
          reason: 'self-cancel is forbidden (gh-1801 Bug 1)',
        );
      },
    );
  });

  // ── AC-2 REG: a leg whose content jobs all skipped creates no release ───
  group('gh-1801 AC-2: release-mobile never runs with zero artifacts', () {
    final blocks = runBlocks('.github/workflows/build-mobile.yml');

    test(
      'the create/attach step routes through release_attach_or_create.sh',
      () {
        final releaseStep = blocks.entries
            .firstWhere(
              (e) => e.value.contains('release_attach_or_create.sh'),
              orElse: () => throw TestFailure(
                'release-mobile must route through release_attach_or_create.sh',
              ),
            )
            .value;
        expect(releaseStep, contains('ASSETS'));
      },
    );

    test(
      'artifact download and release steps are gated on success, never skip',
      () {
        final jobs =
            workflowYaml('.github/workflows/build-mobile.yml')['jobs']
                as YamlMap;
        final steps = (jobs['release-mobile'] as YamlMap)['steps'] as YamlList;
        for (final step in steps.whereType<YamlMap>()) {
          final name = step['name']?.toString() ?? '';
          final isArtifactStep = (step['uses']?.toString() ?? '').startsWith(
            'actions/download-artifact',
          );
          final isReleaseStep =
              step['run']?.toString() ==
              blocks.entries
                  .firstWhere(
                    (e) => e.value.contains('release_attach_or_create'),
                  )
                  .value;
          if (!isArtifactStep && !isReleaseStep) continue;
          expect(
            step['if']?.toString() ?? '',
            contains("== 'success'"),
            reason:
                '"$name" must run only when its build job SUCCEEDED — gating '
                "on 'skipped' would let an all-skipped leg reach the release "
                'create with zero artifacts (gh-1801 AC-2)',
          );
        }
      },
    );
  });

  // ── Bug 2 REG: no empty latest release ──────────────────────────────────
  group('gh-1801: no release may be published without assets', () {
    test(
      'auto_release.sh creates NO release (zero resolved assets → hard skip)',
      () {
        final script = read('scripts/auto_release.sh');
        expect(
          extractCreateCommands(script),
          isEmpty,
          reason:
              'auto_release.sh resolves an EMPTY asset list — creating there '
              'publishes an empty latest release and `fa update` 404s until '
              'the tag-run binaries job backfills (v1.0.630, 2026-10-23). '
              'The tag-run binaries job owns release creation.',
        );
      },
    );

    test(
      'every lazy create in the train is draft-first (never publishes empty)',
      () {
        for (final wf in [
          '.github/workflows/ci.yml',
          '.github/workflows/build-macos.yml',
        ]) {
          final creates = extractCreateCommands(read(wf));
          expect(
            creates,
            isNotEmpty,
            reason: '$wf should still create releases',
          );
          for (final c in creates) {
            expect(
              c,
              contains('--draft'),
              reason:
                  '$wf: `gh release create` without --draft publishes '
                  'immediately with zero assets — the empty-latest class '
                  '(gh-1801). Create as a draft; publish after the upload.',
            );
            expect(c, contains('--title'));
          }
        }
      },
    );

    test(
      'publish (--draft=false) happens ONLY in steps that upload SHA256SUMS',
      () {
        // Review threads 1/5: the CLI asset is NOT the servability bar —
        // `fa update` hard-fails without the SIGNED SHA256SUMS(.sig)
        // (bin/self_manage.dart provenance gate), which only the
        // release-provenance job uploads (needs the whole matrix +
        // web-spa). A publish keyed on the first CLI upload recreates the
        // incident window: latest points at a release every `fa update`
        // aborts on, for all platforms, until provenance lands.
        for (final wf in [
          '.github/workflows/ci.yml',
          '.github/workflows/build-macos.yml',
        ]) {
          runBlocks(wf).forEach((name, body) {
            final stripped = stripComments(body);
            if (!stripped.contains('--draft=false')) return;
            expect(
              stripped,
              contains('SHA256SUMS'),
              reason:
                  '$wf step "$name": --draft=false (publish + latest) may '
                  'only ride the step that uploads the signed SHA256SUMS — '
                  'that is the first moment the release can actually serve '
                  '`fa update` (gh-1801 rework)',
            );
          });
        }
      },
    );

    test('release-provenance owns the publish flip after signing', () {
      final prov =
          workflowYaml('.github/workflows/ci.yml')['jobs']['release-provenance']
              as YamlMap;
      expect(
        (prov['needs'] as YamlList).map((e) => e.toString()),
        containsAll(['binaries', 'web-spa']),
        reason:
            'the flip may only fire after EVERY fa-* asset (full matrix + '
            'web-spa) is on the release',
      );
      final uploadStep = (prov['steps'] as YamlList)
          .whereType<YamlMap>()
          .firstWhere((s) => s['name'] == 'Upload provenance assets');
      final body = stripComments(uploadStep['run'].toString());
      expect(body, contains('gh release upload'));
      expect(body, contains('SHA256SUMS'));
      expect(
        body,
        contains('--draft=false --latest'),
        reason:
            'the provenance upload step is the single publish point: it runs '
            'after all CLI assets AND the signed checksums landed — a red '
            'provenance leaves the previous release as latest instead of '
            'stranding a provenance-less one (gh-1801 rework)',
      );
    });

    test('web-spa / extension uploads never publish the release', () {
      final ciBlocks = runBlocks('.github/workflows/ci.yml');
      final spaStep = ciBlocks.entries
          .where((e) => e.value.contains('fa-web-spa.zip'))
          .map((e) => e.value)
          .toList();
      expect(spaStep, isNotEmpty);
      for (final body in spaStep) {
        expect(
          body,
          isNot(contains('--draft=false')),
          reason:
              'the web zip is not a CLI asset — it must never publish '
              'the release it rides (gh-1801)',
        );
      }
      final macBlocks = runBlocks('.github/workflows/build-macos.yml');
      final extStep = macBlocks.entries
          .where((e) => e.value.contains('fa-extension.zip'))
          .map((e) => e.value)
          .toList();
      expect(extStep, isNotEmpty);
      for (final body in extStep) {
        expect(
          body,
          isNot(contains('--draft=false')),
          reason:
              'the extension zip is not a CLI asset — it must never '
              'publish the release it rides (gh-1801)',
        );
      }
    });

    test(
      'attach-or-create re-asserts draft=false+latest on the attach path',
      () {
        final script = read('scripts/release_attach_or_create.sh');
        expect(
          script,
          contains(RegExp(r'gh release edit "\$tag" --draft=false --latest')),
          reason:
              'attaching to an existing release must leave it published and '
              'latest — a sibling-created DRAFT must be published by the '
              'attach, never left invisible (gh-1801)',
        );
      },
    );
  });

  // ── behavioral: auto_release.sh never calls `gh release create` ─────────
  group('gh-1801 behavioral (stubbed gh, fixture git)', () {
    late Directory root;
    late String origin;
    late String seed;
    late String ghLogPath;
    final realGit = _resolveRealGit();

    setUp(() {
      root = Directory.systemTemp.createTempSync('gh1801-autorelease-');
      origin = '${root.path}/origin.git';
      seed = '${root.path}/seed';
      final bin = '${root.path}/bin';
      Directory(bin).createSync();
      ghLogPath = '${root.path}/gh.log';

      // gh stub: log + exit 0 (any create would land in the log).
      File('$bin/gh').writeAsStringSync(
        '#!/usr/bin/env bash\necho "\$*" >> "\$FA_GH_LOG"\nexit 0\n',
      );
      // git shim → real binary (session PATH may carry push-guard shims).
      File(
        '$bin/git',
      ).writeAsStringSync('#!/usr/bin/env bash\nexec "$realGit" "\$@"\n');
      for (final f in ['$bin/gh', '$bin/git']) {
        Process.runSync('chmod', ['+x', f]);
      }

      void git(List<String> args, {Map<String, String> env = const {}}) {
        final r = Process.runSync(
          realGit,
          args,
          workingDirectory: seed,
          environment: env,
          includeParentEnvironment: true,
        );
        expect(r.exitCode, 0, reason: 'fixture git $args: ${r.stderr}');
      }

      Process.runSync(realGit, ['init', '-q', '--bare', '-b', 'main', origin]);
      Process.runSync(realGit, ['clone', '-q', origin, seed]);
      git(['config', 'user.email', 't@t']);
      git(['config', 'user.name', 't']);
      File('$seed/README.md').writeAsStringSync('seed\n');
      git(['add', '-A']);
      git(
        ['commit', '-q', '-m', 'seed'],
        env: {
          'GIT_COMMITTER_DATE':
              (DateTime.now()
                          .subtract(const Duration(hours: 3))
                          .millisecondsSinceEpoch ~/
                      1000)
                  .toString(),
        },
      );
      git(
        ['tag', '-a', 'v0.1.495', '-m', 'Release v0.1.495'],
        env: {
          'GIT_COMMITTER_DATE':
              (DateTime.now()
                          .subtract(const Duration(hours: 3))
                          .millisecondsSinceEpoch ~/
                      1000)
                  .toString(),
        },
      );
      File('$seed/README.md').writeAsStringSync('pending\n');
      git(['add', '-A']);
      git(['commit', '-q', '-m', 'pending work']);
      git(['push', '-q', 'origin', 'main']);
      git(['push', '-q', 'origin', 'v0.1.495']);
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    List<String> ghLog() => File(ghLogPath).existsSync()
        ? File(ghLogPath).readAsLinesSync()
        : const [];

    test(
      'auto_release.sh pushes the next annotated tag and never creates a release',
      () {
        final res = Process.runSync(
          'bash',
          ['${Directory.current.path}/scripts/auto_release.sh'],
          workingDirectory: seed,
          environment: {
            for (final e in Platform.environment.entries)
              if (!e.key.startsWith('GIT_')) e.key: e.value,
            'PATH': '${root.path}/bin:${Platform.environment['PATH']}',
            'FA_GH_LOG': ghLogPath,
            'GITHUB_REPOSITORY': 'OWNER/REPO',
            'GH_TOKEN': 'stub',
          },
          includeParentEnvironment: false,
        );
        final out = '${res.stdout}${res.stderr}';
        expect(res.exitCode, 0, reason: out);

        // The release train still moves: v0.1.496 cut + pushed, annotated.
        final tagSha = Process.runSync(realGit, [
          '--git-dir',
          origin,
          'rev-parse',
          '-q',
          '--verify',
          'refs/tags/v0.1.496',
        ]);
        expect(tagSha.exitCode, 0, reason: 'the next tag must still be pushed');
        expect(
          Process.runSync(realGit, [
            '--git-dir',
            origin,
            'for-each-ref',
            '--format=%(objecttype)',
            'refs/tags/v0.1.496',
          ]).stdout.toString().trim(),
          'tag',
          reason:
              'the cut tag stays ANNOTATED — a lightweight API tag fires '
              'no tag CI (issue #597 class)',
        );

        // THE regression: no release create from the empty-asset path.
        expect(
          ghLog().where((l) => l.contains('release create')),
          isEmpty,
          reason:
              'auto_release.sh must refuse to create a release with zero '
              'resolved assets — the empty latest release is the fa update '
              'breaker (gh-1801)',
        );
      },
    );

    test(
      'release_attach_or_create.sh with zero assets refuses (hard fail, no create)',
      () {
        final bin = '${root.path}/bin';
        final res = Process.runSync(
          'bash',
          [
            '${Directory.current.path}/scripts/release_attach_or_create.sh',
            'v1.2.3',
          ],
          workingDirectory: seed,
          environment: {
            for (final e in Platform.environment.entries)
              if (!e.key.startsWith('GIT_')) e.key: e.value,
            'PATH': '$bin:${Platform.environment['PATH']}',
            'FA_GH_LOG': ghLogPath,
            'GITHUB_REPOSITORY': 'OWNER/REPO',
            'GITHUB_RUN_ID': '111',
            'GITHUB_JOB': 'release-mobile',
            'GH_TOKEN': 'stub',
          },
          includeParentEnvironment: false,
        );
        expect(
          res.exitCode,
          isNot(0),
          reason:
              'zero resolved assets must be a loud refusal — a silent '
              'pass would leave the release missing entirely',
        );
        expect(
          '${res.stderr}',
          contains('no assets'),
          reason: 'the refusal must name the empty asset list',
        );
        expect(
          ghLog().where((l) => l.contains('release create')),
          isEmpty,
          reason:
              'the refusal must happen BEFORE any create — an empty '
              'latest release is the fa update breaker (gh-1801)',
        );
      },
    );

    test(
      'release_attach_or_create.sh attach path publishes draft + asserts latest',
      () {
        final bin = '${root.path}/bin';
        final asset = '$seed/a.zip';
        File(asset).writeAsStringSync('asset');
        final res = Process.runSync(
          'bash',
          [
            '${Directory.current.path}/scripts/release_attach_or_create.sh',
            'v1.2.3',
            asset,
          ],
          workingDirectory: seed,
          environment: {
            for (final e in Platform.environment.entries)
              if (!e.key.startsWith('GIT_')) e.key: e.value,
            'PATH': '$bin:${Platform.environment['PATH']}',
            'FA_GH_LOG': ghLogPath,
            'GITHUB_REPOSITORY': 'OWNER/REPO',
            'GITHUB_RUN_ID': '111',
            'GITHUB_JOB': 'release-mobile',
            'GH_TOKEN': 'stub',
          },
          includeParentEnvironment: false,
        );
        final out = '${res.stdout}${res.stderr}';
        expect(res.exitCode, 0, reason: out);
        expect(
          ghLog(),
          contains(
            'release edit v1.2.3 --draft=false --latest --repo OWNER/REPO',
          ),
          reason:
              'attaching must end with the release published and latest '
              '(a sibling-created draft is published by the attach, gh-1801)',
        );
      },
    );
  });
}

/// The real git binary: skip session shims (git-push-guard.sh) on PATH.
String _resolveRealGit() {
  for (final dir in (Platform.environment['PATH'] ?? '').split(':')) {
    if (dir.isEmpty) continue;
    final cand = '$dir/git';
    if (!File(cand).existsSync()) continue;
    final resolved = File(cand).resolveSymbolicLinksSync();
    if (resolved.endsWith('git-push-guard.sh')) continue;
    return resolved;
  }
  return '/usr/bin/git';
}
