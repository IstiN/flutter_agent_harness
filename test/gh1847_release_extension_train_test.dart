// gh-1847 regression guards: the once-daily build-macos.yml
// build-extension producer derives "latest+1 at its own dispatch
// moment", so any v* tag train landing after the daily leg published a
// draft WITHOUT fa-extension.zip and the gh-1832 required-assets gate
// correctly stranded it (v1.0.637 + v1.0.638 stuck, 2026-10-24 — the
// manual recovery dispatch from memory note n_1012 risked becoming the
// accepted operating mode). Systemic fix (review-thread option 1): the
// tag train itself produces/attaches fa-extension.zip, so the gh-1832
// gate's precondition is met by the train no matter when the daily leg
// ran.
//
// Deliberately YAML-level asserts (same static pattern as
// ci_1684_extension_size_gate_test.dart / release_required_assets_gate_
// test.dart): they pin the wiring — the builds themselves run on CI
// runners, not locally.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const ci = '.github/workflows/ci.yml';
const macos = '.github/workflows/build-macos.yml';
const jobId = 'build-extension';

/// The exact gate invocation every fa-extension.zip leg must run
/// (gh-1684 AC5: one baseline, one enforcement rule).
const gateInvocation =
    'python3 scripts/size_manifest.py check build/fa-extension.zip '
    '--baseline scripts/size_budget/fa-extension.tsv';

void main() {
  final ciJobs = jobsOf(ci);
  final job = ciJobs[jobId] as YamlMap?;
  final steps = job?['steps'] is YamlList
      ? ((job!['steps'] as YamlList).map((s) => s.toString()).join('\n'))
      : '';

  group('gh-1847: the tag train builds its own fa-extension.zip', () {
    test('ci.yml carries a build-extension release leg', () {
      expect(
        job,
        isNotNull,
        reason:
            'the tag train must produce fa-extension.zip itself — '
            'relying on the once-daily build-macos leg is exactly the '
            'gh-1847 stranding pattern (v1.0.637/v1.0.638)',
      );
    });

    test('the leg rides the tag/release train and waits for the quality gate',
        () {
      final needs = job!['needs'];
      final needsList =
          needs is YamlList ? needs.map((n) => n.toString()) : [needs];
      expect(needsList, contains('quality-gate'),
          reason: 'same keyed model as web-spa — the leg builds only what '
              'the gate validated');
      final cond = job['if'].toString();
      expect(cond, contains("startsWith(github.ref, 'refs/tags/v')"),
          reason: 'PR/dispatch runs must not touch releases');
      expect(cond, contains("github.event_name == 'release'"),
          reason: 'the gh-1172 direct-release path publishes through the '
              'release event too — the extension must attach there');
      expect(cond, contains("needs.quality-gate.result == 'success'"));
    });

    test('the leg is additive (continue-on-error), like web-spa', () {
      // fa-extension.zip is a gh-1832 REQUIRED asset, but the attach leg
      // stays additive: an SDK flake must not hold CLI provenance
      // hostage — release-provenance's required-assets gate is the
      // single publish blocker and strands the draft loudly on the
      // MISSING asset.
      expect(job!['continue-on-error'], isTrue);
      expect(job['timeout-minutes'], isNotNull,
          reason: '#351: every leg carries an explicit ceiling');
      expect((job['permissions'] as YamlMap)['contents'], 'write',
          reason: 'the leg attaches fa-extension.zip to the release');
    });

    test('build → size gate → attach, in that order', () {
      final buildAt = steps.indexOf('bash scripts/build_browser_ext.sh --with-app');
      final gateAt = steps.indexOf(gateInvocation);
      final uploadAt = steps.indexOf('gh release upload');
      expect(buildAt, isNonNegative, reason: 'must build the real artifact');
      expect(gateAt, isNonNegative,
          reason: 'gh-1684 AC5: gate before upload — a budget regression '
              'must not reach the release assets');
      expect(uploadAt, isNonNegative);
      expect(buildAt, lessThan(gateAt));
      expect(gateAt, lessThan(uploadAt));
    });

    test('the attach is draft-first and never publishes', () {
      expect(steps, contains('release_lazy_draft.sh'),
          reason: 'gh-1801: draft-first create via the helper (curated '
              'notes + ownership marker), never an inline create');
      expect(steps, contains('fa-extension.zip'));
      expect(steps, contains('--clobber'));
      expect(steps, isNot(contains('--draft=false')),
          reason: 'the publish flip is provenance-owned and rides ONLY '
              'the SHA256SUMS upload (gh-1801 rework)');
    });

    test('the leg builds on the pinned Flutter SDK (gh-1684 AC5)', () {
      expect(steps, contains('flutter-version: 3.47.7'),
          reason: '#1431 exact-patch pin — every fa-extension.zip builder '
              'must stay comparable across legs');
      expect(steps, contains('cache: true'));
    });
  });

  group('gh-1847: release-provenance can never race the attach', () {
    test('provenance needs the extension leg (ordering)', () {
      final prov = ciJobs['release-provenance'] as YamlMap;
      final needs = prov['needs'];
      final needsList = needs is YamlList
          ? needs.map((n) => n.toString())
          : [needs.toString()];
      expect(
        needsList,
        containsAll(['binaries', 'web-spa', jobId]),
        reason:
            'the gh-1832 gate runs inside provenance and inspects the '
            'release asset set — every REQUIRED attach leg must complete '
            '(success OR additive-failure) before the gate, or a slow '
            'extension upload fails the gate on a false missing asset',
      );
    });
  });

  group('gh-1847: the daily producer stays available', () {
    test('build-macos.yml build-extension still gates then uploads', () {
      final macosJobs = jobsOf(macos);
      final daily = macosJobs[jobId] as YamlMap?;
      expect(daily, isNotNull,
          reason: 'the daily leg still pre-stages the next-tag draft, and '
              'the n_1012 emergency recovery dispatch '
              '(--ref <tag> -f version=<tag>) keeps working');
      final dailySteps =
          (daily!['steps'] as YamlList).map((s) => s.toString()).join('\n');
      expect(dailySteps, contains(gateInvocation));
      expect(dailySteps, contains('gh release upload'));
    });
  });
}
