// gh-1684 — the fa-extension.zip size budget regression surfaced ONLY
// at deploy time (pages.yml), after #1631 merged, and blocked Pages for
// days. Owner direction (locked 2026-10-18):
//  AC1  Pages stops carrying/copying/gating the zip; the site's extension
//       download links point at the GitHub release asset
//       (releases/latest/download/fa-extension.zip),
//  AC2  the zip stays attached to releases by the build-macos.yml
//       build-extension leg (latest tag onward),
//  AC3  the size gate runs at PR review time: a new extension-size-gate
//       leg in ci.yml builds the real zip and fails the PR against the
//       committed baseline (a vendor-bump PR without a reseed goes red),
//  AC4  the notice-only web-app.tsv/outlook-app.tsv legs (baselines never
//       committed since #1096) are REMOVED from pages.yml,
//  AC5  one baseline + one enforcement rule: the release leg and the PR
//       leg gate against the same committed TSV with the identical
//       size_manifest.py invocation, on the same pinned Flutter (3.47.7).
//
// Deliberately YAML-level asserts (same static pattern as
// ci_1267_path_triggered_legs_test.dart / ci_1659_office_addin_matrix_
// test.dart): they pin the wiring — the builds themselves run on CI
// runners, not locally.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const ci = '.github/workflows/ci.yml';
const pages = '.github/workflows/pages.yml';
const macos = '.github/workflows/build-macos.yml';
const legId = 'extension-size-gate';

const releaseDownloadUrl =
    'https://github.com/IstiN/flutter_agent_harness/releases/latest/download/fa-extension.zip';

/// The exact gate invocation every fa-extension.zip leg must run
/// (gh-1684 AC5: one baseline, one enforcement rule).
const gateInvocation =
    'python3 scripts/size_manifest.py check build/fa-extension.zip '
    '--baseline scripts/size_budget/fa-extension.tsv';

/// The extsize classifier arm in the changes job. gh-1684 rework also
/// arms the root `vendor/` forks (patch edits are a normal maintenance
/// event and path deps carry no content hash in pubspec.lock), the gate
/// tool itself and root pubspec_overrides.yaml (feeds `dart pub get`
/// for the dart2js agent build, same as pubspec.yaml/pubspec.lock).
final extsizeGrep =
    r"grep -qE '(^browser_ext/|^flutter_app/|^lib/|^packages/|^vendor/"
    r"|^pubspec\.yaml$|^pubspec_overrides\.yaml$|^pubspec\.lock$"
    r"|^scripts/(build_browser_ext|fetch_vendor_assets|stage_extension_panel"
    r"|ext_package_guard|prune_flutter_assets)\."
    r"|^scripts/size_manifest\.py$"
    r"|^scripts/size_budget/fa-extension\.tsv$"
    r"|^\.github/workflows/(ci|build-macos|pages)\.yml$)'";

