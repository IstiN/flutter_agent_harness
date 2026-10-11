// gh-1310 — every flutter_app `flutter pub get --enforce-lockfile` in CI
// rides ONE shared composite action with the #726 bounded retry.
//
// The v1.0.513 tag CI went red on 13 legs from a deterministic cause
// (gh-1299: release commit without the lockfile refresh). #1304 fixed that
// and hardened the release path — but the very next main run went red AGAIN
// on a different leg (ci.yml build-macos): pub has NO retry for its
// git-dependency mirror clones (flutter_js, flutter_js_widget_runtime), so
// one transient "Connection reset by peer" on github.com:443 kills the leg
// — and every lockfile-refresh commit cold-misses the flutter-action pub
// cache, forcing fresh clones exactly when releases land. build-mobile.yml
// solved this class for its iOS leg back in #726 (bounded retry + backoff +
// deterministic-skew fail-fast), but the pattern stayed trapped in ONE step
// while 21 other workflow steps ran the same network roulette bare.
//
// Deliberately YAML-level asserts (the nightly_desktop_leg_guard_test.dart
// / store_automation_guard_test.dart static pattern):
//  AC1  the shared action exists, is composite, and carries the #726
//       retry loop with the gh-1265/PR-1268 deterministic-skew fail-fast,
//  AC2  NO workflow run-step resolves flutter_app itself anymore — every
//       flutter_app pub get goes through `./.github/actions/flutter-pub-get`
//       (a future bare `cd flutter_app && flutter pub get` is a test red,
//       not a silent network roulette), and
//  AC3  each workflow still resolves flutter_app exactly as many times as
//       it did before the migration (a refactor that DELETES a pub-get
//       step must red here, not silently skip resolution),
//  AC4  a job's first flutter_app resolution is the enforced one — the
//       shared action runs BEFORE any step that consumes flutter_app with
//       a bare `flutter` command (office-addin.yml: flutter test's
//       implicit pub get would otherwise be the first, unenforced and
//       unretried, resolution), and the AC2 detector itself is unit-tested
//       against both `flutter_app` and `./flutter_app` working-directory
//       spellings (gh-1310 rework review threads 1-3).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

const actionUses = './.github/actions/flutter-pub-get';
const actionPath = '.github/actions/flutter-pub-get/action.yml';

/// The seven workflows that resolved flutter_app with
/// `flutter pub get --enforce-lockfile` before the gh-1310 migration.
const workflows = [
  '.github/workflows/ci.yml',
  '.github/workflows/nightly.yml',
  '.github/workflows/build-mobile.yml',
  '.github/workflows/build-macos.yml',
  '.github/workflows/browser-ext.yml',
  '.github/workflows/office-addin.yml',
  '.github/workflows/pages.yml',
];

/// Expected number of `uses: ./.github/actions/flutter-pub-get` steps per
/// workflow — the exact step count that ran `flutter pub get
/// --enforce-lockfile` before the migration. A refactor that drops a
/// resolution step fails AC3 instead of silently skipping pub get.
const expectedUsesPerWorkflow = {
  // 10 pre-migration resolutions + 1 (gh-1310 rework, review thread 1): the
  // release-tag job warms the pub cache through the action BEFORE
  // tag_release.sh's own enforce-lockfile smoke. The smoke stays in the
  // script (release_hygiene_test.dart NG2/AC3 pins it) but no longer
  // cold-clones the git deps unretried on the release path.
  // 11 + 1 (issue #1267 N1, review round 3): the new flutter-app-exzone leg
  // resolves flutter_app through the shared action (bounded retry + skew
  // fail-fast) before its macOS `flutter test test/apps` run — a bare pub
  // get there would be exactly the network roulette AC2 exists to stop.
  // 12 + 1 (issue #1267 N2): the flutter-app-lock-smoke legs resolve
  // flutter_app through the shared action before their linux/windows
  // release builds — the smoke that catches a floated transitive (#1265)
  // must itself resolve against the COMMITTED lockfile, never re-float it.
  '.github/workflows/ci.yml': 13,
  '.github/workflows/nightly.yml': 4,
  '.github/workflows/build-mobile.yml': 4,
  '.github/workflows/build-macos.yml': 1,
  '.github/workflows/browser-ext.yml': 1,
  '.github/workflows/office-addin.yml': 1,
  '.github/workflows/pages.yml': 1,
};

