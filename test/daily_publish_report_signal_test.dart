// gh-1478 — daily-publish self-filer: signal-first failure excerpts,
// cancelled-run digests, root-cause dedup (2026-10-10 morning incidents:
// #1472 cancelled leg filed an empty shrug, #1473 quoted the pub.dev
// file-tree listing while the real server message sat one screen above,
// and #1473 re-filed a root cause already open as #1452).
//
// Behavioral coverage in the release_flow_race_test.dart style: stubbed
// `gh` on PATH answering run-view/search/issue calls from per-test fixture
// files (the stub fails loudly on unknown commands so script drift turns
// red), then scripts/daily_publish_report.sh run end-to-end with the LEG_*
// env wiring the daily-publish.yml report job sets.
import 'dart:io';

import 'package:test/test.dart';

final _fixtureRoot = Directory.systemTemp.createTempSync('daily-report-');

/// One stubbed-gh sandbox: `bin/gh` answers from `$GH_STUB_DIR` fixtures
/// and logs every invocation to `$GH_LOG_FILE`.
class ReportRun {
  ReportRun(
    this.exitCode,
    this.output,
    this.summary,
    this.ghLog,
    this.createdBody,
    this.comments,
    this.dir,
  );

  final int exitCode;
  final String output; // stdout+stderr of the report script
  final String summary; // GITHUB_STEP_SUMMARY content
  final List<String> ghLog; // every stubbed gh invocation
  final String createdBody; // body of the created issue ('' = none created)
  final String comments; // concatenated comment bodies per issue
  final String dir; // fixture dir (debugging)

  bool get created => createdBody.isNotEmpty;
  bool get commented => comments.isNotEmpty;
}

/// Fixture logs: the pub.dev publish step's log whose TAIL is a file-tree
/// listing while the real failure (`Message from server`) sits well above
/// the 50-line tail window (the #1473 shape).
const _treeNoiseLog = '''
Publishing flutter_agent_harness 0.1.497 to https://pub.dev:
├── analysis_options.yaml (412 bytes)
├── CHANGELOG.md (262300 bytes)
├── LICENSE (1077 bytes)
├── README.md (11804 bytes)
├── pubspec.yaml (3891 bytes)
├── bin/fah.dart (3122 bytes)
├── lib/flutter_agent_harness.dart (2411 bytes)
├── lib/src/agent/agent_loop.dart (8291 bytes)
├── lib/src/agent/tool_pairing.dart (4102 bytes)
├── lib/src/cli/agent_cli.dart (9122 bytes)
├── lib/src/compaction/auto_compactor.dart (5211 bytes)
├── lib/src/hashline/hashline_patcher.dart (3111 bytes)
├── lib/src/messaging/messaging.dart (4111 bytes)
├── lib/src/redact/redaction_pipeline.dart (6111 bytes)
├── lib/src/session/session.dart (7111 bytes)
├── lib/src/skills/skills.dart (5111 bytes)
├── lib/src/tools/builtin_tools.dart (8111 bytes)
├── lib/src/trajectory/trajectory.dart (4111 bytes)
├── test/agent_loop_test.dart (5111 bytes)
├── test/tool_pairing_test.dart (4111 bytes)
├── test/hashline_test.dart (3111 bytes)
├── test/messaging_test.dart (4111 bytes)
├── test/redaction_test.dart (3111 bytes)
├── test/session_test.dart (4111 bytes)
├── test/skills_test.dart (3111 bytes)
├── test/trajectory_test.dart (3111 bytes)
Uploading...
Message from server: CHANGELOG.md exceeds the maximum content length (262144 bytes)
├── example/main.dart (2111 bytes)
├── docs/ci.md (3111 bytes)
├── docs/hep.md (2111 bytes)
├── site/index.html (4111 bytes)
├── blog/day1.md (1111 bytes)
├── flutter_app/pubspec.yaml (2111 bytes)
├── flutter_app/lib/main.dart (3111 bytes)
├── office_addin/manifest.xml (2111 bytes)
├── browser_ext/manifest.json (1111 bytes)
├── schema/config.schema.json (2111 bytes)
├── prompts/cli/finalize_gate.md (2111 bytes)
├── scripts/daily_publish_report.sh (8111 bytes)
├── scripts/daily_plan.sh (3111 bytes)
├── .github/workflows/daily-publish.yml (4111 bytes)
└── z_last_tree_noise.dart (42 bytes)
''';

