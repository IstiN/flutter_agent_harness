// SM CI Gate waiter - behavioral + structural pins for the `sm-validation`
// leg of .github/workflows/ci-gate.yml (the leg the three mirror jobs key
// off).
//
// The waiter script lives INLINE in the workflow. The tests extract the
// real `run:` block from the parsed YAML (single source of truth) and
// drive it through a stubbed `gh` that serves GitHub-shaped fixtures
// through the script's REAL jq expression.
//
// Stub knobs (env):
//   GH_STUB_RAW_FAIL_FIRST  - first N GETs fail at the transport level
//                             (empty response -> the script's api-fail path)
//   GH_STUB_RUNS2_AFTER     - GET N onwards serves runs2.json
//
// The script's loop clock is $SECONDS (real time); an instant `sleep`
// stub plus a small WAIT_OVERRIDE (the test swaps the literal 5100
// deadline for it) bounds every deadline spin to ~1-2s.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const gateYmlPath = '.github/workflows/ci-gate.yml';

/// The real waiter script, extracted from the parsed workflow YAML.
late String waiterScript;
late YamlMap gate;

late Directory _fixtureRoot;

String iso(int seconds) =>
    DateTime.utc(2026, 9, 22)
        .add(Duration(seconds: seconds))
        .toIso8601String()
        .replaceAll('.000', '');

Map<String, Object?> run(String status, String? conclusion, {int ageSec = 0}) =>
    {
      'status': status,
      'conclusion': conclusion,
      'created_at': iso(-ageSec),
    };

String runsDoc(List<Map<String, Object?>> runs) =>
    jsonEncode({'workflow_runs': runs});

class Watch {
  final int exitCode;
  final String out;
  final String verdict; // GITHUB_OUTPUT content
  Watch(this.exitCode, this.out, this.verdict);
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
      'SHA': '446836ec446836ec446836ec446836ec446836ec',
      ...env,
    },
  );
  return Watch(
    res.exitCode,
    '${res.stdout}${res.stderr}',
    File(outFile).readAsStringSync(),
  );
}

void main() {
  setUpAll(() {
    gate = loadYaml(File(gateYmlPath).readAsStringSync()) as YamlMap;
    final raw =
        ((gate['jobs'] as YamlMap)['sm-validation'] as YamlMap)['steps']
            as YamlList;
    final script = (raw.first as YamlMap)['run'] as String;
    // The only mutation: swap the literal deadline for an env-overridable
    // one so deadline tests finish in seconds. A structural pin below
    // asserts the YAML really contains 'SECONDS + 5100'.
    expect(script, contains('SECONDS + 5100'),
        reason: 'deadline literal moved - update the extraction swap');
    waiterScript = script.replaceAll('SECONDS + 5100', 'SECONDS + \${WAIT_OVERRIDE:-5100}');
    _fixtureRoot = Directory.systemTemp.createTempSync('await-sm-ci-');
  });

  YamlMap job(String id) =>
      (gate['jobs'] as YamlMap)[id] as YamlMap;

  group('terminal-state routing — fast verdicts never eat the tolerance', () {
    for (final c in ['success', 'failure', 'timed_out', 'startup_failure', 'action_required']) {
      test('$c reports at poll 1 (red/green in seconds)', () {
        final w = runWatch('fast-$c', {
          'runs.json': runsDoc([run('completed', c, ageSec: 1)]),
          'WAIT_OVERRIDE': '2',
        });
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
        'WAIT_OVERRIDE': '2',
      });
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
    });

    test('cancelled debris never masks the older red - the red verdict stands', () {
      final w = runWatch('debris-over-red', {
        'runs.json': runsDoc([
          run('completed', 'cancelled', ageSec: 30),
          run('completed', 'failure', ageSec: 90),
        ]),
        'WAIT_OVERRIDE': '2',
      });
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=failure\n');
    });

    test('an in-flight rerun outranks the older green — and flips the verdict when red', () {
      final rerunGreen = runWatch('rerun-green', {
        'runs.json': runsDoc([
          run('in_progress', null, ageSec: 30),
          run('completed', 'success', ageSec: 90),
        ]),
        'runs2.json': runsDoc([run('completed', 'success', ageSec: 30)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '3', 'WAIT_OVERRIDE': '2'});
      expect(rerunGreen.verdict, 'conclusion=success\n');
      expect(rerunGreen.exitCode, 0);

      final rerunRed = runWatch('rerun-red', {
        'runs.json': runsDoc([
          run('in_progress', null, ageSec: 30),
          run('completed', 'success', ageSec: 90),
        ]),
        'runs2.json': runsDoc([run('completed', 'failure', ageSec: 30)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '3', 'WAIT_OVERRIDE': '2'});
      expect(rerunRed.verdict, 'conclusion=failure\n');
      expect(rerunRed.exitCode, 0);
    });

    test('slow pool: queued run resolving after many polls still lands green', () {
      final w = runWatch('slow-pool', {
        'runs.json': runsDoc([run('queued', null, ageSec: 1)]),
        'runs2.json': runsDoc([run('completed', 'success', ageSec: 1)]),
      }, env: const {'GH_STUB_RUNS2_AFTER': '5', 'WAIT_OVERRIDE': '30'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
    });
  });

  group('degraded paths are surfaced, never silent', () {
    test('api-level poll failures keep polling and recover on the next success', () {
      final w = runWatch('api-fail', {
        'runs.json': runsDoc([run('completed', 'success', ageSec: 1)]),
      }, env: const {'GH_STUB_RAW_FAIL_FIRST': '1', 'WAIT_OVERRIDE': '2'});
      expect(w.exitCode, 0);
      expect(w.verdict, 'conclusion=success\n');
    });

    test('deadline expiry keeps the human signal: loud error, empty verdict', () {
      final w = runWatch('sm-dead', {
        'runs.json': '{"workflow_runs":[]}',
      }, env: const {'WAIT_OVERRIDE': '2'});
      expect(w.exitCode, 1);
      expect(w.verdict, '');
      expect(w.out, contains('::error::SM-dispatched validation did not conclude within 85 min'));
    });
  });

  group('structural contract — ci-gate.yml', () {
    test('waiter keeps the widened window and debris-proof selection', () {
      final w = job('sm-validation');
      expect(w['timeout-minutes'], 90, reason: 'job timeout must bound the 85-min poll window');
      final script = ((w['steps'] as YamlList).first as YamlMap)['run'] as String;
      expect(script, contains('per_page=30'), reason: 'selection must see past wave debris');
      expect(script, isNot(contains('per_page=1')));
      expect(script, contains('SECONDS + 5100'), reason: '85-min poll window');
      expect(script, isNot(contains('cancelled|')), reason: 'cancelled must never be a verdict');
      expect(script, isNot(contains('. == "cancelled"')));
      expect(script, isNot(contains('. == "skipped"')));
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
