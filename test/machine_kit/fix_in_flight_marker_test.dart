// gh-2359 AC1 — the fix-in-flight marker: when a fix PR opens, its linked
// issue is stamped visibly (label `fix-in-flight` + a comment naming the
// PR and branch); when the PR closes (merged or not), the marker clears.
//
// 2026-11-20 incident: the machine loop opened PR #2339 (ai/gh-2337) for
// the 125k release-body root with NO marker on #2337, and a human PR
// (#2340) for the same root landed in parallel.
//
// Behavioral coverage: scripts/fix_in_flight_marker.sh runs end-to-end
// with a stubbed `gh` on PATH that logs every invocation (the stub fails
// loudly on unknown commands so script drift turns red), plus a workflow
// wiring pin (the yaml must actually call the script on the right
// pull_request triggers).
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('fix-in-flight-');

class MarkerRun {
  MarkerRun(this.exitCode, this.output, this.ghLog, this.comments, this.dir);

  final int exitCode;
  final String output; // stdout+stderr
  final List<String> ghLog; // every stubbed gh invocation
  final String comments; // concatenated comment bodies per issue
  final String dir; // fixture dir (debugging)

  bool get stamped => ghLog.any(
    (l) => l.contains('issue edit') && l.contains('--add-label fix-in-flight'),
  );
  bool get cleared => ghLog.any(
    (l) =>
        l.contains('issue edit') && l.contains('--remove-label fix-in-flight'),
  );
}

MarkerRun runMarker(
  String name, {
  required String action, // opened | reopened | closed
  required String pr,
  String branch = '',
  String body = '',
  String author = 'ai-teammate',
  String merged = 'false',
}) {
  final dir =
      '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}';
  Directory('$dir/bin').createSync(recursive: true);
  File('$dir/bin/gh').writeAsStringSync(r'''
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG_FILE"
cmd="$1"; sub="${2:-}"; shift 2 2>/dev/null || true
case "$cmd" in
  label) exit 0 ;;
  issue)
    case "$sub" in
      edit) : ;; # logged above; the label add/remove is the observable
      comment)
        num="$1"
        bodyf=""; bodytxt=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) bodyf="$2"; shift 2 ;;
            --body) bodytxt="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        {
          echo "── comment on #$num ──"
          if [ -n "$bodyf" ] && [ -f "$bodyf" ]; then cat "$bodyf"; fi
          [ -n "$bodytxt" ] && printf '%s\n' "$bodytxt"
        } >> "$GH_STUB_DIR/comments.md"
        ;;
      *) echo "stub: unexpected gh invocation: issue $sub $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stub: unexpected gh invocation: $cmd $sub $*" >&2; exit 1 ;;
esac
exit 0
''');
  Process.runSync('chmod', ['+x', '$dir/bin/gh']);

  final res = Process.runSync(
    'bash',
    [File('scripts/fix_in_flight_marker.sh').absolute.path],
    workingDirectory: dir,
    environment: {
      'PATH': '$dir/bin:${Platform.environment['PATH']}',
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GH_STUB_DIR': dir,
      'GH_LOG_FILE': '$dir/gh.log',
      'PR_ACTION': action,
      'PR_NUMBER': pr,
      'PR_AUTHOR': author,
      'PR_BRANCH': branch,
      'PR_BODY': body,
      'PR_MERGED': merged,
    },
  );
  return MarkerRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('$dir/gh.log').existsSync()
        ? File('$dir/gh.log').readAsLinesSync()
        : <String>[],
    File('$dir/comments.md').existsSync()
        ? File('$dir/comments.md').readAsStringSync()
        : '',
    dir,
  );
}

