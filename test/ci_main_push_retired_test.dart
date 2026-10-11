// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// gh-1537: the post-merge main CI run is RETIRED — the SM's pre-merge
/// validation dispatch (machine-sm.yml -> factory-sm, strictly serialized,
/// validating the exact tree that merges) is the only gate a merge ever
/// sees. Deliberately text/YAML-level asserts (the repo's workflow-shape
/// never-again pattern, same as workflow_fetch_shape_guard_test.dart):
///  AC1  ci.yml fires on tags + workflow_dispatch + schedule + release
///       only — `push:` carries NO `branches:` filter (a main-push trigger
///       must never return and silently resurrect post-merge CI),
///  AC2  no ci.yml job keys off a main-push run (the release job's dead
///       push arm is gone; `refs/heads/main` survives only in the
///       ref-restricted releaseDispatch dispatch arm, which is a dispatch,
///       not a push),
///  AC3  the release flow keeps working WITHOUT main CI: release-tag.yml
///       owns the tag-on-bump, triggered by the release-bot's chore(release)
///       push to main (release flow, not CI — the job filters on the bump
///       subject, SM merges never start it),
///  AC4  flake intake consumes PR-dispatch runs: flake_watch.py filters
///       ci.yml failures to workflow_dispatch events (tag/release reds are
///       release-flow failures, triaged by daily-publish/ci-red-report —
///       never quarantined as "flakes"),
///  AC5  the serialized-validation invariant gets a cheap alarm:
///       sm-merge-guard.yml fires on every main push and asserts the
///       pushed tree was covered by a successful dispatched validation.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();

/// Transitive needs closure of the two aggregate checks the SM's branch
/// protection requires ("Quality gate", "Binaries smoke gate") — the gate
/// population that MUST run on every SM validation dispatch.
Set<String> _gateClosure(YamlMap jobs) {
  final closure = <String>{};
  void collect(String name) {
    if (!closure.add(name)) return;
    final needs = (jobs[name] as YamlMap)['needs'];
    if (needs is String) {
      collect(needs);
    } else if (needs is YamlList) {
      for (final n in needs) {
        collect(n.toString());
      }
    }
  }

  collect('quality-gate');
  collect('binaries-smoke-gate');
  return closure;
}