void main() {
  final ciBody = read(ci);
  final ciJobs = jobsOf(ci);
  final pagesBody = read(pages);
  final macosBody = read(macos);
  final macosJobs = jobsOf(macos);
  final index = read('site/index.html');
  final llms = read('site/llms.txt');

  group('AC1 — Pages stops carrying the zip; site links move', () {
    test('pages.yml no longer copies fa-extension.zip into the artifact', () {
      expect(
        pagesBody,
        isNot(contains('build/pages/root/extension')),
        reason:
            'AC1: the Pages artifact must not contain fa-extension.zip — '
            'the download channel is the GitHub release now',
      );
      expect(
        pagesBody,
        isNot(contains('Build Chrome extension')),
        reason: 'nothing extension-related ships from Pages anymore',
      );
    });

    test('pages.yml runs no size gates at deploy time', () {
      expect(
        pagesBody,
        isNot(contains('Size manifest + budget gate')),
        reason:
            'the deploy-time gate is the wrong layer (this bug) — the '
            'extension gate lives at PR/review time and release time',
      );
      expect(
        pagesBody,
        isNot(contains('upload-artifact')),
        reason:
            'the seeded-baseline ride-along upload is obsolete with '
            'the web-app/outlook-app notice-only legs removed (AC4)',
      );
    });

    test('every site extension link points at the GitHub release', () {
      expect(index, contains(releaseDownloadUrl));
      expect(llms, contains(releaseDownloadUrl));
      expect(
        index + llms,
        isNot(contains('./extension/fa-extension.zip')),
        reason: 'no site-relative extension links may survive',
      );
      expect(
        index + llms,
        isNot(contains('https://fa1.dev/extension/fa-extension.zip')),
        reason: 'no fa1.dev extension-zip links may survive',
      );
      // The FAQ JSON-LD answer is a link too — it must carry the new URL.
      expect(
        index,
        contains('Download fa-extension.zip from $releaseDownloadUrl'),
      );
    });

    test(
      'the llms.txt artifact lead-in matches the release channel (rework)',
      () {
        // AC1 moved the zip channel to Releases: build-macos builds it
        // per release, ci.yml extension-size-gate per PR — deploys no
        // longer touch it, so "(rebuilt on every deploy)" is stale.
        expect(llms, contains('- Artifact (attached to every release):'));
        expect(llms, isNot(contains('rebuilt on every deploy')));
      },
    );
  });

  group('AC2 — the zip keeps riding the release', () {
    test('build-macos.yml build-extension gates then uploads the zip', () {
      final job = macosJobs['build-extension'] as YamlMap?;
      expect(
        job,
        isNotNull,
        reason:
            'the daily leg still pre-stages the next-tag draft and stays '
            'the n_1012 emergency producer (gh-1847: the tag train gained '
            'its own ci.yml build-extension leg, this one was NOT '
            'removed)',
      );
      final steps = ((job!['steps'] as YamlList).map(
        (s) => s.toString(),
      )).join('\n');
      expect(
        steps,
        contains(gateInvocation),
        reason:
            'gate BEFORE upload — a budget regression must not '
            'reach the release assets',
      );
      expect(
        steps,
        contains(r'gh release upload "$RELEASE_TAG" "$asset"'),
        reason:
            'AC2: fa-extension.zip attached to releases, latest '
            'tag onward (--clobber keeps the stable asset name)',
      );
    });
  });

  group('AC3 — the gate runs at PR review time', () {
    test('the extension-size-gate leg exists in ci.yml', () {
      expect(ciJobs[legId], isNotNull);
    });

    test('the leg is path-gated on the new extsize output', () {
      final cond = (ciJobs[legId] as YamlMap)['if'].toString();
      expect(cond, contains("needs.changes.outputs.extsize == 'true'"));
      // Same two-event guard as exzone/locksmoke/office_addin:
      // pull_request events AND SM validation dispatches.
      expect(cond, contains("github.event_name == 'pull_request'"));
      expect(cond, contains("github.event_name == 'workflow_dispatch'"));
      expect(
        cond,
        contains("needs.release-pending.outputs.pending == 'true'"),
        reason: 'gh-1551: the empty-schedule-tick pre-check gates every leg',
      );
      expect(
        cond,
        contains("needs.release-dedupe.outputs.dedupe != 'true'"),
        reason: 'gh-1625: the release-twin pre-check gates every leg',
      );
    });

    test('the leg builds the full zip and gates against the baseline', () {
      final steps = (((ciJobs[legId] as YamlMap)['steps'] as YamlList).map(
        (s) => s.toString(),
      )).join('\n');
      expect(
        steps,
        contains('bash scripts/build_browser_ext.sh --with-app'),
        reason:
            'the gate must measure the REAL artifact, not a '
            'manifest-only stand-in',
      );
      expect(steps, contains(gateInvocation));
      expect(
        steps,
        isNot(contains('--init-if-missing')),
        reason:
            'the baseline is committed — self-seeding would wave '
            'any regression through',
      );
    });

    test('the leg carries an explicit ceiling (#351 arithmetic)', () {
      expect((ciJobs[legId] as YamlMap)['timeout-minutes'], isNotNull);
    });

    test('the classifier emits extsize for both events', () {
      final outputs = (ciJobs['changes'] as YamlMap)['outputs'] as YamlMap;
      expect(
        outputs['extsize'].toString(),
        contains('steps.paths.outputs.extsize'),
        reason:
            'the output rides the paths step (pull_request + validation '
            'dispatches), NOT the non-PR full-gate filter — tags/schedule '
            'are gated by the release leg instead',
      );
    });

    test('the classifier keys on the extension-touching path set', () {
      final run = ciBody.split('\n  changes:')[1].split('\n  # ─')[0];
      expect(run, contains(extsizeGrep));
      expect(
        ciBody.split(extsizeGrep).length - 1,
        1,
        reason: 'single source — a second copy would let the arms drift',
      );
      // The baseline itself is in the trigger set: a reseed PR must
      // re-run the gate and prove the new floor matches the artifact;
      // a vendor.lock bump without a reseed fails red here.
      expect(extsizeGrep, contains('fa-extension'));
    });

    test('the trigger set arms on root vendor/ fork edits (rework)', () {
      // The vendored forks are real build inputs of the gated artifact
      // (pubspec.yaml → vendor/xterm; pubspec_overrides → vendor/dart_tui;
      // flutter_app/pubspec.yaml → ../vendor/wasm_run*). Path deps carry
      // no content hash in pubspec.lock, so a patched-fork edit can move
      // the zip manifest with no other covered path touched — the exact
      // merge-then-red failure mode gh-1684 exists to kill.
      expect(extsizeGrep, contains('^vendor/'));
      expect(
        ciBody.split('\n  changes:')[1].split('\n  # ─')[0],
        contains(r'|^packages/|^vendor/'),
        reason:
            'the root vendor tree must sit in the same alternation, '
            'not a second grep arm that could drift',
      );
    });

    test('the trigger set arms on the gate tool itself (rework)', () {
      // A scripts/size_manifest.py change (rev normalization, budget
      // math, is_vendored split) must re-run the gate that runs it —
      // the always-on core tests cover correctness, not enforcement.
      expect(extsizeGrep, contains(r'^scripts/size_manifest\.py$'));
    });

    test('the trigger set arms on root pubspec_overrides.yaml (rework)', () {
      // The overrides file selects the vendored dart_tui fork for the
      // dart2js agent build — same supply-chain surface as
      // pubspec.yaml/pubspec.lock, which are already armed.
      expect(extsizeGrep, contains(r'^pubspec_overrides\.yaml$'));
    });

    test('the classifier failure arm runs the leg (fail-safe)', () {
      final run = ciBody.split('\n  changes:')[1].split('\n  # ─')[0];
      expect(run, contains('echo "extsize=true"'));
      expect(
        run,
        contains(
          'failing safe: exzone + locksmoke + installer + office_addin + extsize arms run',
        ),
      );
    });

    test('the extsize arm classifies validation dispatches too', () {
      final run = ciBody.split('\n  changes:')[1].split('\n  # ─')[0];
      final armAt = run.indexOf(extsizeGrep);
      final dispatchExitAt = run.indexOf('!= "pull_request"');
      expect(armAt, greaterThan(-1));
      expect(dispatchExitAt, greaterThan(-1));
      expect(
        armAt < dispatchExitAt,
        isTrue,
        reason:
            'the arm must sit before the dispatch early-exit — the SM '
            'validation dispatch IS the pre-merge gate (dispatch-only '
            'CI); a classification after the exit is path-blind there',
      );
    });

    test('quality-gate NEEDS the leg and consumes its result', () {
      final gate = ciJobs['quality-gate'] as YamlMap;
      final needs = gate['needs'];
      final needsList = needs is YamlList
          ? needs.map((n) => n.toString())
          : [needs!];
      expect(
        needsList,
        contains(legId),
        reason:
            'a leg outside the aggregate never blocks the merge — the '
            'quality gate is the single required check',
      );
      expect(
        ciBody,
        contains('R_EXT_SIZE: \${{ needs.extension-size-gate.result }}'),
      );
      expect(
        ciBody,
        contains('"extension-size-gate:\$R_EXT_SIZE"'),
        reason:
            'the verdict loop must consume the result — an unlisted need '
            'reports in the log and gates nothing',
      );
    });

    test('the leg is platform class (never holds the dart publish)', () {
      final gateRun = ciBody.split('\n  quality-gate:')[1].split('\n  # ─')[0];
      final caseBody = gateRun.split('case "\$name" in')[1].split('esac')[0];
      expect(
        caseBody,
        contains('extension-size-gate'),
        reason:
            '#1368 platform class: a red size gate reddens the required '
            'aggregate (blocks the MERGE) but never gates dart_ok — a '
            'zip-size red must not hold the pure-Dart publish hostage',
      );
    });
  });

  group('AC4 — the notice-only web gates are removed, not armed', () {
    test('pages.yml has no web-app/outlook-app gate legs left', () {
      expect(pagesBody, isNot(contains('web-app.tsv')));
      expect(pagesBody, isNot(contains('outlook-app.tsv')));
      expect(
        pagesBody,
        isNot(contains('--init-if-missing')),
        reason:
            'the baselines were never committed — the legs were '
            'notice-only since #1096; removed per gh-1684 decision 5',
      );
    });
  });

  group('AC5 — one baseline, one enforcement rule', () {
    test('both legs gate against the committed baseline identically', () {
      expect(macosBody, contains(gateInvocation));
      expect(ciBody, contains(gateInvocation));
      expect(macosBody.split(gateInvocation).length - 1, 1);
      expect(
        ciBody.split(gateInvocation).length - 1,
        2,
        reason:
            'two call sites in ci.yml, ONE of them enforced per event — '
            'the PR-time extension-size-gate leg and the gh-1847 tag-train '
            'release leg; both carry the byte-identical invocation, so '
            'drift would resurrect the two-legs-green-one-leg-red class',
      );
    });

    test('the release leg builds on the same pinned Flutter', () {
      // The pages.yml leg that used to carry this pin is retired; every
      // REMAINING fa-extension.zip builder pins 3.47.7 exactly (#1431:
      // a wildcard pin re-resolves a new engine build per patch drop).
      // Raw-text assert: the parsed view renders the pin unquoted, the
      // file carries it quoted.
      final jobBody = macosBody
          .split('\n  build-extension:')[1]
          .split('\n  release-macos:')[0];
      expect(
        jobBody,
        contains("flutter-version: '3.47.7'"),
        reason:
            'gh-1684 decision 4: the old unpinned channel: stable was '
            'one of the two ways the release and Pages legs diverged',
      );
      final ciSteps = (((ciJobs[legId] as YamlMap)['steps'] as YamlList).map(
        (s) => s.toString(),
      )).join('\n');
      expect(ciSteps, contains('flutter-version: 3.47.7'));
    });

    test('the gate leg caches the pinned Flutter SDK (rework)', () {
      // Sibling legs (e.g. office-addin-suite, the template this leg
      // was modeled on) set cache: true — the pin (not the cache)
      // keeps the engine rev stable, and a cache miss re-resolves the
      // same pinned version, so build comparability is unaffected.
      final flutterStep = ((ciJobs[legId] as YamlMap)['steps'] as YamlList)
          .map((s) => s.toString())
          .firstWhere((s) => s.contains('flutter-version: 3.47.7'));
      expect(
        flutterStep,
        contains('cache: true'),
        reason:
            'the gate fires on the high-churn paths — an uncached '
            'SDK download taxes every one of those runs',
      );
    });
  });
}
