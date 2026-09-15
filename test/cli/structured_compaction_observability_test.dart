import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #438 — structured compaction must be observable on stderr.
///
/// An orchestrator watching stderr (the dmtools CI loop) must be able to
/// distinguish «compacted and still working» from «hung»: every structured
/// fold prints a receipt whose counters match the session's fold records
/// (hidden_range ids / checkpoint covered messages), and the receipts
/// alone (no session file) classify «alive, compacted N times».
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
    // Thirteen fat files, read one per turn: the executed tool results
    // (~2.5k estimated tokens each) eventually blow the 40k window — the
    // over-window guard refuses the next request and the structured
    // engine folds the older records to get the retry through.
    for (var i = 1; i <= 13; i++) {
      env.writeFile('big$i.txt', List.filled(250, 'x' * 40).join('\n'));
    }
  });

  tearDown(() => io.close());

  /// The content-aware fake: agent requests get the next scripted `read`
  /// tool call, hide-judge requests (the context-hygiene judge system
  /// prompt) get hide picks over the oldest pairs, checkpoint/summarizer
  /// requests get a text summary, and the closing agent turn gets the
  StreamFunction foldRun() {
    var nextFile = 1;
    List<AssistantMessageEvent> answer(Context context) {
      final system = context.systemPrompt ?? '';
      if (system.contains('context-hygiene judge')) {
        return textTurn('[2, 3, 4, 5, 6, 7, 8, 9, 10, 11]');
      }
      final last = context.messages.last;
      final text = last is UserMessage
          ? (last.content is String
                ? last.content as String
                : (last.content as List<Object>)
                      .whereType<TextContent>()
                      .map((b) => b.text)
                      .join())
          : '';
      if (text.contains('<conversation>') || system.contains('hand off')) {
        return textTurn('checkpoint: the file counting investigation');
      }
      if (nextFile > 13) return textTurn('done: all files counted');
      final file = nextFile++;
      return toolTurn([
        ToolCall(
          id: 't$file',
          name: 'read',
          arguments: {'path': 'big$file.txt'},
        ),
      ]);
    }

    return (model, context, {cancelToken}) {
      final events = answer(context);
      final stream = AssistantMessageEventStream();
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
      return stream;
    };
  }

  AgentCli buildCli(StreamFunction stream) => AgentCli(
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

  Future<Session> openRunSession() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    return repo.open(sessions.single);
  }

  test(
    'IT-stderr-receipt: every fold prints a receipt whose counters match '
    'the session fold records',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = buildCli(foldRun());
      final exitCode = await cli.runHeadless('count the words');

      expect(exitCode, 0, reason: 'the turn finished after the folds');
      final stderrText = io.out.toString();
      expect(stderrText, contains('done: all files counted'));

      final session = await openRunSession();
      final entries = await session.getEntries();
      final hiddenRanges = entries.whereType<HiddenRangeRecord>().toList();
      final checkpoints = entries.whereType<CompactCheckpointRecord>().toList();
      expect(
        hiddenRanges.length + checkpoints.length,
        greaterThanOrEqualTo(1),
        reason: 'the fixture must really fold',
      );

      // One receipt per fold event — no silent folds (the issue #438
      // fixture: five folds, zero compaction lines).
      final receipts = RegExp(
        r'^● auto-compacted',
        multiLine: true,
      ).allMatches(stderrText).length;
      expect(
        receipts,
        hiddenRanges.length + checkpoints.length,
        reason:
            'stderr must carry a receipt per structured fold '
            '($receipts receipts for ${hiddenRanges.length} hidden ranges '
            '+ ${checkpoints.length} checkpoints):\n$stderrText',
      );

      // Honest counters: the receipts' hidden counts sum to the records
      // the session's hidden_range records actually cover, and the
      // summarized counts to the checkpoints' covered message records —
      // «0 hidden» while work happened is the issue fixture lie.
      final sessionHidden = hiddenRanges.fold(
        0,
        (sum, r) => sum + r.recordIds.length,
      );
      final sessionSummarized = checkpoints.fold(0, (sum, c) {
        final byId = {for (final e in entries) e.id: e};
        return sum +
            c.coversRecordIds.where((id) {
              final record = byId[id];
              return record is MessageRecord;
            }).length;
      });
      final claimedHidden = RegExp(r'records: (\d+) hidden')
          .allMatches(stderrText)
          .fold(0, (sum, m) => sum + int.parse(m.group(1)!));
      final claimedSummarized = RegExp(r'· (\d+) summarized')
          .allMatches(stderrText)
          .fold(0, (sum, m) => sum + int.parse(m.group(1)!));
      expect(
        claimedHidden,
        sessionHidden,
        reason:
            'hidden counters must match the session hidden_ranges '
            '(claimed $claimedHidden, session holds $sessionHidden):\n'
            '$stderrText',
      );
      expect(
        claimedSummarized,
        sessionSummarized,
        reason:
            'summarized counters must match the checkpoints\' covered '
            'message records (claimed $claimedSummarized, session holds '
            '$sessionSummarized):\n$stderrText',
      );
    },
  );

  test(
    'E2E-watcher: stderr alone classifies «alive, compacted N times»',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final cli = buildCli(foldRun());
      await cli.runHeadless('count the words');

      // The external watcher's whole view: the stderr text — no session
      // file access.
      final verdict = classifyWatchedRun(io.out.toString());
      expect(verdict.alive, isTrue, reason: 'the run finished its task');

      final foldEvents = (await (await openRunSession()).getEntries())
          .where((r) => r is HiddenRangeRecord || r is CompactCheckpointRecord)
          .length;
      expect(
        verdict.compactions,
        foldEvents,
        reason:
            'the watcher counts fold receipts — one per session '
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