void main() {
  group('AC1 — ci.yml has no main-push trigger (gh-1537)', () {
    test('on.push carries tags only, no branches filter', () {
      final on = (loadYaml(read('.github/workflows/ci.yml'))['on'] as YamlMap);
      final push = on['push'] as YamlMap;
      expect(push, isNotNull, reason: 'the tag push trigger must stay');
      expect(
        push.containsKey('branches'),
        isFalse,
        reason:
            'gh-1537 AC1: the post-merge main CI run is retired — a '
            '`branches: [main]` filter must never return (the SM pre-merge '
            'validation dispatch is the single gate; main runs would be '
            'pure repetition of the byte-identical validated tree)',
      );
      expect(
        (push['tags'] as YamlList).toString(),
        contains('v*'),
        reason: 'the release/tag flow keys on the v* tag push',
      );
      // The non-dispatch triggers that stay, pinned so a cleanup cannot
      // silently drop the release catch-up or the release-event arm.
      expect(on.containsKey('workflow_dispatch'), isTrue);
      expect(on.containsKey('release'), isTrue);
      expect(on.containsKey('schedule'), isTrue);
    });
  });

  group('AC2 — no ci.yml job keys off a main-push run', () {
    test('release job has no dead push arm; main survives only in the '
        'ref-restricted releaseDispatch arm', () {
      final jobs =
          loadYaml(read('.github/workflows/ci.yml'))['jobs'] as YamlMap;
      final releaseIf = (jobs['release'] as YamlMap)['if'].toString();
      expect(
        releaseIf,
        isNot(contains("github.event_name == 'push'")),
        reason:
            'gh-1537: with the main-push trigger retired the push arm '
            'is dead code — and a future push trigger would auto-release '
            'from any push; the release job arms on schedule + the two '
            'gated dispatch arms only',
      );
      expect(releaseIf, contains("github.event_name == 'schedule'"));
      expect(releaseIf, contains('inputs.releaseDryRun'));
      expect(releaseIf, contains('inputs.releaseDispatch'));
      expect(
        releaseIf.split("github.ref == 'refs/heads/main'").length - 1,
        1,
        reason:
            'refs/heads/main may appear exactly once — inside the '
            'releaseDispatch dispatch arm (a dispatch restriction, not a '
            'push key)',
      );

      // No job in the GATE CLOSURE (everything the SM's required checks
      // aggregate: quality-gate + binaries-smoke-gate and their transitive
      // needs) may require a push event — a dispatched run (the SM
      // validation) must execute every gate; a push-keyed gate leg would
      // skip on all of them. Release-flow legs (publish, provider smoke,
      // ci-red-report …) intentionally key on v* tag pushes and are not
      // in the closure.
      jobs.forEach((jobId, job) {
        final ifText = (job as YamlMap)['if']?.toString() ?? '';
        final isGateLeg = _gateClosure(jobs).contains(jobId);
        if (!isGateLeg) return;
        expect(
          ifText.contains("github.event_name == 'push'"),
          isFalse,
          reason:
              'gh-1537: gate leg `$jobId` keys off push events — with '
              'the main trigger gone the only ci.yml push events are v* '
              'tag pushes, and a gate leg skipping on SM validation '
              'dispatches would break the pre-merge gate',
        );
      });
    });
  });

  group('AC3 — the release flow keeps working without main CI', () {
    test(
      'release-tag.yml owns the tag-on-bump off the chore(release) push',
      () {
        final path = '.github/workflows/release-tag.yml';
        final raw = read(path);
        final doc = loadYaml(raw) as YamlMap;
        final on = doc['on'] as YamlMap;
        final push = on['push'] as YamlMap;
        expect(
          (push['branches'] as YamlList).toString(),
          contains('main'),
          reason:
              'the release-bot bump push to main is the one remaining '
              'main-push consumer — it is release flow, not CI (gh-1537 AC1 '
              'retired the ci.yml main trigger, not the release chain)',
        );
        expect(
          on.containsKey('tags'),
          isFalse,
          reason: 'tag pushes must not re-trigger the tag cutter',
        );
        final jobs = doc['jobs'] as YamlMap;
        final tagIf = (jobs['release-tag'] as YamlMap)['if'].toString();
        expect(
          tagIf,
          contains(
            "startsWith(github.event.head_commit.message, 'chore(release):')",
          ),
          reason:
              'SM merge commits (squash subjects like `KEY summary '
              '(#PR)`) must never start the tag cutter — only the '
              'release-bot bump commit does',
        );
        expect(
          raw,
          contains(
            r'BUMP_SHA: ${{ github.event.head_commit.id || github.sha }}',
          ),
          reason:
              'the tag pins to the push-event bump sha (the #1178 '
              'interloper capture) — the move out of ci.yml must not drop '
              'the pin',
        );
        // ci.yml must no longer carry the job (one owner, no drifted twins).
        final ci = read('.github/workflows/ci.yml');
        expect(
          ci,
          isNot(contains('  release-tag:')),
          reason: 'release-tag lives in release-tag.yml exclusively',
        );
      },
    );
  });

  group('AC4 — flake intake consumes PR-dispatch runs', () {
    test('flake_watch.py filters ci.yml failures to workflow_dispatch', () {
      final script = read('scripts/flake_watch.py');
      expect(
        script,
        contains("r.get(\"event\") != \"workflow_dispatch\""),
        reason:
            'gh-1537 AC3: the only ci.yml runs left are SM validation '
            'dispatches (PR heads) and v* tag runs — a red tag run is a '
            'release-flow failure (daily-publish triage), never a flake '
            'to quarantine',
      );
    });
  });

  group('AC5 — the serialized-validation invariant has a cheap alarm', () {
    test('sm-merge-guard.yml fires on every main push and nothing else', () {
      final path = '.github/workflows/sm-merge-guard.yml';
      final doc = loadYaml(read(path)) as YamlMap;
      final on = doc['on'] as YamlMap;
      final push = on['push'] as YamlMap;
      expect(
        (push['branches'] as YamlList).toString(),
        contains('main'),
        reason:
            'the invariant under watch: every main push must be a '
            'tree the SM validated pre-merge (gh-1537 AC5)',
      );
      expect(
        on.keys.toSet(),
        {'push'},
        reason:
            'no schedule/tags/pull_request arms — an alarm must be '
            'event-driven off the exact push it guards, never a polling '
            'backstop',
      );
      expect(
        read('scripts/sm_merge_guard.py'),
        contains('chore(release):'),
        reason:
            'release-bot bump pushes skip the guard — the tag run '
            'gates them (the ci.yml v* arm runs the full gate before '
            'publish)',
      );
    });
  });
}
