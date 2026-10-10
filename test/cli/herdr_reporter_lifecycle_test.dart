// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The herdr pane reporter wired into the live CLI lifecycle (issue #1481):
/// with the pane gate satisfied, a real [AgentCli.run] under the scripted
/// harness reports `idle` at REPL boot (the pane never sits `unknown`),
/// `working` at run start, `idle` at settle, releases exactly once on
/// `/exit`, re-reports (never releases) on an in-process session switch,
/// and stays byte-silent outside herdr — every inert gate combination
/// spawns zero subprocesses through a full run.
///
/// The transport is a recording closure (no herdr binary, no subprocess);
/// the mock provider drives the turns. Canary byte-scans prove nothing but
/// the pinned state vocabulary leaves fa.
@Timeout(Duration(minutes: 2))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

const _canarySecret = 'LIVE_CANARY_hunter2_9f2e';
const _canaryCwd = '/Users/somebody/secret-project';

/// The herdr pane env herdr exports to every pane process (the incident
/// session's shape).
Map<String, String> _paneEnv({
  String env = '1',
  String pane = 'w6:p16',
  String bin = '/opt/homebrew/bin/herdr',
  String? kill,
}) {
  return {
    'HERDR_ENV': env,
    'HERDR_PANE_ID': pane,
    'HERDR_BIN_PATH': bin,
    if (kill != null) 'FA_HERDR': kill,
  };
}

/// The herdr op of a recorded argv: `report-agent`,
/// `report-agent-session`, or `release-agent`.
String _op(List<String> argv) => argv[argv.indexOf('pane') + 1];

int _seqOf(List<String> argv) => int.parse(argv[argv.indexOf('--seq') + 1]);

