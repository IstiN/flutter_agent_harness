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
///  AC3  the release flow keeps working WITHOUT main CI: the tag-only
///       release (gh-1522) cuts its tag inside ci.yml's `release` job
///       (no release-tag job, no chore(release) bump commit — they
///       retired together with scripts/tag_release.sh), armed by the
///       2h coalesce schedule and the gated dispatches; the pushed v*
///       tag triggers the tag-scoped publish/binaries jobs,
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
    test('the ci.yml release job owns the tag cut (gh-1522 tag-only flow) — '
        'no release-tag job anywhere', () {
      // gh-1522 retired the bump flow BEFORE this PR merged: zero
      // commits land on main, so there is no 'chore(release):' bump
      // push to key a tag-on-bump workflow off — and with the
      // post-merge main CI run retired (gh-1537) ci.yml has no
      // main-push trigger to hand such a workflow either. The release
      // job cuts the annotated tag + GitHub Release in one step,
      // armed by the 2h coalesce schedule and the gated dispatches
      // (AC2); the pushed v* tag fires this workflow's tags arm,
      // which runs the full quality gate BEFORE publish/binaries.
      final ci = read('.github/workflows/ci.yml');
      expect(
        ci,
        isNot(contains('release-tag')),
        reason:
            'the release-tag job (and scripts/tag_release.sh) retired '
            'with the bot bump flow (gh-1522) — auto_release.sh cuts '
            'the tag directly; a tag-on-bump workflow would also be '
            'dead code now that nothing pushes chore(release) commits '
            'and ci.yml has no main-push trigger (gh-1537)',
      );
      expect(
        File('.github/workflows/release-tag.yml').existsSync(),
        isFalse,
        reason:
            'gh-1537 originally extracted release-tag.yml to carry the '
            'tag-on-bump off the retired ci.yml main trigger — but '
            'gh-1522 retired the bump flow itself (this workflow goes '
            'with it, as its own header anticipated)',
      );
      expect(
        ci,
        isNot(contains('tag_release.sh')),
        reason: 'the script is deleted from the repo',
      );
      final jobs = loadYaml(ci)['jobs'] as YamlMap;
      final release = jobs['release'] as YamlMap;
      final steps = release['steps'] as YamlList;
      final cut = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) => s['run']?.toString().contains('auto_release.sh') ?? false,
            orElse: () =>
                throw TestFailure('release must run scripts/auto_release.sh'),
          );
      // gh-1801 (rework): auto_release.sh no longer calls `gh` — the
      // asset-less create published an empty `latest` and broke `fa
      // update`. GH_TOKEN on the cut step became a dead write-capable
      // credential: the tag push rides the checkout App token (gh-1172)
      // and the step must not export GH_TOKEN.
      expect(
        (cut['env'] as YamlMap?)?.containsKey('GH_TOKEN') ?? false,
        isFalse,
        reason:
            'the cut step must not export GH_TOKEN anymore — no gh '
            'surface is left in auto_release.sh (gh-1801: the create '
            'moved to the tag-run binaries job, draft-first)',
      );
    });
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

    test('the guard checkout is pinned to the pushed SHA — the tree '
        'under assertion cannot drift to a moved main', () {
      final doc =
          loadYaml(read('.github/workflows/sm-merge-guard.yml')) as YamlMap;
      final steps =
          ((doc['jobs'] as YamlMap)['guard'] as YamlMap)['steps'] as YamlList;
      final checkout = steps
          .map((s) => s as YamlMap)
          .firstWhere(
            (s) =>
                s['uses']?.toString().startsWith('actions/checkout') ?? false,
            orElse: () => throw TestFailure('guard must check out the repo'),
          );
      final options = checkout['with'] as YamlMap;
      expect(
        options['ref'].toString(),
        r'${{ github.event.head_commit.id || github.sha }}',
        reason:
            'the tree compared against the validation runs is read '
            'from the checkout HEAD (`git rev-parse HEAD^{tree}`) — '
            'without the pin, a busy main drifts run-for-push-A onto a '
            'newer push B and certifies a tree it never examined '
            '(PR review: tree drift between the frozen PUSHED_SHA and '
            'the drifting checkout)',
      );
      expect(
        options['fetch-depth'].toString(),
        '1',
        reason: 'only the pushed tree is read — no history, no blobs',
      );
    });
  });
}
