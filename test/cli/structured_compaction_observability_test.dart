import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #438 — structured compaction must be observable on stderr.
///
/// An orchestrator watching stderr (the dmtools CI loop) must be able to
/// distinguish «compacted and still working» from «hung»: every structured
/// fold prints a receipt line whose counters match the session's
/// hidden_range records for that pass, and the receipts alone (no session
/// file) classify «alive, compacted N times».
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    // Eight fat files: one agent turn reads them all — the executed tool
    // results (~11.5k estimated tokens each) blow the tiny window and the
    // structured engine folds the older records to stay under it.
    for (var i = 1; i <= 8; i++) {
      env.writeFile('big$i.txt', List.filled(1000, 'x' * 45).join('\n'));
    }
  });

  tearDown(() => io.close());

  AgentCli buildCli(FakeStreamFunction stream) => AgentCli(
    config: AgentCliConfig(
      model: const Model(
        id: 'tiny-window',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 40000,
        maxTokens: 4096,
      ),
      apiKey: '[REDACTED:Sensitive Value]',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
      compactionSettings: const CompactionSettings(
        enabled: true,
        reserveTokens: 2000,
        keepRecentTokens: 2000,
      ),
    ),
    io: io,
    streamFunction: stream.call,
  );

  List<AssistantMessageEvent> readAllTurn() => toolTurn([
    for (var i = 1; i <= 8; i++)
      ToolCall(id: 't$i', name: 'read', arguments: {'path': 'big$i.txt'}),
  ]);

  /// A judge turn picking the first [n] ledger seqs (JSON array, the
  /// production judge's answer shape).
  List<AssistantMessageEvent> judgeTurn(List<int> seqs) =>
      textTurn('[${seqs.join(', ')}]');

  /// The scripted fold run: one fat read turn, three judge passes, a
  /// checkpoint summarizer, the closing reply.
  FakeStreamFunction foldRun() => FakeStreamFunction([
    readAllTurn(),
    judgeTurn([1, 2, 3, 4, 5, 6, 7, 8, 9]),
    judgeTurn([2, 3, 4, 5, 6, 7, 8, 9, 10]),
    judgeTurn([2, 3, 4, 5, 6, 7, 8, 9, 10]),
    textTurn('checkpoint: eight fat reads of big1-8.txt'),
    textTurn('done: all files counted'),
  ]);

  Future<Session> openRunSession() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    return repo.open(sessions.single);
  }

  test(
    'IT-stderr-receipt: ≥2 structured folds print ≥2 receipts whose '
    'counters match the session hidden_ranges',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = buildCli(foldRun());
      final exitCode = await cli.runHeadless('count the words');

      expect(exitCode, 0, reason: 'the turn finished after the folds');
      final stderrText = io.out.toString();
      final receipts = RegExp(
        r'^● auto-compacted.*$',
        multiLine: true,
      ).allMatches(stderrText).length;
      expect(
        receipts,
        greaterThanOrEqualTo(2),
        reason:
            'stderr must carry a receipt per structured fold; got '
            '$receipts in:\n$stderrText',
      );

      // Honest counters: the receipts' hidden counts must sum to the
      // records the session's hidden_range records actually cover —
      // «0 hidden» while work happened is the issue #438 fixture lie.
      final sessionHidden = (await (await openRunSession()).getEntries())
          .whereType<HiddenRangeRecord>()
          .fold(0, (sum, r) => sum + r.recordIds.length);
      expect(
        sessionHidden,
        greaterThanOrEqualTo(2),
        reason: 'the fixture must really hide records',
      );
      final claimedHidden = RegExp(
        r'records: (\d+) hidden',
      )
          .allMatches(stderrText)
          .fold(0, (sum, m) => sum + int.parse(m.group(1)!));
      expect(
        claimedHidden,
        sessionHidden,
        reason:
            'receipt counters must match the session hidden_range records '
            '(claimed $claimedHidden, session holds $sessionHidden):\n'
            '$stderrText',
      );
    },
  );

  test(
    'E2E-watcher: stderr alone classifies «alive, compacted N times»',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = buildCli(foldRun());
      await cli.runHeadless('count the words');

      // One receipt per fold event: a hide pass appends one hidden_range,
      // a checkpoint pass one compact_checkpoint.
      final foldEvents = (await (await openRunSession()).getEntries())
          .where((r) => r is HiddenRangeRecord || r is CompactCheckpointRecord)
          .length;
      // The external watcher's whole view: the stderr text — no session
      // file access.
      final verdict = classifyWatchedRun(io.out.toString());
      expect(verdict.alive, isTrue, reason: 'the run finished its task');
      expect(
        verdict.compactions,
        greaterThanOrEqualTo(2),
        reason: 'two structured folds happened and each must be visible',
      );
      expect(
        verdict.compactions,
        foldEvents,
        reason: 'the watcher counts fold receipts — one per session '
            'hidden_range/checkpoint record',
      );
    },
  );
}

/// What a stderr-watching orchestrator can tell about a run (issue #438
/// AC6): alive/dead and how many compaction folds it saw — from the
/// receipt lines alone.
({bool alive, int compactions}) classifyWatchedRun(String stderr) {
  final compactions = RegExp(
    r'^● auto-compacted',
    multiLine: true,
  ).allMatches(stderr).length;
  return (alive: stderr.contains('done:'), compactions: compactions);
}
