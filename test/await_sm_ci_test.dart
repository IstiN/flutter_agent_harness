// SM CI Gate waiter - behavioral + structural pins for the `sm-validation`
// leg of .github/workflows/ci-gate.yml (the leg the three mirror jobs key
// off).
//
// The waiter script lives INLINE in the workflow. The tests extract the
// real `run:` block from the parsed YAML (single source of truth) and
// drive it VERBATIM (no textual mutation) through a stubbed `gh` that
// serves GitHub-shaped fixtures through the script's REAL jq expression.
//
// Stub knobs (env):
//   GH_STUB_RAW_FAIL_FIRST  - first N GETs fail at the transport level
//                             (empty response -> the script's api-fail path)
//   GH_STUB_RUNS2_AFTER     - GET N onwards serves runs2.json
//
// Script knobs the tests drive through real env (no script rewriting):
//   WAIT_SECONDS, STALE_PENDING_SECONDS - tiny values bound every
//   deadline spin to ~1-2s (the loop clock is $SECONDS; `sleep` is
//   stubbed to an instant no-op).
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const gateYmlPath = '.github/workflows/ci-gate.yml';

/// The real waiter script, extracted verbatim from the parsed workflow YAML.
late String waiterScript;
late YamlMap gate;

late Directory _fixtureRoot;

/// `created_at` for a run that started [seconds] before NOW, so the
/// script's real `date +%s`-based staleness arithmetic sees realistic ages.
/// Second precision: jq's fromdateiso8601 accepts nothing finer.
String iso(int seconds) {
  final t = DateTime.now().toUtc().subtract(Duration(seconds: seconds));
  return '${t.toIso8601String().substring(0, 19)}Z';
}

Map<String, Object?> run(String status, String? conclusion, {int ageSec = 0}) =>
    {
      'status': status,
      'conclusion': conclusion,
      'created_at': iso(ageSec),
    };

String runsDoc(List<Map<String, Object?>> runs) =>
    jsonEncode({'workflow_runs': runs});

class Watch {
  final int exitCode;
  final String out;
  final String verdict; // GITHUB_OUTPUT content
  final String summary; // GITHUB_STEP_SUMMARY content
  Watch(this.exitCode, this.out, this.verdict, this.summary);
}

/// Writes the stub `gh` (and an instant `sleep`) into `<dir>/bin` and
/// returns the bin path for PATH prepending.
String stubGh(String dir) {
  final bin = Directory('$dir/bin')..createSync(recursive: true);
  File('${bin.path}/gh').writeAsStringSync(r'''
#!/usr/bin/env bash
cmd="$1"
jq_arg=""
args=("$@")
for ((i=0; i<$#; i++)); do
  if [ "${args[$i]}" = "--jq" ]; then jq_arg="${args[$((i+1))]}"; fi
done

if [ "$cmd" = "api" ]; then
  calls=$(($(cat "$GH_STUB_DIR/get-calls" 2>/dev/null || echo 0) + 1))
  echo "$calls" > "$GH_STUB_DIR/get-calls"
  if [ "$calls" -le "${GH_STUB_RAW_FAIL_FIRST:-0}" ]; then exit 1; fi
  f="$GH_STUB_DIR/runs.json"
  if [ -n "${GH_STUB_RUNS2_AFTER:-}" ] && [ "$calls" -ge "$GH_STUB_RUNS2_AFTER" ]; then
    f="$GH_STUB_DIR/runs2.json"
  fi
  if [ -n "$jq_arg" ]; then
    jq -r "$jq_arg" "$f" 2>/dev/null
  else
    cat "$f"
  fi
  exit 0
fi
exit 0
''');
  // The script's loop clock is $SECONDS (real time); an instant `sleep`
  // stub keeps deadline spins at wall-clock speed without 30s naps.
  File('${bin.path}/sleep').writeAsStringSync('#!/usr/bin/env bash\nexit 0\n');
  for (final f in ['gh', 'sleep']) {
    Process.runSync('chmod', ['+x', '${bin.path}/$f']);
  }
  return bin.path;
}