/// The inject_failure shape: a failed leg job (no child run) whose per-job
/// log carries the injected ::error:: annotation line.
const _injectedFailureLog = '''
Leg: pub.dev	Checkout	2026-10-10T05:17:10.0000000Z Syncing repository: IstiN/flutter_agent_harness
Leg: pub.dev	Inject failure (test)	2026-10-10T05:17:12.0000000Z ::error::injected failure (inject_failure=pubdev) — exercising the self-filing issue path, nothing published
Leg: pub.dev	Inject failure (test)	2026-10-10T05:17:12.0000000Z ##[error]Process completed with exit code 1.
''';

/// Plain progress noise — no signal line at all (tail-fallback shape).
final _noSignalLog = List<String>.generate(
  80,
  (i) => 'progress line ${i + 1}: checking repository state',
).join('\n');

/// Minimal daily-publish.yml shape for the timeout-ceiling lookup.
const _workflowYaml = '''
name: Daily auto-publish
on:
  schedule:
    - cron: '17 5 * * *'
jobs:
  plan:
    name: Plan (change detection + versions)
    runs-on: ubuntu-latest
    timeout-minutes: 10
  testflight:
    name: 'Leg: TestFlight'
    runs-on: ubuntu-latest
    timeout-minutes: 360
  play:
    name: 'Leg: Play (Android external beta)'
    runs-on: ubuntu-latest
    timeout-minutes: 240
  pubdev:
    name: 'Leg: pub.dev'
    runs-on: ubuntu-latest
    timeout-minutes: 60
  cli:
    name: 'Leg: CLI + macOS desktop'
    runs-on: ubuntu-latest
    timeout-minutes: 360
  website:
    name: 'Leg: Website'
    runs-on: ubuntu-latest
    timeout-minutes: 180
  addin:
    name: 'Leg: Outlook add-in'
    runs-on: ubuntu-latest
    timeout-minutes: 150
''';

/// jobs-API fixture for the daily run 555 (own-run paths: cancelled digest,
/// per-job log resolution).
const _run555Jobs = '''
{
  "jobs": [
    {"databaseId": 1, "name": "Plan (change detection + versions)", "conclusion": "success", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T05:18:00Z"},
    {"databaseId": 11, "name": "Leg: TestFlight", "conclusion": "cancelled", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T11:16:53Z"},
    {"databaseId": 12, "name": "Leg: Play (Android external beta)", "conclusion": "success", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T06:00:00Z"},
    {"databaseId": 22, "name": "Leg: pub.dev", "conclusion": "failure", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T05:18:00Z"},
    {"databaseId": 13, "name": "Leg: CLI + macOS desktop", "conclusion": "success", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T10:00:00Z"},
    {"databaseId": 14, "name": "Leg: Website", "conclusion": "success", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T05:45:00Z"},
    {"databaseId": 15, "name": "Leg: Outlook add-in", "conclusion": "success", "startedAt": "2026-10-10T05:17:00Z", "completedAt": "2026-10-10T05:40:00Z"}
  ]
}
''';