/// Every `steps:` entry of every job in [workflowPath] as YamlMap steps
/// (jobs with `uses:` reusable-workflow calls have no steps and yield
/// nothing).
Iterable<YamlMap> stepsOf(String workflowPath) sync* {
  final root = loadYaml(read(workflowPath)) as YamlMap;
  final jobs = root['jobs'] as YamlMap;
  for (final job in jobs.values) {
    final steps = (job as YamlMap)['steps'];
    if (steps is! YamlList) continue;
    for (final step in steps) {
      if (step is YamlMap) yield step;
    }
  }
}

/// Every run-step in [workflowPath] as (run, workingDirectory).
Iterable<({String run, String? workingDirectory})> runStepsOf(
    String workflowPath) sync* {
  for (final step in stepsOf(workflowPath)) {
    if (step['run'] is! String) continue;
    yield (
      run: step['run'] as String,
      workingDirectory: step['working-directory'] as String?,
    );
  }
}

/// The AC2 regression class: run-steps that resolve flutter_app with a
/// bare `flutter pub get` instead of the shared action. A step counts
/// when the command mentions flutter_app OR runs inside flutter_app.
List<({String run, String? workingDirectory})> bareFlutterAppPubGetRunSteps(
    Iterable<({String run, String? workingDirectory})> steps) {
  return steps
      // Normalize the `./` spelling so `working-directory: ./flutter_app`
      // counts the same as `working-directory: flutter_app` (review
      // thread 3 — the heuristic must not depend on spelling).
      .map((step) => (
            run: step.run,
            workingDirectory:
                step.workingDirectory?.replaceFirst(RegExp(r'^\./'), ''),
          ))
      .where((step) =>
          step.run.contains('flutter pub get') &&
          (step.run.contains('flutter_app') ||
              (step.workingDirectory ?? '').startsWith('flutter_app')))
      .toList();
}