Watch runWatch(
  String name,
  Map<String, String> stubFiles, {
  Map<String, String> env = const {},
}) {
  final dir = Directory(
    '${_fixtureRoot.path}/$name-${DateTime.now().microsecondsSinceEpoch}',
  )..createSync(recursive: true);
  final bin = stubGh(dir.path);
  for (final e in stubFiles.entries) {
    File('${dir.path}/${e.key}').writeAsStringSync(e.value);
  }
  final outFile = '${dir.path}/github-output';
  File(outFile).writeAsStringSync('');
  final summaryFile = '${dir.path}/summary.md';
  File(summaryFile).writeAsStringSync('');
  File('${dir.path}/waiter.sh').writeAsStringSync(waiterScript);
  final res = Process.runSync(
    'bash',
    [File('${dir.path}/waiter.sh').absolute.path],
    environment: {
      ...Platform.environment,
      'PATH': '$bin:${Platform.environment['PATH']}',
      'GH_STUB_DIR': dir.path,
      'GITHUB_REPOSITORY': 'OWNER/REPO',
      'GH_TOKEN': 'stub',
      'GITHUB_OUTPUT': outFile,
      'GITHUB_STEP_SUMMARY': summaryFile,
      'SHA': '446836ec446836ec446836ec446836ec446836ec',
      'REF': 'fix/some-branch',
      ...env,
    },
  );
  return Watch(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File(outFile).readAsStringSync(),
    File(summaryFile).readAsStringSync(),
  );
}

int countOf(String haystack, String needle) =>
    needle.isEmpty ? 0 : haystack.split(needle).length - 1;