String? _stateOf(List<String> argv) =>
    argv.contains('--state') ? argv[argv.indexOf('--state') + 1] : null;

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: _canaryCwd);
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  /// Boots the CLI with the pane env [pane] and a recording spawn closure
  /// appending to [reports]; waits for the REPL to be up. Returns the
  /// finisher that exits the REPL and awaits the whole teardown (the
  /// release report is awaited inside it).
  Future<Future<void> Function()> bootCli({
    required Map<String, String> pane,
    required List<List<String>> reports,
    List<List<AssistantMessageEvent>> turns = const [],
    bool gateActive = true,
  }) async {
    final fake = FakeStreamFunction(turns);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        herdrEnvLookup: (name) => pane[name],
        herdrSpawn: (argv) async {
          reports.add(argv);
        },
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa> '));
    if (gateActive) {
      await waitForIt(
        () => reports.any((argv) => _stateOf(argv) == 'idle'),
        reason: 'boot idle report',
      );
    }
    return () async {
      io.sendLine('/exit');
      await run;
    };
  }

  test('IT-1: boot idle → working → idle → release, strictly increasing seq', () async {
    final reports = <List<String>>[];
    final finish = await bootCli(
      pane: _paneEnv(),
      reports: reports,
      turns: [textTurn('hello back')],
    );
    io.sendLine('hello');
    await waitForIt(
      () => reports.any((argv) => _stateOf(argv) == 'working'),
      reason: 'run-start working report',
    );
    await waitForIt(
      () => reports.where((argv) => _stateOf(argv) == 'idle').length >= 2,
      reason: 'post-run idle report',
    );
    await finish();

    expect(reports.map(_op).toList(), [
      'report-agent',
      'report-agent',
      'report-agent',
      'release-agent',
    ]);
    expect(reports.map(_stateOf).toList(), ['idle', 'working', 'idle', null]);
    final seqs = reports.map(_seqOf).toList();
    for (var i = 1; i < seqs.length; i++) {
      expect(seqs[i], greaterThan(seqs[i - 1]), reason: 'seq monotonic');
    }
    expect(reports.where((argv) => _op(argv) == 'release-agent'), hasLength(1));
  });

  test('AC4: the boot report carries the session id + the resume argv once', () async {
    final reports = <List<String>>[];
    final finish = await bootCli(pane: _paneEnv(), reports: reports);
    await finish();

    final boot = reports.first;
    expect(_op(boot), 'report-agent');
    final id = boot[boot.indexOf('--agent-session-id') + 1];
    expect(id, isNotEmpty);
    // The resume argv rides the FIRST report of the session, after `--`,
    // and the state fields stay in front of it (herdr 0.8.2 ignores the
    // tail while state/release still apply — the pinned asymmetry, E6).
    expect(boot.indexOf('--state'), lessThan(boot.indexOf('--')));
    expect(boot.sublist(boot.indexOf('--')), ['--', 'fa', '--session', id]);
    // …and exactly once for the session: the release argv carries no
    // resume block, and no other report ran to repeat it.
    expect(reports.where((argv) => argv.contains('--')), hasLength(1));
  });

  test('IT-3/E5: /session switch re-reports the new session, never releases', () async {
    final reports = <List<String>>[];
    final finish = await bootCli(pane: _paneEnv(), reports: reports);
    io.sendLine('/session fresh');
    await waitForIt(
      () => reports.any((argv) => _op(argv) == 'report-agent-session'),
      reason: 'session-switch report',
    );
    expect(
      reports.where((argv) => _op(argv) == 'release-agent'),
      isEmpty,
      reason: 'a session switch never releases',
    );
    final switchReport = reports.singleWhere(
      (argv) => _op(argv) == 'report-agent-session',
    );
    final id = switchReport[switchReport.indexOf('--agent-session-id') + 1];
    expect(id, isNotEmpty);
    expect(switchReport.sublist(switchReport.indexOf('--')), [
      '--',
      'fa',
      '--session',
      id,
    ]);
    await finish();
    expect(reports.where((argv) => _op(argv) == 'release-agent'), hasLength(1));
  });

  test('IT-2/AC2: every inert gate combination spawns nothing through a full run', () async {
    const cases = <String, Map<String, String>>{
      'no herdr env at all': {},
      'HERDR_ENV only': {'HERDR_ENV': '1'},
      'relative bin path (E7)': {
        'HERDR_ENV': '1',
        'HERDR_PANE_ID': 'w6:p16',
        'HERDR_BIN_PATH': 'herdr',
      },
      'hostile pane id': {
        'HERDR_ENV': '1',
        'HERDR_PANE_ID': 'not a pane id',
        'HERDR_BIN_PATH': '/opt/homebrew/bin/herdr',
      },
      'kill switch (E8)': {
        'HERDR_ENV': '1',
        'HERDR_PANE_ID': 'w6:p16',
        'HERDR_BIN_PATH': '/opt/homebrew/bin/herdr',
        'FA_HERDR': '0',
      },
    };
    for (final entry in cases.entries) {
      final reports = <List<String>>[];
      final finish = await bootCli(
        pane: entry.value,
        reports: reports,
        turns: [textTurn('hello back')],
        gateActive: false,
      );
      io.sendLine('hello');
      await waitForIt(
        () => io.out.toString().contains('hello back'),
        reason: '${entry.key}: turn completed',
      );
      await finish();
      expect(reports, isEmpty, reason: '${entry.key}: zero spawns');
    }
  });

  test('IT-7: a throwing recorder never disturbs the run and never surfaces', () async {
    final fake = FakeStreamFunction([textTurn('hello back')]);
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        herdrEnvLookup: (name) => _paneEnv()[name],
        herdrSpawn: (argv) async => throw StateError('herdr died'),
      ),
      io: io,
      streamFunction: fake.call,
    );
    final run = cli.run();
    await waitForIt(() => io.out.toString().contains('fa> '));
    io.sendLine('hello');
    await waitForIt(() => io.out.toString().contains('hello back'));
    io.sendLine('/exit');
    await run;
    expect(io.out.toString(), isNot(contains('herdr')));
  });

  test('IT-6/AC5: nothing but state bytes leaves fa under a canary environment', () async {
    final reports = <List<String>>[];
    final finish = await bootCli(
      pane: {..._paneEnv(), 'HERDR_CANARY_SECRET': _canarySecret},
      reports: reports,
      turns: [textTurn('hello back')],
    );
    // The secret rides the transcript (the user prompt) and the cwd is a
    // secret-shaped path — neither may ever reach an argv.
    io.sendLine('please echo $_canarySecret');
    await waitForIt(() => io.out.toString().contains('hello back'));
    await finish();

    expect(reports, isNotEmpty);
    final vocabulary = RegExp(
      r'^(/opt/homebrew/bin/herdr|pane|report-agent|report-agent-session|'
      r'release-agent|w6:p16|--source|--agent|--state|--message|--seq|'
      r'--agent-session-id|--session|fa|idle|working|blocked|approval|ask|'
      r'secret|host-model|--|\d+|[A-Za-z0-9._:-]+)$',
    );
    for (final argv in reports) {
      final joined = argv.join(' ');
      expect(joined, isNot(contains(_canarySecret)), reason: 'argv: $joined');
      expect(joined, isNot(contains(_canaryCwd)), reason: 'argv: $joined');
      expect(joined, isNot(contains('please echo')), reason: 'argv: $joined');
      for (final arg in argv) {
        expect(arg, matches(vocabulary), reason: 'argv: $argv');
      }
    }
  });
}