void _installStub(String bin) {
  File('$bin/gh').writeAsStringSync(r'''
#!/usr/bin/env bash
# gh-1478 fixture stub. Serves $GH_STUB_DIR fixtures:
#   run view <id> --json jobs [--jq F]   -> run-<id>.json (jq applied)
#   run view <id> --log[-failed]         -> failed-log-<id>.txt (empty when absent)
#   run view --job <id> --log            -> failed-log-job-<id>.txt (empty when absent)
#   search issues <q> --jq F             -> search.json (loud error when absent)
#   issue list --json .. [--jq F]        -> issues.json (absent = no open issues)
#   issue create --body-file F           -> body copied to created.md, URL echoed
#   issue comment <n> --body-file F      -> body appended to comments.md
# Every invocation is logged to $GH_LOG_FILE; unknown commands fail loudly.
echo "$*" >> "$GH_LOG_FILE"
cmd="$1"; shift || true
case "$cmd" in
  run)
    sub="$1"; shift || true
    if [ "$sub" != "view" ]; then
      echo "stub: unexpected gh invocation: run $sub $*" >&2; exit 1
    fi
    id=""; job=""; jqf=""; mode="json"
    while [ $# -gt 0 ]; do
      case "$1" in
        --job) job="$2"; shift 2 ;;
        --jq) jqf="$2"; shift 2 ;;
        --repo|--ref) shift 2 ;;
        --json) shift 2 ;;
        --log|--log-failed) mode="log"; shift ;;
        -*) shift ;;
        *) id="$1"; shift ;;
      esac
    done
    if [ "$mode" = "log" ]; then
      if [ -n "$job" ]; then
        f="$GH_STUB_DIR/failed-log-job-$job.txt"
      else
        f="$GH_STUB_DIR/failed-log-$id.txt"
      fi
      [ -f "$f" ] && cat "$f"
      exit 0
    fi
    f="$GH_STUB_DIR/run-$id.json"
    [ -f "$f" ] || { echo "stub: no fixture $f" >&2; exit 1; }
    if [ -n "$jqf" ]; then jq -r "$jqf" "$f"; else cat "$f"; fi
    ;;
  search)
    sub="$1"; shift || true
    if [ "$sub" != "issues" ]; then
      echo "stub: unexpected gh invocation: search $sub $*" >&2; exit 1
    fi
    jqf="."
    while [ $# -gt 0 ]; do
      case "$1" in
        --jq) jqf="$2"; shift 2 ;;
        --repo|--state|--match|--limit) shift 2 ;;
        --json) shift 2 ;;
        *) shift ;;
      esac
    done
    f="$GH_STUB_DIR/search.json"
    [ -f "$f" ] || { echo "stub: no search.json fixture" >&2; exit 1; }
    jq -r "$jqf" "$f"
    ;;
  issue)
    sub="$1"; shift || true
    case "$sub" in
      list)
        jqf="."
        while [ $# -gt 0 ]; do
          case "$1" in
            --jq) jqf="$2"; shift 2 ;;
            --repo|--state|--label|--limit) shift 2 ;;
            --json) shift 2 ;;
            *) shift ;;
          esac
        done
        f="$GH_STUB_DIR/issues.json"
        if [ -f "$f" ]; then jq -r "$jqf" "$f"; else echo '[]' | jq -r "$jqf"; fi
        ;;
      create)
        body=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        [ -n "$body" ] && [ -f "$body" ] && cp "$body" "$GH_STUB_DIR/created.md"
        echo "https://github.com/OWNER/REPO/issues/99"
        ;;
      comment)
        num="$1"; shift || true
        body=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --body-file) body="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        if [ -n "$body" ] && [ -f "$body" ]; then
          {
            echo "── comment on #$num ──"
            cat "$body"
          } >> "$GH_STUB_DIR/comments.md"
        fi
        ;;
      close)
        : # logged by the stub preamble; nothing to serve
        ;;
      *) echo "stub: unexpected gh invocation: issue $sub $*" >&2; exit 1 ;;
    esac
    ;;
  label) exit 0 ;;
  *) echo "stub: unexpected gh invocation: $cmd $*" >&2; exit 1 ;;
esac
''');
  Process.runSync('chmod', ['+x', '$bin/gh']);
}