void main() {
  group('gh-1310 — flutter_app pub get rides the shared retry action', () {
    test('AC1: the composite action exists and is a composite action', () {
      final action = loadYaml(read(actionPath)) as YamlMap;
      final runs = action['runs'] as YamlMap;
      expect(runs['using'], 'composite');
      expect(runs['steps'], isA<YamlList>());
    });

    test('AC1: the action carries the #726 bounded retry', () {
      final body = read(actionPath);
      expect(body, contains('for attempt in 1 2 3'));
      expect(body, contains('sleep 15'),
          reason: 'the retry must back off — a tight loop hammers a '
              'runner whose network is already flapping (#726)');
      // pub runs its git-dep clones non-interactively; a credential
      // prompt would hang the leg until the job timeout.
      expect(body, contains('GIT_TERMINAL_PROMPT'));
      expect(body, contains('--enforce-lockfile'),
          reason: 'the shared action is the ONE sanctioned flutter_app '
              'resolution shape — it must keep enforcing the committed '
              'lockfile (gh-1265 AC2)');
    });

    test('AC1: the action fails fast on a deterministic lockfile skew', () {
      // PR #1268 review thread 3: a pubspec/lockfile skew fails
      // identically on every attempt — retrying costs ~30s per red leg
      // and blames the network. The loop must detect the skew signature
      // and exit immediately.
      final body = read(actionPath);
      expect(
        body,
        contains(RegExp(r'Unable to satisfy .+pubspec')),
        reason: 'the retry loop must match the deterministic '
            'lockfile-skew signature ("Unable to satisfy ... using ... '
            'pubspec.lock") in the failed output and fail fast instead '
            'of retrying (gh-1265 AC2, moved here from build-mobile.yml '
            'by gh-1310).',
      );
    });

    test('AC1: the action resolves flutter_app by default', () {
      final action = loadYaml(read(actionPath)) as YamlMap;
      final inputs = action['inputs'] as YamlMap?;
      expect(inputs, isNotNull);
      final workingDirectory = inputs!['working-directory'] as YamlMap;
      expect(workingDirectory['default'], 'flutter_app',
          reason: 'every call site in the repo resolves flutter_app — '
              'the bare `uses:` form must not need an input');
    });

    for (final workflow in workflows) {
      test('AC2: $workflow has NO run-step resolving flutter_app itself',
          () {
        final offending = bareFlutterAppPubGetRunSteps(runStepsOf(workflow));
        expect(
          offending,
          isEmpty,
          reason: '$workflow resolves flutter_app in a bare run-step — '
              'route it through `uses: $actionUses` so the #726 bounded '
              'retry and the deterministic-skew fail-fast apply (gh-1310; '
              'the bare shapes lost the v1.0.516 build-macos leg to one '
              'transient git-clone reset).',
        );
      });

      test('AC3: $workflow still resolves flutter_app '
          '(${expectedUsesPerWorkflow[workflow]} resolution steps)', () {
        final usesCount = stepsOf(workflow)
            .where((step) => (step['uses'] as String?) == actionUses)
            .length;
        expect(
          usesCount,
          expectedUsesPerWorkflow[workflow],
          reason: '$workflow references `$actionUses` '
              '${expectedUsesPerWorkflow[workflow]} time(s) — a count '
              'below that means a resolution step was DELETED by a '
              'refactor instead of migrated (the build would float or '
              'fail on a missing package_config).',
        );
      });
    }

    test('AC2: the detector catches the `working-directory: ./flutter_app` '
        'spelling of a bare resolve', () {
      // Review thread 3 (gh-1310 rework): the heuristic must not depend on
      // how the working directory is spelled — `./flutter_app` resolves to
      // the same directory, and a future bare pub get written that way
      // must red exactly like the plain spelling.
      final offending = bareFlutterAppPubGetRunSteps(const [
        (
          run: 'flutter pub get --enforce-lockfile',
          workingDirectory: 'flutter_app',
        ),
        (
          run: 'flutter pub get --enforce-lockfile',
          workingDirectory: './flutter_app',
        ),
        // Not the regression class: a library-package resolve (fa_ui's
        // lockfile stays uncommitted by design) and a non-pub-get flutter
        // command in flutter_app.
        (run: 'flutter pub get', workingDirectory: 'packages/fa_ui'),
        (run: 'flutter build web', workingDirectory: './flutter_app'),
      ]);
      expect(
        offending.map((step) => step.workingDirectory),
        ['flutter_app', 'flutter_app'],
      );
    });

    test('AC4: office-addin.yml resolves flutter_app BEFORE its first '
        'flutter consumer (no implicit pub get first)', () {
      // Review thread 2 (gh-1310 rework): the flutter_app package config
      // does not exist at checkout (.dart_tool/ is not committed), so the
      // first step that runs `flutter` against flutter_app triggers
      // flutter's IMPLICIT pub get — without --enforce-lockfile and
      // without the bounded retry. The shared action must run first so
      // the job's first resolution is the enforced, retried one.
      final steps = stepsOf('.github/workflows/office-addin.yml').toList();
      final actionIndex = steps
          .indexWhere((step) => (step['uses'] as String?) == actionUses);
      expect(actionIndex, isNonNegative,
          reason: 'office-addin.yml must resolve flutter_app through '
              '`$actionUses`');
      final consumers = <int>[];
      for (var i = 0; i < steps.length; i++) {
        final run = steps[i]['run'];
        if (run is! String) continue;
        final workingDirectory =
            (steps[i]['working-directory'] as String?) ?? '';
        final inFlutterApp = workingDirectory.startsWith('flutter_app') ||
            run.contains('cd flutter_app');
        final runsFlutter = RegExp(r'\bflutter\b').hasMatch(run);
        if (inFlutterApp && runsFlutter) consumers.add(i);
      }
      expect(consumers, isNotEmpty,
          reason: 'precondition: the job runs flutter against flutter_app '
              '(Chrome boot tests, office wiring tests) — otherwise this '
              'guard pins nothing');
      for (final consumer in consumers) {
        final name = (steps[consumer]['name'] as String?) ?? 'step $consumer';
        expect(
          actionIndex,
          lessThan(consumer),
          reason: 'office-addin.yml "$name" runs flutter against '
              'flutter_app BEFORE the shared pub-get action — flutter '
              'test/build triggers an implicit, unenforced, unretried pub '
              'get there (gh-1310 rework review thread 2).',
        );
      }
    });

    test('AC3: every workflow that needs flutter_app references the action',
        () {
      for (final workflow in workflows) {
        expect(
          read(workflow),
          contains('uses: $actionUses'),
          reason: '$workflow resolved flutter_app before gh-1310 — it '
              'must keep doing so through the shared action',
        );
      }
    });
  });
}
