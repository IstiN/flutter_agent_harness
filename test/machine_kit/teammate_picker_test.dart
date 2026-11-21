// gh-2359 AC2 — the machine issue-picker must skip any issue that has an
// OPEN referencing PR, from ANY author.
//
// 2026-11-20 incident: the machine opened PR #2339 (branch ai/gh-2337)
// for the 125k release-body root while the owner's HUMAN PR #2340 for the
// same root was already open — the picker only knew its own in-flight
// work, so both fixes ran in parallel and #2340 closed superseded.
//
// Behavioral coverage in the daily_publish_report_signal_test.dart style:
// scripts/teammate_picker.sh runs end-to-end with a stubbed `gh` on PATH
// serving the open-PR list (the stub fails loudly on unknown commands so
// script drift turns red).
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('teammate-picker-');

/// One stubbed-gh sandbox: `bin/gh` answers `pr list` from `$GH_STUB_DIR`
/// fixtures and logs every invocation to `$GH_LOG_FILE`.
class PickRun {
  PickRun(this.leg, this.output, this.ghLog, this.dir);

  /// The leg the picker derived: 'dev' (pick it) or '' (skip — fix in
  /// flight). This is the picker's entire decision surface.
  final String leg;
  final String output; // stdout+stderr
  final List<String> ghLog;
  final String dir; // fixture dir (debugging)
}

PickRun runPicker(
  String name, {
  required String issue,

  /// Served verbatim as the `gh pr list --json ...` answer (a JSON array;
  /// `null` plants a fixture so broken JSON turns red instead of silently
  /// reading as "no open PRs").
  String? openPrs,

  /// When true the stubbed gh exits 1 on `pr list` (API blip).
  bool prListFails = false,
}) {
  final dir =
      '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}';
  Directory('$dir/bin').createSync(recursive: true);
  File('$dir/bin/gh').writeAsStringSync('''
#!/usr/bin/env bash
echo "\$*" >> "\$GH_LOG_FILE"
if [ "\$1" = "pr" ] && [ "\$2" = "list" ]; then
  ${prListFails ? 'echo "gh: HTTP 502 (stub API blip)" >&2; exit 1' : 'cat "\$GH_STUB_DIR/open-prs.json"'}
  exit 0
fi
echo "stub: unexpected gh invocation: \$*" >&2
exit 1
''');
  Process.runSync('chmod', ['+x', '$dir/bin/gh']);
  if (openPrs != null) File('$dir/open-prs.json').writeAsStringSync(openPrs);

  final res = Process.runSync(
    'bash',
    [File('scripts/teammate_picker.sh').absolute.path, issue],
    workingDirectory: dir,
    environment: {
      'PATH': '$dir/bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir,
      'GH_LOG_FILE': '$dir/gh.log',
    },
  );
  final out = '${res.stdout}${res.stderr}';
  return PickRun(
    res.exitCode == 0 && out.startsWith('dev') ? 'dev' : '',
    out,
    File('$dir/gh.log').existsSync()
        ? File('$dir/gh.log').readAsLinesSync()
        : <String>[],
    dir,
  );
}