/// Runs scripts/daily_publish_report.sh with [legResults] (e.g.
/// `{'pubdev': 'failure'}`), [legUrls] (child run links) and [fixtures]
/// (extra $GH_STUB_DIR files: failed logs, run-555.json, search.json,
/// issues.json, ...). All legs default to `skipped`; the pubdev success
/// override defaults to up-to-date.
ReportRun runReport(
  String name, {
  Map<String, String> legResults = const {},
  Map<String, String> legUrls = const {},
  Map<String, String> fixtures = const {},
  bool withWorkflowYaml = false,
  String pubdevStatusOverride = 'up-to-date',
}) {
  final dir =
      '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}';
  Directory('$dir/bin').createSync(recursive: true);
  _installStub('$dir/bin');
  if (withWorkflowYaml) {
    File('$dir/daily-publish.yml').writeAsStringSync(_workflowYaml);
  }
  fixtures.forEach((k, v) => File('$dir/$k').writeAsStringSync(v));

  final env = <String, String>{
    'PATH': '$dir/bin:${Platform.environment['PATH']}',
    'GITHUB_REPOSITORY': 'OWNER/REPO',
    'GITHUB_RUN_ID': '555',
    'GITHUB_SERVER_URL': 'https://github.com',
    'GH_TOKEN': 'stub',
    'GH_STUB_DIR': dir,
    'GH_LOG_FILE': '$dir/gh.log',
    'GITHUB_STEP_SUMMARY': '$dir/summary.md',
    'NEXT_TAG': 'v9.9.9',
    'DAILY_PUBLISH_ASSIGNEE': 'ai-teammate',
    'PLAN_RESULT': 'success',
    for (final leg in const [
      'TESTFLIGHT',
      'PLAY',
      'PUBDEV',
      'CLI',
      'WEBSITE',
      'ADDIN',
    ])
      'LEG_$leg': legResults[leg.toLowerCase()] ?? 'skipped',
    ...legUrls.map((k, v) => MapEntry('LEG_${k.toUpperCase()}_URL', v)),
    if (legResults['pubdev'] == 'success') ...{
      'LEG_PUBDEV_PUBSPEC': '0.1.497',
      'LEG_PUBDEV_PUBLISHED': '0.1.496',
      'LEG_PUBDEV_STATUS': pubdevStatusOverride,
    },
    if (withWorkflowYaml) 'DAILY_PUBLISH_WORKFLOW': '$dir/daily-publish.yml',
  };

  final res = Process.runSync(
    'bash',
    [File('scripts/daily_publish_report.sh').absolute.path],
    workingDirectory: dir,
    environment: env,
  );
  return ReportRun(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File('$dir/summary.md').existsSync()
        ? File('$dir/summary.md').readAsStringSync()
        : '',
    File('$dir/gh.log').existsSync()
        ? File('$dir/gh.log').readAsLinesSync()
        : <String>[],
    File('$dir/created.md').existsSync()
        ? File('$dir/created.md').readAsStringSync()
        : '',
    File('$dir/comments.md').existsSync()
        ? File('$dir/comments.md').readAsStringSync()
        : '',
    dir,
  );
}