void main() {
  group('gh-2359 AC1 — the fix-in-flight marker', () {
    test('machine fix PR opens -> issue stamped + comment names PR+branch', () {
      final r = runMarker(
        'open-branch',
        action: 'opened',
        pr: '2339',
        branch: 'ai/gh-2337',
        body: '',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(
        r.stamped,
        isTrue,
        reason: 'the label must land the moment the PR opens — ${r.output}',
      );
      expect(r.comments, contains('── comment on #2337 ──'));
      expect(r.comments, contains('#2339'));
      expect(r.comments, contains('ai/gh-2337'));
      expect(r.comments, contains('Fix in flight'));
    });

    test('the merge-train body keyword links too (Fixes/Closes/Resolves)', () {
      final r = runMarker(
        'open-body',
        action: 'opened',
        pr: '2400',
        branch: 'human-fix',
        body: 'Rework of the release-body cap.\n\nResolves: #2337',
        author: 'IstiN',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.stamped, isTrue, reason: r.output);
      expect(r.comments, contains('── comment on #2337 ──'));
      expect(r.comments, contains('@IstiN'));
    });

    test('number boundaries: fixing #23370 stamps 23370, never 2337', () {
      final r = runMarker(
        'number-boundary',
        action: 'opened',
        pr: '2401',
        branch: 'patch-1',
        body: 'See fixes #23370 for context.',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.comments, contains('── comment on #23370 ──'));
      expect(
        r.comments,
        isNot(contains('── comment on #2337 ──')),
        reason: 'a number-suffix issue must never bleed into its prefix issue',
      );
    });

    test('a PR with no linkage at all is a clean no-op', () {
      final r = runMarker(
        'no-linkage',
        action: 'opened',
        pr: '2402',
        branch: 'chore/docs',
        body: 'Docs-only PR.',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.stamped, isFalse);
      expect(r.cleared, isFalse);
      expect(r.comments, isEmpty);
    });

    test('close clears the marker and names the outcome (merged)', () {
      final r = runMarker(
        'close-merged',
        action: 'closed',
        pr: '2339',
        branch: 'ai/gh-2337',
        merged: 'true',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.cleared, isTrue, reason: r.output);
      expect(r.stamped, isFalse);
      expect(r.comments, contains('── comment on #2337 ──'));
      expect(r.comments, contains('merged'));
      expect(r.comments, contains('#2339'));
    });

    test('close UNMERGED (superseded) also clears — the issue is pickable', () {
      final r = runMarker(
        'close-unmerged',
        action: 'closed',
        pr: '2340',
        branch: 'fix/release-body-cap',
        body: 'Fixes #2337',
        author: 'IstiN',
        merged: 'false',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.cleared, isTrue, reason: r.output);
      expect(r.comments, contains('closed unmerged'));
    });

    test('multiple linked issues all get the marker', () {
      final r = runMarker(
        'multi-issue',
        action: 'opened',
        pr: '2410',
        branch: 'shared-root',
        body: 'Fixes #2337 and closes #2336',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.comments, contains('── comment on #2336 ──'));
      expect(r.comments, contains('── comment on #2337 ──'));
    });

    test('reopen re-stamps (a reopened PR is in flight again)', () {
      final r = runMarker(
        'reopen',
        action: 'reopened',
        pr: '2339',
        branch: 'ai/gh-2337',
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.stamped, isTrue, reason: r.output);
    });

    test(
      'wiring: fix-in-flight.yml calls the marker on the right triggers',
      () {
        final wf =
            loadYaml(
                  File(
                    '.github/workflows/fix-in-flight.yml',
                  ).readAsStringSync(),
                )
                as YamlMap;
        final on = wf['on'] ?? wf[true]; // yaml 1.1 parses a bare `on` as true
        expect(on, isA<YamlMap>(), reason: 'pull_request trigger must exist');
        final pr = (on as YamlMap)['pull_request'] as YamlMap;
        expect(
          (pr['types'] as YamlList).map((t) => t.toString()),
          containsAll(['opened', 'reopened', 'closed']),
          reason: 'stamp on open/reopen, clear on close — nothing else',
        );
        final perms = wf['permissions'] as YamlMap;
        expect(
          perms['issues'].toString(),
          'write',
          reason: 'label + comment on the issue need issues: write',
        );
        expect(
          perms['contents'].toString(),
          'read',
          reason:
              'actions/checkout needs contents: read — an unlisted scope '
              'drops to none and the checkout fails on EVERY trigger',
        );
        final jobs = wf['jobs'] as YamlMap;
        final mark = jobs['mark'] as YamlMap;
        final steps = mark['steps'] as YamlList;
        expect(
          steps.whereType<YamlMap>().any(
            (s) => s['run'].toString().contains('fix_in_flight_marker.sh'),
          ),
          isTrue,
          reason: 'the workflow is a thin caller of the tested script',
        );
        // Every PR attribute reaches the script through env — never
        // interpolated into the run text (injection-safe wiring).
        final step = steps.whereType<YamlMap>().firstWhere(
          (s) => s['run'].toString().contains('marker'),
        );
        final env = step['env'] as YamlMap;
        for (final key in [
          'PR_ACTION',
          'PR_NUMBER',
          'PR_AUTHOR',
          'PR_BRANCH',
          'PR_BODY',
          'PR_MERGED',
        ]) {
          expect(env.keys, contains(key), reason: 'missing env wiring: $key');
        }
        expect(
          step['run'].toString(),
          isNot(contains('\${{ github.event.pull_request.body')),
          reason: 'PR-controlled text must ride env, not the script text',
        );
      },
    );
  });
}