void main() {
  group('gh-2359 AC2 — the picker skips issues with an open referencing PR', () {
    test(
      'THE incident: a HUMAN PR open on issue N -> picker never selects N',
      () {
        final r = runPicker(
          'human-pr',
          issue: '2337',
          openPrs: '''
[
  {"number": 2340, "author": {"login": "IstiN"}, "headRefName": "fix/release-body-cap",
   "body": "Human fix for the same root.\\n\\nFixes #2337"}
]
''',
        );
        expect(
          r.leg,
          isEmpty,
          reason:
              'a human-authored open PR is still a fix in flight — ${r.output}',
        );
        expect(r.output, contains('fix-in-flight'));
        expect(
          r.output,
          contains('#2340 by IstiN'),
          reason: 'the skip notice names the blocking PR and its author',
        );
      },
    );

    test('a machine PR (ai/gh-<n> branch) open on issue N -> skip', () {
      final r = runPicker(
        'machine-pr',
        issue: '2337',
        openPrs: '''
[
  {"number": 2339, "author": {"login": "ai-teammate"}, "headRefName": "ai/gh-2337",
   "body": "Machine fix (branch-linked, no body keyword)."}
]
''',
      );
      expect(r.leg, isEmpty, reason: r.output);
    });

    test('Closes/Resolves keyword variants and `: #n` spacing link too', () {
      final cases = <String, String>{
        'Closes #2337': 'Closes #2337',
        'Resolves: #2337.': 'Resolves: #2337.',
        'lowercase': 'fixes #2337 (lowercase)',
        'newline-separated': 'text before\\n\\nRESOLVES #2337',
      };
      cases.forEach((name, body) {
        final r = runPicker(
          'keyword-$name',
          issue: '2337',
          openPrs:
              '''
[
  {"number": 2400, "author": {"login": "someone"}, "headRefName": "patch-1",
   "body": "$body"}
]
''',
        );
        expect(r.leg, isEmpty, reason: 'body: $name -> ${r.output}');
      });
    });

    test('no false positive: #23370 does not link issue 2337', () {
      final r = runPicker(
        'number-prefix',
        issue: '2337',
        openPrs: '''
[
  {"number": 2401, "author": {"login": "someone"}, "headRefName": "patch-1",
   "body": "See discussion on #23370 and fixes #23370."}
]
''',
      );
      expect(r.leg, 'dev', reason: r.output);
    });

    test('unrelated open PRs do not block the pick', () {
      final r = runPicker(
        'unrelated',
        issue: '2337',
        openPrs: '''
[
  {"number": 2300, "author": {"login": "IstiN"}, "headRefName": "feat/other",
   "body": "Fixes #2301"},
  {"number": 2301, "author": {"login": "ai-teammate"}, "headRefName": "ai/gh-2301",
   "body": ""}
]
''',
      );
      expect(r.leg, 'dev', reason: r.output);
    });

    test('an issue with NO open PR picks normally (dev)', () {
      final r = runPicker('clean', issue: '2337', openPrs: '[]');
      expect(r.leg, 'dev', reason: r.output);
      expect(r.output, isNot(contains('fix-in-flight')));
    });

    test('a CLOSED PR no longer blocks (marker cleared, issue pickable)', () {
      final r = runPicker(
        'closed-pr',
        issue: '2337',
        // gh pr list --state open serves only open PRs — a merged/closed
        // fix PR is absent, which IS the fixture shape here.
        openPrs: '[]',
      );
      expect(r.leg, 'dev', reason: r.output);
    });

    test('lookup failure fails CLOSED (skip the pick, warn, exit 0)', () {
      final r = runPicker('api-blip', issue: '2337', prListFails: true);
      expect(
        r.leg,
        isEmpty,
        reason: 'a duplicate fix is worse than a delayed one — ${r.output}',
      );
      expect(r.output, contains('::warning::'));
      expect(r.output.trim(), isNot(contains('dev')));
    });

    test(
      'the ai-teammate gate wires the picker into the fresh-dev handoff',
      () {
        final wf = File('.github/workflows/ai-teammate.yml').readAsStringSync();
        expect(
          wf.contains('bash scripts/teammate_picker.sh'),
          isTrue,
          reason: 'the gate must run the picker guard on the assigned event',
        );
        expect(
          wf.contains("bash scripts/teammate_picker.sh \"\${ISSUE_NUMBER}\""),
          isTrue,
          reason: 'the guard is scoped to the issue being picked',
        );
        // The picker runs INSIDE the human-assignee gate branch (dev fires
        // only when ai-teammate is the sole assignee, #693) — the picker
        // call must sit after that check, not replace it.
        final humanCheck = wf.indexOf('HUMAN=\$(gh api');
        final pickerCall = wf.indexOf('LEG=\$(bash scripts/teammate_picker.sh');
        expect(humanCheck, greaterThanOrEqualTo(0));
        expect(pickerCall, greaterThan(humanCheck));
        // Dispatch legs (review/rework on an EXISTING PR) must stay unguarded:
        // the picker may only ride the assigned-event branch.
        final dispatchCase = wf.indexOf('workflow_dispatch)');
        final assignedCase = wf.indexOf('"issues"');
        final issuesBranch = wf.indexOf('if [ "\$ACTION" = "assigned" ]; then');
        expect(
          issuesBranch,
          greaterThan(assignedCase),
          reason: 'the guard lives in the issues branch of the case',
        );
        expect(dispatchCase, greaterThanOrEqualTo(0));
      },
    );
  });
}