void main() {
  // ── AC1 — signal-first excerpt over tree noise (#1473) ──────────────────
  group('signal-first excerpt', () {
    test('tree-noise child log -> quotes the server message, not the tree tail',
        () {
      final r = runReport(
        'tree-noise',
        legResults: const {'pubdev': 'failure'},
        legUrls: const {'pubdev': 'https://github.com/OWNER/REPO/actions/runs/777'},
        fixtures: const {'failed-log-777.txt': _treeNoiseLog},
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.created, isTrue, reason: 'a failing leg files an issue: ${r.output}');
      expect(r.createdBody,
          contains('Message from server: CHANGELOG.md exceeds the maximum '
              'content length (262144 bytes)'),
          reason: 'the signal line must be quoted, not the tree tail');
      expect(r.createdBody, isNot(contains('z_last_tree_noise.dart')),
          reason: 'the raw tail is tree noise and must not dominate the digest');
      // The normalized signature is embedded for future root-cause dedup.
      expect(
        r.createdBody,
        contains('daily-publish-sig: CHANGELOG.md exceeds the maximum content '
            'length (262144 bytes)'),
        reason: 'the server message is the root-cause signature',
      );
    });

    test('priority order: ::error:: beats a later Message from server', () {
      final log = '''
first noise line
plain progress
Message from server: some secondary complaint
more noise
::error::primary injected failure (inject_failure=play) — nothing dispatched
final noise line
''';
      final r = runReport(
        'priority',
        legResults: const {'play': 'failure'},
        legUrls: const {'play': 'https://github.com/OWNER/REPO/actions/runs/888'},
        fixtures: {'failed-log-888.txt': log},
      );
      expect(r.created, isTrue, reason: r.output);
      // The signature comes from the highest-priority signal (::error::)...
      expect(r.createdBody,
          contains('daily-publish-sig: primary injected failure'));
      expect(r.createdBody, isNot(contains('daily-publish-sig: Message from server')));
      // ...while the excerpt still quotes the first matches with context.
      expect(r.createdBody, contains('Message from server: some secondary complaint'));
      expect(r.createdBody, contains('::error::primary injected failure'));
    });

    test('no signal line at all -> raw tail fallback', () {
      final r = runReport(
        'tail-fallback',
        legResults: const {'website': 'failure'},
        legUrls: const {'website': 'https://github.com/OWNER/REPO/actions/runs/889'},
        fixtures: {'failed-log-889.txt': _noSignalLog},
      );
      expect(r.created, isTrue, reason: r.output);
      expect(r.createdBody, contains('progress line 80'),
          reason: 'without a signal line the excerpt is the raw tail');
      expect(r.createdBody, isNot(contains('progress line 10')),
          reason: 'the fallback tail is bounded');
      expect(r.createdBody, isNot(contains('Error signature')),
          reason: 'no signature is derived from noise');
      expect(
        r.ghLog.where((l) => l.contains('search issues')),
        isEmpty,
        reason: 'no signature -> no root-cause search',
      );
    });
  });

  // ── AC2 — cancelled-run digest: job + timeout ceiling + elapsed (#1472) ─
  group('cancelled-run digest', () {
    test('cancelled leg -> dedicated section with job, ceiling, elapsed', () {
      final r = runReport(
        'cancelled-leg',
        legResults: const {'testflight': 'cancelled'},
        fixtures: const {
          'run-555.json': _run555Jobs,
          'failed-log-job-11.txt': 'checkout noise\nmid-checkout kill point',
        },
        withWorkflowYaml: true,
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.created, isTrue, reason: r.output);
      // Which job was in flight, its timeout-minutes, elapsed-vs-ceiling —
      // the #1472 empty-shrug class must be gone.
      expect(r.createdBody, contains('Cancelled while running'));
      expect(r.createdBody, contains('Leg: TestFlight'));
      expect(r.createdBody, contains('5h59m53s'),
          reason: '05:17:00Z -> 11:16:53Z elapsed');
      expect(r.createdBody, contains('360'),
          reason: 'the timeout-minutes ceiling from daily-publish.yml');
      expect(r.createdBody, isNot(contains('(no failed-step log available')),
          reason: 'the cancelled leg job log IS served per-job mid-run');
      expect(r.createdBody, contains('mid-checkout kill point'));
      expect(r.summary, contains('⚠️'));
    });

    test('cancelled digest degrades gracefully without the workflow file', () {
      final r = runReport(
        'cancelled-no-yaml',
        legResults: const {'testflight': 'cancelled'},
        fixtures: const {'run-555.json': _run555Jobs},
      );
      expect(r.created, isTrue, reason: r.output);
      expect(r.createdBody, contains('Leg: TestFlight'));
      expect(r.createdBody, contains('5h59m53s'));
      // No ceiling known -> say so, never invent one.
      expect(r.createdBody, isNot(contains('timeout ceiling')));
    });
  });

  // ── AC3 — root-cause dedup by normalized signature (#1473 vs #1452) ─────
  group('root-cause dedup', () {
    test('open issue carrying the same signature -> comment, not a new issue',
        () {
      final r = runReport(
        'sig-dedup',
        legResults: const {'pubdev': 'failure'},
        legUrls: const {'pubdev': 'https://github.com/OWNER/REPO/actions/runs/777'},
        fixtures: const {
          'failed-log-777.txt': _treeNoiseLog,
          // #1452: the CHANGELOG > 256 KiB root cause is already open.
          'search.json': '[{"number": 1452}]',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.created, isFalse,
          reason: 'a signature match must not file a symptom duplicate');
      expect(
        r.ghLog.where((l) => l.contains('issue comment 1452')),
        hasLength(1),
        reason: 'the digest lands as a comment on the root-cause issue',
      );
      expect(r.comments, contains('Root-cause dedup'));
      expect(r.comments, contains('#1452'));
      expect(
        r.comments,
        contains('Message from server: CHANGELOG.md exceeds the maximum '
            'content length (262144 bytes)'),
        reason: 'the comment still carries the full digest',
      );
      expect(
        r.comments,
        contains('https://github.com/OWNER/REPO/actions/runs/777'),
        reason: 'the new run link rides the comment',
      );
      expect(
        r.ghLog.singleWhere((l) => l.contains('search issues')),
        contains('CHANGELOG.md exceeds the maximum content length'),
        reason: 'the search query carries the normalized signature',
      );
    });

    test('gh log line 2+ items: two signal lines both quoted in the dedup comment',
        () {
      final log = '''
noise
::error::first recurring failure (inject_failure=cli) — nothing dispatched
padding
padding
padding
error: second recurring failure: compiler exploded
tail noise
''';
      final r = runReport(
        'sig-dedup-multi',
        legResults: const {'cli': 'failure'},
        legUrls: const {'cli': 'https://github.com/OWNER/REPO/actions/runs/890'},
        fixtures: {
          'failed-log-890.txt': log,
          'search.json': '[{"number": 1400}]',
        },
      );
      expect(r.created, isFalse);
      expect(r.comments, contains('first recurring failure'));
      expect(r.comments, contains('second recurring failure: compiler exploded'),
          reason: 'every signal match in the window is quoted, not just one');
    });
  });

  // ── AC4 — existing lifecycle behavior is unchanged ──────────────────────
  group('existing lifecycle behavior', () {
    test('dedup by open leg issue (title match) still comments, never re-files',
        () {
      final r = runReport(
        'title-dedup',
        legResults: const {'pubdev': 'failure'},
        legUrls: const {'pubdev': 'https://github.com/OWNER/REPO/actions/runs/777'},
        fixtures: const {
          'failed-log-777.txt': _treeNoiseLog,
          'search.json': '[]',
          'issues.json':
              '[{"number": 1400, "title": "[daily-publish] pubdev leg failed"}]',
        },
      );
      expect(r.exitCode, isNot(0), reason: r.output);
      expect(r.created, isFalse);
      expect(r.ghLog.where((l) => l.contains('issue comment 1400')), hasLength(1));
    });

    test('auto-close on green still closes the leg issue', () {
      final r = runReport(
        'auto-close',
        legResults: const {'pubdev': 'success'},
        fixtures: const {
          'issues.json':
              '[{"number": 1401, "title": "[daily-publish] pubdev leg failed"}]',
        },
      );
      expect(r.exitCode, 0, reason: r.output);
      expect(r.created, isFalse);
      expect(r.ghLog.where((l) => l.contains('issue close 1401')), hasLength(1));
    });

    test('all-skipped stays green and files nothing', () {
      final r = runReport('all-skipped');
      expect(r.exitCode, 0, reason: r.output);
      expect(r.created, isFalse);
      expect(r.commented, isFalse);
      expect(r.summary, contains('No issue lifecycle actions'));
    });
  });

  // ── inject_failure shape: failed leg job, no child run, per-job log ─────
  group('inject_failure end-to-end shape', () {
    test('failed leg job log is resolved per-job and the injected ::error:: '
        'line is quoted + signed', () {
      final r = runReport(
        'inject-shape',
        legResults: const {'pubdev': 'failure'},
        fixtures: const {
          'run-555.json': _run555Jobs,
          'failed-log-job-22.txt': _injectedFailureLog,
        },
      );
      expect(r.created, isTrue, reason: r.output);
      expect(
        r.createdBody,
        contains('injected failure (inject_failure=pubdev)'),
        reason: 'the filed digest quotes the injected error line verbatim — '
            'this is what the workflow verify step asserts',
      );
      expect(
        r.createdBody,
        contains('daily-publish-sig: injected failure (inject_failure=pubdev)'),
        reason: 'gh log prefixes (job/step/timestamp) are stripped from the '
            'signature',
      );
    });
  });

  // ── wiring — the workflow asserts the excerpt, the script ships the bits ─
  group('wiring', () {
    test('daily-publish.yml verifies the injected excerpt, not just issue creation',
        () {
      final daily = File('.github/workflows/daily-publish.yml')
          .readAsStringSync();
      expect(daily, contains('Verify injected-failure excerpt'),
          reason: 'the TEST hook must assert the digest content (gh-1478)');
      expect(daily, contains('inject_failure verify'));
      expect(daily, contains('injected failure (inject_failure='));
    });

    test('report script ships the gh-1478 machinery', () {
      final script =
          File('scripts/daily_publish_report.sh').readAsStringSync();
      for (final needle in [
        'signal_excerpt',
        'error_signature',
        'find_issue_by_signature',
        'cancelled_job_info',
        'leg_ceiling_minutes',
        'daily-publish-sig',
        '--log-failed',
        '--job',
        'search issues',
      ]) {
        expect(script, contains(needle), reason: 'missing: $needle');
      }
    });
  });
}
