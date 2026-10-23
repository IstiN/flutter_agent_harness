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
      'every lazy create routes through release_lazy_draft.sh (curated notes + ownership marker)',
      () {
        // Review threads 3/7 + 4/8: the inline `--draft --generate-notes`
        // creates (a) dropped the curated CHANGELOG notes contract and
        // (b) left drafts the ownership-scoped draft guard can never
        // reclaim. Both invariants live in the shared helper now.
        for (final wf in [
          '.github/workflows/ci.yml',
          '.github/workflows/build-macos.yml',
        ]) {
          expect(
            extractCreateCommands(read(wf)),
            isEmpty,
            reason:
                '$wf must not inline `gh release create` anymore — the lazy '
                'draft create lives in scripts/release_lazy_draft.sh '
                '(curated notes via release_notes.sh + the release-draft-owner '
                'marker), gh-1801 rework',
          );
          expect(read(wf), contains('release_lazy_draft.sh'));
        }
        final helper = read('scripts/release_lazy_draft.sh');
        expect(
          helper,
          contains('release_notes.sh'),
          reason:
              'the create body must fold the curated CHANGELOG section '
              '(release_notes.sh preference order) — --generate-notes '
              'permanently degraded the release notes on every train '
              '(review threads 3/7)',
        );
        expect(
          stripComments(helper),
          contains('--draft'),
          reason: 'a lazy create is draft-first — never publishes empty',
        );
        expect(
          stripComments(helper),
          isNot(contains('--latest')),
          reason: 'a lazy create never flags latest — provenance owns the flip',
        );
        expect(
          helper,
          contains('release-draft-owner: run/'),
          reason:
              'the draft body must stamp the ownership marker so the draft '
              'lifecycle guard can reclaim it on failure (review threads 4/8)',
        );
        expect(stripComments(helper), isNot(contains('--generate-notes')));
      },
    );

    test(
      'matrix lazy creates carry a leg-suffixed draft identity (sibling-safe guard)',
      () {
        // Matrix legs share GITHUB_JOB (binaries / build-macos-cli). A
        // guard keyed on run+job alone would let one failed leg delete a
        // SIBLING leg's mid-upload draft — the exact destruction the
        // ownership scoping (review of #294) was built to prevent.
        // RELEASE_DRAFT_IDENTITY rides the step env, so inspect the step
        // maps, not just the run bodies.
        Map<String, YamlMap> stepMaps(String workflowPath) {
          final steps = <String, YamlMap>{};
          (workflowYaml(workflowPath)['jobs'] as YamlMap).forEach((jobId, job) {
            for (final step in (job as YamlMap)['steps'] as YamlList) {
              if (step is YamlMap && step.containsKey('run')) {
                steps['$jobId/${step['name'] ?? '?'}'] = step;
              }
            }
          });
          return steps;
        }

        void expectLegIdentity(
          Map<String, YamlMap> steps,
          String jobPrefix,
          String wf,
        ) {
          final step = steps.entries.firstWhere(
            (e) =>
                e.key.startsWith(jobPrefix) &&
                e.value['run'].toString().contains('release_lazy_draft.sh'),
          );
          expect(
            step.value['env']?['RELEASE_DRAFT_IDENTITY']?.toString() ?? '',
            contains('matrix.'),
            reason:
                '$wf step "${step.key}": matrix legs must stamp a '
                'leg-suffixed draft identity (e.g. '
                '${step.key.split('/').first}-<leg>) — the failure-path '
                'guard is only sibling-safe at leg resolution',
          );
          final guard = steps.entries.firstWhere(
            (e) =>
                e.key.startsWith(jobPrefix) &&
                e.value['run'].toString().contains('release_draft_guard.sh'),
          );
          expect(
            guard.value['env']?['RELEASE_DRAFT_IDENTITY']?.toString() ?? '',
            contains('matrix.'),
            reason:
                '$wf guard step "${guard.key}" must carry the same '
                'leg-suffixed identity as the create step',
          );
        }

        expectLegIdentity(
          stepMaps('.github/workflows/ci.yml'),
          'binaries/',
          '.github/workflows/ci.yml',
        );
        expectLegIdentity(
          stepMaps('.github/workflows/build-macos.yml'),
          'build-macos-cli/',
          '.github/workflows/build-macos.yml',
        );
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
      // Command-level check (comments stripped — a comment may document
      // the provenance-owned flip without executing anything).
      final ciBlocks = runBlocks('.github/workflows/ci.yml');
      final spaStep = ciBlocks.entries
          .where((e) => stripComments(e.value).contains('fa-web-spa.zip'))
          .map((e) => stripComments(e.value))
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
          .where((e) => stripComments(e.value).contains('fa-extension.zip'))
          .map((e) => stripComments(e.value))
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

    test('AGENTS.md documents the provenance-owned release contract', () {
      // Review threads 3/7 + the summary's SUGESTION: the "Commits and
      // releases" paragraph must describe the implemented flow — tag-only
      // auto_release.sh, draft-first binaries create, provenance-owned
      // publish — never the retired "tag + GitHub Release" one-liner.
      final doc = read('AGENTS.md');
      expect(doc, contains('release_lazy_draft.sh'));
      expect(doc, contains('release-provenance'));
      expect(
        doc,
        isNot(contains('TAG + GitHub Release')),
        reason:
            'the retired tag+release one-liner contradicts the gh-1801 '
            'no-create contract (an asset-less create published an empty '
            'latest)',
      );
    });

    test(
      'attach-or-create: create is draft-only, the attach publish is SHA256SUMS-gated',
      () {
        // Review threads 2/6: the create path published `--latest` with
        // whatever the leg resolved (AAB/IPA/DMG/zip) and the attach path
        // published a sibling draft unconditionally — both can strand a
        // `latest` that cannot serve `fa update`. The create is draft-only
        // now and the re-asserted publish is gated on the release actually
        // carrying the signed checksums.
        final script = read('scripts/release_attach_or_create.sh');
        final creates = extractCreateCommands(script);
        expect(creates, hasLength(1));
        expect(
          creates.single,
          contains('--draft'),
          reason:
              'the daily legs must create the release as a DRAFT — publish '
              'belongs to the provenance step, never to a leg-resolved asset '
              'list (gh-1801 rework)',
        );
        expect(
          creates.single,
          isNot(contains('--latest')),
          reason:
              'a create with leg-resolved assets (AAB/IPA/DMG) must never '
              'carry the latest badge — latest moves only after the signed '
              'SHA256SUMS is on the release (gh-1801 threads 2/6)',
        );
        expect(
          script,
          contains('--draft=false --latest'),
          reason: 'the recovery publish (release already servable) stays',
        );
        expect(
          stripComments(script),
          contains('SHA256SUMS'),
          reason:
              'the attach publish must be gated on the release carrying '
              'SHA256SUMS — `fa update` aborts without the signed checksums',
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
          ghLog().where((l) => l.contains('release edit')),
          isEmpty,
          reason:
              'the simple logging stub answers no asset list — a release '
              'without provenance must NOT be published/latest by the attach '
              '(the rework behavioral group below covers the servable path)',
        );
      },
    );
  });

  // ── rework threads 1-4: behavioral (stateful stubbed gh) ────────────────
  group('gh-1801 rework behavioral: provenance-owned publish + guard-visible drafts', () {
    late Directory fx;
    late String bin;
    late String logPath;

    setUp(() {
      fx = Directory.systemTemp.createTempSync('gh1801-rework-');
      bin = '${fx.path}/bin';
      Directory(bin).createSync();
      logPath = '${fx.path}/gh.log';
      File('$bin/gh').writeAsStringSync(_reworkGhStub);
      Process.runSync('chmod', ['+x', '$bin/gh']);
    });

    tearDown(() {
      fx.deleteSync(recursive: true);
    });

    /// Plant a fixture file inside the stub state dir.
    void plant(String name, String content) =>
        File('${fx.path}/$name').writeAsStringSync(content);

    Map<String, String> env({Map<String, String> extra = const {}}) => {
      'PATH': '$bin:${Platform.environment['PATH']}',
      'FA_GH_DIR': fx.path,
      'FA_GH_LOG': logPath,
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GITHUB_RUN_ID': '222',
      'GITHUB_JOB': 'release-macos',
      'GH_TOKEN': 'stub',
      ...extra,
    };

    ProcessResult runScript(String script, List<String> args) =>
        Process.runSync(
          'bash',
          [script, ...args],
          workingDirectory: fx.path,
          environment: env(),
          includeParentEnvironment: true,
        );

    List<String> ghLog() =>
        File(logPath).existsSync() ? File(logPath).readAsLinesSync() : const [];

    test(
      'release_lazy_draft.sh: draft-first, curated notes + owner marker, never latest',
      () {
        plant('CHANGELOG.md', '## Unreleased\n- curated entry one\n');
        final r = runScript(
          '${Directory.current.path}/scripts/release_lazy_draft.sh',
          ['v1.2.3'],
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final creates = ghLog()
            .where((l) => l.contains('release create'))
            .toList();
        expect(creates, hasLength(1));
        expect(creates.single, contains('--draft'), reason: 'draft-first');
        expect(creates.single, contains('--title v1.2.3'));
        expect(
          creates.single,
          isNot(contains('--latest')),
          reason: 'a lazy create never flags latest — provenance owns the flip',
        );
        final notes = File(
          '${fx.path}/last-create-notes.md',
        ).readAsStringSync();
        expect(
          notes,
          contains('curated entry one'),
          reason:
              'the curated CHANGELOG section reaches the release body (threads 3/7)',
        );
        expect(
          notes,
          contains('release-draft-owner: run/222/job/release-macos'),
          reason:
              'the draft body stamps the owner so the guard can reclaim it (threads 4/8)',
        );
      },
    );

    test(
      'release_lazy_draft.sh: release already exists → no create, exit 0',
      () {
        plant('release-exists', '');
        final r = runScript(
          '${Directory.current.path}/scripts/release_lazy_draft.sh',
          ['v1.2.3'],
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(ghLog().where((l) => l.contains('release create')), isEmpty);
      },
    );

    test(
      'release_lazy_draft.sh: malformed RELEASE_DRAFT_IDENTITY fails loud',
      () {
        plant('CHANGELOG.md', '## Unreleased\n- curated entry one\n');
        final r = Process.runSync(
          'bash',
          ['${Directory.current.path}/scripts/release_lazy_draft.sh', 'v1.2.3'],
          workingDirectory: fx.path,
          environment: env(extra: {'RELEASE_DRAFT_IDENTITY': 'job/binaries'}),
          includeParentEnvironment: true,
        );
        expect(
          r.exitCode,
          isNot(0),
          reason: 'an unmatchable marker would orphan the draft forever',
        );
        expect('${r.stdout}${r.stderr}', contains('RELEASE_DRAFT_IDENTITY'));
      },
    );

    test(
      'attach path: release without SHA256SUMS → upload only, publish left to provenance',
      () {
        plant('view-seq.txt', 'exists\n');
        plant('asset-names.txt', 'Fa-macos-arm64.dmg\nfa-web-spa.zip\n');
        final asset = '${fx.path}/a.zip';
        File(asset).writeAsStringSync('asset');
        final r = runScript(
          '${Directory.current.path}/scripts/release_attach_or_create.sh',
          ['v1.2.3', asset],
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(
          ghLog(),
          contains('release upload v1.2.3 $asset --clobber --repo OWNER/REPO'),
        );
        expect(
          ghLog().where((l) => l.contains('release edit')),
          isEmpty,
          reason:
              'a release without the signed checksums cannot serve `fa update` '
              '— publishing it as latest here recreates the incident window '
              '(gh-1801 threads 1/5, 2/6)',
        );
      },
    );

    test(
      'attach path: release already carrying SHA256SUMS → recovery publish + latest',
      () {
        // Provenance landed (servable) but its own flip failed / a draft
        // was left behind — the attach may recover it: publish + latest is
        // safe exactly when the release can serve `fa update`.
        plant('view-seq.txt', 'exists\n');
        plant(
          'asset-names.txt',
          'fa-linux-x64.tar.gz\nSHA256SUMS\nSHA256SUMS.sig\n',
        );
        final asset = '${fx.path}/a.zip';
        File(asset).writeAsStringSync('asset');
        final r = runScript(
          '${Directory.current.path}/scripts/release_attach_or_create.sh',
          ['v1.2.3', asset],
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(
          ghLog(),
          contains(
            'release edit v1.2.3 --draft=false --latest --repo OWNER/REPO',
          ),
          reason:
              'a servable release (signed checksums on board) may be published + flagged latest',
        );
      },
    );

    test(
      'create path: draft-only create, ownership marker, never --latest',
      () {
        plant('view-seq.txt', 'missing\n');
        plant('release-notes.md', 'leg notes\n');
        final asset = '${fx.path}/a.ab';
        File(asset).writeAsStringSync('aab');
        final r = runScript(
          '${Directory.current.path}/scripts/release_attach_or_create.sh',
          ['v1.2.3', asset],
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        final creates = ghLog()
            .where((l) => l.contains('release create'))
            .toList();
        expect(creates, hasLength(1));
        expect(
          creates.single,
          contains('--draft'),
          reason: 'the leg create is draft-only',
        );
        expect(
          creates.single,
          isNot(contains('--latest')),
          reason: 'gh-1801 threads 2/6: a leg create never publishes/latest',
        );
        expect(
          creates.single,
          contains('a.ab'),
          reason: 'assets ride the create command',
        );
        final notes = File(
          '${fx.path}/last-create-notes.md',
        ).readAsStringSync();
        expect(notes, contains('leg notes'));
        expect(
          notes,
          contains('release-draft-owner: run/222/job/release-macos'),
        );
      },
    );

    test(
      'draft guard: RELEASE_DRAFT_IDENTITY match deletes the leg-stamped draft',
      () {
        plant('draft-state.txt', 'true');
        plant(
          'release-body.txt',
          '<!-- release-draft-owner: run/222/job/binaries-linux-x64 -->\n',
        );
        final r = Process.runSync(
          'bash',
          [
            '${Directory.current.path}/scripts/release_draft_guard.sh',
            'v1.2.3',
          ],
          workingDirectory: fx.path,
          environment: env(
            extra: {
              'GITHUB_JOB': 'binaries',
              'RELEASE_DRAFT_IDENTITY': 'run/222/job/binaries-linux-x64',
            },
          ),
          includeParentEnvironment: true,
        );
        expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');
        expect(
          ghLog(),
          contains('release delete v1.2.3 --repo OWNER/REPO --yes'),
        );
      },
    );

    test(
      'draft guard: sibling leg identity never deletes (refuses, exit 0)',
      () {
        plant('draft-state.txt', 'true');
        plant(
          'release-body.txt',
          '<!-- release-draft-owner: run/222/job/binaries-linux-x64 -->\n',
        );
        final r = Process.runSync(
          'bash',
          [
            '${Directory.current.path}/scripts/release_draft_guard.sh',
            'v1.2.3',
          ],
          workingDirectory: fx.path,
          environment: env(
            extra: {
              'GITHUB_JOB': 'binaries',
              'RELEASE_DRAFT_IDENTITY': 'run/222/job/binaries-macos-x64',
            },
          ),
          includeParentEnvironment: true,
        );
        expect(r.exitCode, 0);
        expect(
          ghLog().where((l) => l.contains('release delete')),
          isEmpty,
          reason:
              'a failed leg must never delete a sibling leg\'s in-flight draft',
        );
        expect('${r.stdout}${r.stderr}', contains('refusing to delete'));
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

/// Stateful gh stub for the rework behavioral group. State lives in
/// $FA_GH_DIR:
///  - view-seq.txt        one exists|missing word per view call (popped)
///  - release-exists      permanent "the release exists" verdict
///  - asset-names.txt     the release's asset names, one per line
///  - draft-state.txt     the --json isDraft answer (true/false)
///  - release-body.txt    the --json body answer
///  - create-fails        makes `release create` exit 1 (race simulation)
///  - last-create-notes.md captures the --notes-file payload
const String _reworkGhStub = '''
#!/usr/bin/env bash
echo "\$*" >> "\$FA_GH_LOG"
case "\$1 \$2" in
  "release view")
    # Structured queries (--json) are reads, not the exists-check — answer
    # them before the view-seq sequencing (the attach path queries the
    # asset list of a release it has already confirmed exists).
    case "\$*" in
      *"--json isDraft"*) cat "\$FA_GH_DIR/draft-state.txt" 2>/dev/null || echo "false"; exit 0 ;;
      *"--json body"*) cat "\$FA_GH_DIR/release-body.txt" 2>/dev/null || echo ""; exit 0 ;;
      *"--json assets"*) cat "\$FA_GH_DIR/asset-names.txt" 2>/dev/null || echo ""; exit 0 ;;
    esac
    if [ -f "\$FA_GH_DIR/view-seq.txt" ]; then
      w=\$(head -1 "\$FA_GH_DIR/view-seq.txt")
      sed -i.bak '1d' "\$FA_GH_DIR/view-seq.txt" && rm -f "\$FA_GH_DIR/view-seq.txt.bak"
      [ "\$w" = "exists" ] && exit 0
      echo "release not found (stub)" >&2
      exit 1
    fi
    [ -f "\$FA_GH_DIR/release-exists" ] && exit 0
    echo "release not found (stub)" >&2
    exit 1
    ;;
  "release create")
    if [ -f "\$FA_GH_DIR/create-fails" ]; then
      echo "gh: HTTP 422: Reference already exists (stub: lost the create race)" >&2
      exit 1
    fi
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--notes-file" ]; then
        cp "\$2" "\$FA_GH_DIR/last-create-notes.md" 2>/dev/null || true
      fi
      shift
    done
    touch "\$FA_GH_DIR/release-exists"
    exit 0
    ;;
esac
exit 0
''';
