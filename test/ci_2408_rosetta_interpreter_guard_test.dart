// gh-2408 — v1.0.775 release run red: `arch -x86_64` must never
// PATH-resolve a native (ARM-only) interpreter on the self-hosted
// macos-m5 pool.
//
// The #2405 macOS-runner migration routes the x64 macOS CLI legs to the
// self-hosted pool, where PATH prefers Homebrew's /opt/homebrew/bin — an
// ARM64-only bash. The fa-clip step invoked `arch -x86_64 bash ...`; arch
// resolved that bash via PATH and posix_spawnp refused it as x86_64
// (`arch: posix_spawnp: bash: Bad CPU type in executable`, run 45524011164,
// job 138910839290). The whole x64 leg — and with it release-provenance
// (no signed SHA256SUMS) and the fail-closed vpinned marker advance — went
// red on a step that used to pass on the hosted macos-15-intel runners,
// where PATH resolved to the universal /bin/bash.
//
// Static workflow-shape asserts (the workflow_fetch_shape_guard_test.dart /
// ci_1596 pattern), repo-wide:
//
//   AC1  every `arch -x86_64 <cmd>` invocation in every workflow targets
//        either (a) an ABSOLUTE path (the caller took responsibility for a
//        universal/x86_64 binary — `/bin/bash` ships universal on every
//        supported macOS) or (b) the bare `dart` — safe because every job
//        that runs `arch -x86_64 dart` installs the exact-arch SDK via
//        dart-lang/setup-dart `architecture:` (AC2 pins that pairing).
//   AC2  every job invoking `arch -x86_64 dart` carries a setup-dart step
//        with an explicit `architecture:` — without it the bare-dart
//        exemption in AC1 would resolve the host's arm64 dart and fail the
//        same "Bad CPU type" way.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

/// `arch -x86_64 <cmd>` occurrences in a line of a step script. Deliberately
/// UNANCHORED (gh-2409 review thread 2): compound-command forms
/// (`cd x && arch -x86_64 bash ...`, `out=$(arch -x86_64 bash ...)`,
/// `sudo arch -x86_64 bash ...`) PATH-resolve the same way, and comment
/// lines are already skipped before matching — a stray false positive in a
/// guard test is cheap, a missed violation reintroduces gh-2408.
final rosettaCommand = RegExp(r'arch -x86_64 (\S+)');

/// Commands exempt from the absolute-path rule: setup-dart installs the
/// exact-arch SDK, so the bare name IS the x86_64 binary (AC2 keeps this
/// exemption honest).
const archExactSdkCommands = {'dart'};

/// Every `arch -x86_64 <cmd>` line in every run-step of the workflow.
/// Returns (job, step, command, line) tuples.
List<(String, String, String, String)> rosettaInvocations(String workflowPath) {
  final hits = <(String, String, String, String)>[];
  final jobs = jobsOf(workflowPath);
  for (final jobEntry in jobs.entries) {
    final steps = (jobEntry.value as YamlMap)['steps'] as YamlList?;
    if (steps == null) continue;
    for (final step in steps.whereType<YamlMap>()) {
      final run = step['run']?.toString();
      if (run == null) continue;
      for (final line in run.split('\n')) {
        final trimmed = line.trimLeft();
        if (trimmed.startsWith('#')) continue;
        final m = rosettaCommand.firstMatch(trimmed);
        if (m != null) {
          hits.add((
            jobEntry.key.toString(),
            step['name']?.toString() ?? '<unnamed>',
            m.group(1)!,
            line.trim(),
          ));
        }
      }
    }
  }
  return hits;
}

/// Jobs in the workflow whose run-steps invoke `arch -x86_64 dart`,
/// derived per-line from [rosettaInvocations]. AC2 must NOT scan whole
/// multi-line scripts with [rosettaCommand]: `^` without `multiLine:` only
/// matches at string start, so comment-first scripts (every script in this
/// repo) were invisible, the group registered zero tests, and a missing
/// setup-dart `architecture:` pin stayed green (gh-2409 review thread 1).
Set<String> rosettaDartJobs(String workflowPath) => rosettaInvocations(
  workflowPath,
).where((inv) => inv.$3 == 'dart').map((inv) => inv.$1).toSet();

