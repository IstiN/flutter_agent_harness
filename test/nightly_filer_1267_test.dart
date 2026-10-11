// Issue #1267 N3 — the nightly-red filer resurrection:
//
// Five consecutive red nights (2026-10-01 → 10-05) filed NOTHING. Two
// defects, both pinned here so the filer cannot silently die again:
//   1. the dedup lookup read jq's literal "null" — an empty result of a
//      bare `.[0].number` — as a truthy issue number, so the
//      no-open-tracker path died commenting issue "null" and NEVER filed
//      (the filer's silent-death bug; last living tracker: #466). Every
//      lookup now reads `.[0].number // empty` — the same shape
//      ci.yml's ci-red-report already uses.
//   2. the job was schedule-only, so the AC3 synthetic-red drill
//      (dispatch + a forced-failing leg) could not reach it. The
//      fileTracker dispatch input arms it; a drill dispatch must never
//      CLOSE the live tracker on green though — close stays schedule-only.
// Plus the N3 rules: the decision (filed / commented / closed / why-not)
// is logged to the job output and the step summary, and the 2nd
// consecutive red scheduled night adds the nightly-red-escalated label.
//
// Deliberately YAML-level asserts (the ci_binaries_arch_gate_test.dart
// static pattern): they pin the wiring — the filer itself is exercised by
// CI runs (schedule + the AC3 drill dispatch), not locally.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

String read(String path) => File(path).readAsStringSync();
YamlMap jobsOf(String workflowPath) =>
    loadYaml(read(workflowPath))['jobs'] as YamlMap;

const nightly = '.github/workflows/nightly.yml';

void main() {
  final body = read(nightly);
  final filer = jobsOf(nightly)['auto-issue'] as YamlMap;

  group('#1267 AC3 — the filer arms where the drill can reach it', () {
    test('the job runs on schedule AND on the fileTracker drill dispatch',
        () {
      final cond = filer['if'].toString();
      expect(cond, contains("github.event_name == 'schedule'"));
      expect(cond, contains('fileTracker'),
          reason: 'the synthetic-red drill is a workflow_dispatch with '
              'fileTracker=true — a schedule-only job can never satisfy '
              'AC3 (tracker comment within the same run)');
    });

    test('the dispatch trigger declares the fileTracker input', () {
      expect(body, contains('fileTracker:'));
      expect(body, contains('type: boolean'));
      expect(body, contains('default: false'),
          reason: 'ad-hoc manual dispatches must stay tracker-silent — only '
              'scheduled nights (and explicit drills) file');
    });

    test('a drill dispatch can never CLOSE the live tracker on green', () {
      expect(
        body,
        contains("if: success() && github.event_name == 'schedule'"),
        reason: 'a manual dispatch is not a night — its green must not '
            'close a tracker a real red night opened',
      );
    });
  });

  group('#1267 N3 — the dedup lookup never reads jq null as a number', () {
    test('every lookup reads `.[0].number // empty`', () {
      expect(
        '// empty'.allMatches(body).length,
        greaterThanOrEqualTo(2),
        reason: 'both steps (green close + red file/comment) dedup through '
            'the label lookup — one fixed and one bare lookup would leave '
            'half the filer dead',
      );
      expect(body, contains(".[0].number // empty"));
      expect(
        body,
        isNot(contains(".[0].number' --repo")),
        reason: "the bare lookup prints jq's literal \"null\" on an empty "
            'result — [ -n ] reads it as a live issue number and the filer '
            'dies commenting issue "null" (the 5-red-nights silent death)',
      );
    });
  });

  group('#1267 N3 — escalation + decision log', () {
    test('the 2nd consecutive red scheduled night escalates', () {
      expect(body, contains('nightly-red-escalated'));
      expect(
        body,
        contains('--event schedule --status completed'),
        reason: 'the streak counts real nights only — dispatch drills and '
            'incomplete runs must never inflate it',
      );
      expect(
        body,
        contains('[ "\$streak" -ge 1 ]'),
        reason: 'streak >= 1 completed prior red + tonight = 2 consecutive '
            'nights — the escalation threshold',
      );
      expect(
        body,
        contains('(\$r.databaseId | tostring)'),
        reason: 'the current run must be excluded from its own streak — '
            'the job runs before the run concludes in the API',
      );
    });

    test('the decision (filed/commented/closed/why-not) hits the output',
        () {
      for (final line in [
        'decision: filed',
        'decision: commented',
        'decision: closed',
        'decision: why-not',
      ]) {
        expect(body, contains(line),
            reason: 'the filer must log WHAT it did and WHY — an empty '
                'decision log is how the filer stayed dead for 5 nights');
      }
      expect(
        body.split(r'$GITHUB_STEP_SUMMARY').length - 1,
        greaterThanOrEqualTo(4),
        reason: 'the decision lands in the step summary too, not only the '
            'raw job log',
      );
    });
  });
}