void main() {
  setUpAll(() {
    gate = loadYaml(File(gateYmlPath).readAsStringSync()) as YamlMap;
    final raw =
        ((gate['jobs'] as YamlMap)['sm-validation'] as YamlMap)['steps']
            as YamlList;
    // No mutation: the script's own knobs (WAIT_SECONDS,
    // STALE_PENDING_SECONDS) make it test-drivable as-is. If this pin
    // fails the script grew a hardcoded deadline again - fix the script.
    waiterScript = raw.first['run'] as String;
    expect(waiterScript, contains('WAIT_SECONDS:-5100'),
        reason: 'deadline must stay env-overridable for test driving');
    _fixtureRoot = Directory.systemTemp.createTempSync('await-sm-ci-');
  });

  YamlMap job(String id) =>
      (gate['jobs'] as YamlMap)[id] as YamlMap;

  group('terminal-state routing — fast verdicts never eat the tolerance', () {
    for (final c in ['success', 'failure', 'timed_out', 'startup_failure', 'action_required']) {
      test('$c reports at poll 1 (red/green in seconds)', () {
        final w = runWatch('fast-$c', {
          'runs.json': runsDoc([run('completed', c, ageSec: 1)]),
        }, env: const {'WAIT_SECONDS': '2'});
        expect(w.exitCode, 0);
        expect(w.verdict, 'conclusion=$c\n');
      });
    }

    test('cancelled debris over an older green resolves green at poll 1', () {
      final w = runWatch('debris-over-green', {
        'runs.json': runsDoc([
          run('completed', 'cancelled', ageSec: 30), // newest: wave debris
          run('completed', 'success', ageSec: 90), // older: real verdict
        ]),
      }, env: const {'WAIT_SECONDS': '2'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
    });

    test('cancelled debris never masks the older red - the red verdict stands', () {
      final w = runWatch('debris-over-red', {
        'runs.json': runsDoc([
          run('completed', 'cancelled', ageSec: 30),
          run('completed', 'failure', ageSec: 90),
        ]),
      }, env: const {'WAIT_SECONDS': '2'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=failure\n');
    });

    test('neutral conclusions are debris too - never a verdict', () {
      final w = runWatch('neutral-debris', {
        'runs.json': runsDoc([
          run('completed', 'neutral', ageSec: 30),
          run('completed', 'success', ageSec: 90),
        ]),
      }, env: const {'WAIT_SECONDS': '2'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
      expect(w.out, isNot(contains('neutral')),
          reason: 'neutral must not even be reported as a candidate');
    });

    test('a lone neutral run never satisfies the gate', () {
      final w = runWatch('neutral-only', {
        'runs.json': runsDoc([run('completed', 'neutral', ageSec: 1)]),
      }, env: const {'WAIT_SECONDS': '2'});
      expect(w.exitCode, 1);
      expect(w.verdict, '');
    });
  });

  group('rerun semantics — an in-flight rerun outranks the older verdict', () {
    test('rerun flips an older green to green when it completes', () {
      final w = runWatch('rerun-green', {
        'runs.json': runsDoc([
          run('in_progress', null, ageSec: 30),
          run('completed', 'success', ageSec: 90),
        ]),
        'runs2.json': runsDoc([run('completed', 'success', ageSec: 30)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '3', 'WAIT_SECONDS': '2'});
      expect(w.verdict, 'conclusion=success\n');
      expect(w.exitCode, 0);
    });

    test('rerun flips an older green to red when it completes red', () {
      final w = runWatch('rerun-red', {
        'runs.json': runsDoc([
          run('in_progress', null, ageSec: 30),
          run('completed', 'success', ageSec: 90),
        ]),
        'runs2.json': runsDoc([run('completed', 'failure', ageSec: 30)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '3', 'WAIT_SECONDS': '2'});
      expect(w.verdict, 'conclusion=failure\n');
      expect(w.exitCode, 0);
    });

    test('slow pool: queued run resolving after many polls still lands green', () {
      final w = runWatch('slow-pool', {
        'runs.json': runsDoc([run('queued', null, ageSec: 1)]),
        'runs2.json': runsDoc([run('completed', 'success', ageSec: 1)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '5', 'WAIT_SECONDS': '30'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
    });
  });

  group('staleness cap — a wedged pending run stops blocking', () {
    test('wedged pending over an older green accepts the green, with a summary note', () {
      final w = runWatch('wedged-over-green', {
        'runs.json': runsDoc([
          run('in_progress', null, ageSec: 3600), // wedged rerun
          run('completed', 'success', ageSec: 7200), // older green
        ]),
      }, env: const {'WAIT_SECONDS': '2', 'STALE_PENDING_SECONDS': '60'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
      expect(w.out, contains('stale pending'));
      expect(w.summary, contains('accepted older verdict'));
    });

    test('wedged pending with no verdict escalates once, keeps polling, fails loud', () {
      final w = runWatch('wedged-no-verdict', {
        'runs.json': runsDoc([run('in_progress', null, ageSec: 3600)]),
      }, env: const {'WAIT_SECONDS': '2', 'STALE_PENDING_SECONDS': '60'});
      expect(w.exitCode, 1);
      expect(w.verdict, '');
      expect(w.out, contains('::warning::dispatched run pending'));
      expect(countOf(w.summary, 'wedged queue?'), 1,
          reason: 'the escalation must fire once, not once per poll');
    });
  });

  group('degraded paths are surfaced, never silent', () {
    test('api-level poll failures warn, land a summary note, and recover', () {
      final w = runWatch('api-fail', {
        'runs.json': runsDoc([run('completed', 'success', ageSec: 1)]),
      }, env: const {'GH_STUB_RAW_FAIL_FIRST': '1', 'WAIT_SECONDS': '2'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
      expect(w.out, contains('::warning::dispatch-run poll failed 1x'));
      expect(w.summary, contains('verdicts may lag reality'));
    });

    test('deadline expiry keeps the human signal: loud error, empty verdict', () {
      final w = runWatch('sm-dead', {
        'runs.json': '{"workflow_runs":[]}',
      }, env: const {'WAIT_SECONDS': '2'});
      expect(w.exitCode, 1);
      expect(w.verdict, '');
      expect(w.out, contains('::error::SM-dispatched validation did not conclude within'));
      expect(w.out, contains('(api failures: 0)'),
          reason: 'a clean slow pool must be distinguishable from api breakage');
      expect(w.summary, contains('api_failures=0'));
    });

    test('persistent api failures are counted into the deadline error', () {
      final w = runWatch('api-dead', {
        'runs.json': '{"workflow_runs":[]}',
      }, env: const {'GH_STUB_RAW_FAIL_FIRST': '99999', 'WAIT_SECONDS': '2'});
      expect(w.exitCode, 1);
      expect(w.verdict, '');
      expect(w.out, contains('::warning::dispatch-run poll failed 1x'));
      expect(RegExp(r'\(api failures: [1-9]').hasMatch(w.out), isTrue,
          reason: 'the deadline error must carry a nonzero api-failure count');
      expect(w.summary, isNot(contains('api_failures=0')),
          reason: 'summary must not claim a clean pool when polls kept failing');
    });
  });

  group('summary hygiene — hostile branch names cannot break the summary', () {
    test('refs are sanitized before they reach markdown notes', () {
      final w = runWatch('hostile-ref', {
        'runs.json': runsDoc([run('in_progress', null, ageSec: 3600)]),
      }, env: const {
        'WAIT_SECONDS': '2',
        'STALE_PENDING_SECONDS': '60',
        'REF': "fix/`x`|<y>",
      });
      expect(w.summary, contains('on `fix/_x___y_`'),
          reason: 'sanitized ref must appear in the note');
      expect(w.summary, isNot(contains('fix/`x`')),
          reason: 'the raw ref must never reach the summary');
      expect(w.summary, isNot(contains('<')));
      expect(w.summary, isNot(contains('>')));
    });
  });

  group('structural contract — ci-gate.yml', () {
    test('waiter keeps the widened window, the staleness cap, and debris-proof selection', () {
      final w = job('sm-validation');
      expect(w['timeout-minutes'], 90, reason: 'job timeout must bound the 85-min poll window');
      final step = (w['steps'] as YamlList).first as YamlMap;
      final script = step['run'] as String;
      expect(script, contains('per_page=30'), reason: 'selection must see past wave debris');
      expect(script, isNot(contains('per_page=1')));
      expect(script, contains('WAIT_SECONDS:-5100'), reason: '85-min poll window');
      expect(script, contains('STALE_PENDING_SECONDS:-2400'),
          reason: 'the staleness cap must be present (wedged pending runs bury verdicts)');
      // Verdict whitelist: only real terminal conclusions route; cancelled,
      // skipped and neutral are never named by any comparison, so they can
      // never become a verdict.
      expect(script, contains('conclusion == "success"'));
      expect(script, isNot(contains('== "neutral"')));
      expect(script, isNot(contains('cancelled|')));
      expect(script, isNot(contains('. == "cancelled"')));
      expect(script, isNot(contains('. == "skipped"')));
      // Degraded-path surfacing: poll failures are counted and end up in
      // the deadline error, refs are sanitized before summary notes.
      expect(script, contains(r'(api failures: ${api_fails})'));
      expect(script, contains('ref_display='));
      expect((step['env'] as YamlMap).containsKey('REF'), isTrue,
          reason: 'the head ref must reach the script (sanitized) for summary notes');
    });

    test('mirrors run only on real verdicts: no false red on cancelled waiter, no noise on drafts', () {
      final expected =
          "\${{ !cancelled() && needs.sm-validation.result != 'cancelled' && needs.sm-validation.result != 'skipped' }}";
      final runSteps = <String>[];
      for (final id in ['quality-gate', 'quickjs-integration', 'binaries-smoke']) {
        final j = job(id);
        expect(
          (j['if'] as String).replaceAll(' ', ''),
          expected.replaceAll(' ', ''),
          reason: '$id mirror guard drifted',
        );
        runSteps.add((j['steps'] as YamlList).first['run'] as String);
        expect(j['needs'], 'sm-validation');
      }
      expect(runSteps.length, 3);
      expect(
        runSteps.toSet().length,
        1,
        reason: 'the three mirrors must stay byte-identical to each other',
      );
    });

    test('least privilege: workflow reads actions, drafts skip the waiter', () {
      expect((gate['permissions'] as YamlMap)['actions'], 'read');
      expect((job('sm-validation')['if'] as String), contains('!github.event.pull_request.draft'));
    });
  });
}