/// True when any top-level job step is a dart-lang/setup-dart use carrying
/// an explicit `architecture:` pin — the pairing AC2 requires for the
/// bare-`dart` exemption in AC1.
bool hasSetupDartArchPin(YamlList steps) => steps.whereType<YamlMap>().any(
  (s) =>
      s['uses']?.toString().startsWith('dart-lang/setup-dart') == true &&
      (s['with'] as YamlMap?)?.containsKey('architecture') == true,
);

void main() {
  final workflowPaths =
      Directory('.github/workflows')
          .listSync()
          .where((f) => f.path.endsWith('.yml'))
          .map((f) => f.path)
          .toList()
        ..sort();

  group('AC1 — Rosetta invocations never PATH-resolve a native command', () {
    test(
      'the repo still exercises the Rosetta path (guard stays meaningful)',
      () {
        final all = [
          for (final path in workflowPaths) ...rosettaInvocations(path),
        ];
        expect(
          all,
          isNotEmpty,
          reason:
              'the x64 macOS CLI legs must keep building under Rosetta '
              '(#2405) — if every `arch -x86_64` line disappeared this guard '
              'is dead weight and should be revisited',
        );
      },
    );

    for (final path in workflowPaths) {
      final invocations = rosettaInvocations(path);
      if (invocations.isEmpty) continue;
      test('${path.split('/').last}: every arch -x86_64 target is safe', () {
        for (final (job, step, cmd, line) in invocations) {
          final safe =
              cmd.startsWith('/') || archExactSdkCommands.contains(cmd);
          expect(
            safe,
            isTrue,
            reason:
                '$path job "$job" step "$step" runs `$line` — `arch -x86_64 '
                '$cmd` resolves $cmd via PATH, and on the self-hosted '
                'macos-m5 pool PATH prefers the ARM64-only Homebrew '
                'binaries (`posix_spawnp: $cmd: Bad CPU type in executable`, '
                'gh-2408 / run 45524011164). Use an absolute path to a '
                'universal binary (e.g. `/bin/bash`) or a command installed '
                'as the exact arch (dart via setup-dart architecture:).',
          );
        }
      });
    }

    test(
      'regression pin: the fa-clip x64 legs use the universal /bin/bash',
      () {
        // The exact step class that went red on v1.0.775.
        final expected = <String, RegExp>{
          '.github/workflows/ci.yml': RegExp(
            r'arch -x86_64 /bin/bash scripts/build_fa_clip\.sh '
            r'build/out/bundle/bin/fa-clip',
          ),
          '.github/workflows/build-macos.yml': RegExp(
            r'arch -x86_64 /bin/bash scripts/build_fa_clip\.sh '
            r'build/out/bundle/bin/fa-clip',
          ),
        };
        for (final entry in expected.entries) {
          expect(
            read(entry.key),
            matches(entry.value),
            reason:
                '${entry.key} must invoke the fa-clip build under Rosetta '
                'with the universal /bin/bash — a bare `bash` resolves to '
                'the ARM-only Homebrew bash on macos-m5 and dies with '
                '`Bad CPU type in executable` (gh-2408)',
          );
          expect(
            read(entry.key),
            isNot(contains('arch -x86_64 bash scripts/build_fa_clip.sh')),
            reason:
                'the PATH-resolved form must be gone from ${entry.key} '
                '(gh-2408)',
          );
        }
      },
    );
  });

  group('AC2 — the bare-dart exemption stays paired with setup-dart arch', () {
    for (final path in workflowPaths) {
      final dartJobs = rosettaDartJobs(path);
      if (dartJobs.isEmpty) continue;
      final jobs = jobsOf(path);
      for (final jobEntry in jobs.entries) {
        if (!dartJobs.contains(jobEntry.key.toString())) continue;
        final steps = (jobEntry.value as YamlMap)['steps'] as YamlList?;
        if (steps == null) continue;
        test('${path.split('/').last}::${jobEntry.key} pins setup-dart '
            'architecture for its arch -x86_64 dart', () {
          expect(
            hasSetupDartArchPin(steps),
            isTrue,
            reason:
                '$path job "${jobEntry.key}" runs `arch -x86_64 dart` '
                'without a dart-lang/setup-dart step carrying an explicit '
                '`architecture:` — without the exact-arch SDK the bare-dart '
                'exemption (AC1) would resolve the host arm64 dart and '
                'fail the same `Bad CPU type` way (gh-2408)',
          );
        });
      }
    }
  });

  // gh-2409 rework: the PR description promises a negative probe (a fresh
  // `arch -x86_64 bash` violation is flagged). Feed synthetic workflows to
  // the guard machinery directly — temp files OUTSIDE .github/workflows, so
  // the repo-wide sweeps above cannot see them.
  group('Negative probes — synthetic violations must be flagged', () {
    test('a compound-command arch -x86_64 bash violation is flagged (AC1)', () {
      final dir = Directory.systemTemp.createTempSync('gh2408_probe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/probe.yml';
      File(path).writeAsStringSync(r'''
jobs:
  bundle:
    steps:
      - name: Build fa-clip pasteboard helper
        shell: bash
        run: |
          out=$(arch -x86_64 bash scripts/build_fa_clip.sh out/fa-clip)
          echo "$out"
''');
      final hits = rosettaInvocations(path);
      expect(
        hits.map((h) => h.$3),
        contains('bash'),
        reason:
            'a `\$(arch -x86_64 bash ...)` compound command PATH-resolves '
            'bash exactly like a line-leading invocation — the matcher '
            'must see non-line-leading forms (gh-2409 review thread 2); '
            'the anchored `^\\s*arch` regex misses it and the violation '
            'sails through AC1',
      );
      // AC1 would fail this hit: bash is neither an absolute path nor an
      // exact-arch-SDK command.
      expect(
        hits.any(
          (h) =>
              h.$3 == 'bash' &&
              !h.$3.startsWith('/') &&
              !archExactSdkCommands.contains(h.$3),
        ),
        isTrue,
      );
    });

    test('a Rosetta-dart job with comment-first script and no architecture '
        'pin is caught (AC2)', () {
      // Realistic shape: the run script does NOT begin with the arch
      // line (comment first, invocation inside an if) — the shape every
      // script in this repo has and the whole-script `hasMatch` chain
      // never saw (gh-2409 review thread 1).
      final dir = Directory.systemTemp.createTempSync('gh2408_probe_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/probe.yml';
      File(path).writeAsStringSync(r'''
jobs:
  bundle:
    steps:
      - uses: dart-lang/setup-dart@e6f8ce0
        with:
          sdk: stable
      - name: Build CLI bundle
        shell: bash
        run: |
          # gh-1522: the bundle version rides the TAG.
          version="${GITHUB_REF_NAME#v}"
          if [ x = x ]; then
            arch -x86_64 dart build cli --target=bin/fa.dart
          else
            dart build cli
          fi
          echo "$version"
''');
      final dartJobs = rosettaDartJobs(path);
      expect(
        dartJobs,
        contains('bundle'),
        reason:
            'the AC2 job derivation must be per-line (rosettaInvocations) '
            '— whole-script `hasMatch` anchored `^` at string start, so '
            'comment-first scripts were invisible and AC2 registered '
            'zero tests while a missing setup-dart `architecture:` pin '
            'stayed green (gh-2409 review thread 1)',
      );
      final steps =
          ((loadYaml(read(path)) as YamlMap)['jobs']
                  as YamlMap)['bundle']['steps']
              as YamlList;
      expect(
        hasSetupDartArchPin(steps),
        isFalse,
        reason:
            'the synthetic setup-dart step pins no architecture — '
            'paired with the Rosetta-dart invocation above, AC2 must '
            'fail this job',
      );
    });
  });
}
