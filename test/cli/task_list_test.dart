@TestOn('vm')
library;

/// Issue #222 AC5 — the `/tasks` half: the listing folds superseded
/// generations of a respawn chain into ONE logical entry (the
/// `agent_directory` half lives in subagent_lifecycle_test.dart). The
/// [TaskJob]s come from the REAL task tool + job manager wiring, so the
/// rows are exactly what `/tasks` renders.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/task_list.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({List<ContentBlock> content = const []}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
}

/// Echo stream: every child finishes with `finished <last user text>`.
AssistantMessageEventStream _echo(
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  var lastUser = '';
  for (final message in context.messages.reversed) {
    if (message is UserMessage) {
      final content = message.content;
      lastUser = content is String
          ? content
          : content is List<ContentBlock>
          ? content.whereType<TextContent>().map((b) => b.text).join('\n')
          : '';
      break;
    }
  }
  final reply = 'finished $lastUser';
  final partial = _assistant(content: [TextContent(text: reply)]);
  final stream = AssistantMessageEventStream();
  stream
    ..push(StartEvent(partial: _assistant()))
    ..push(TextStartEvent(contentIndex: 0, partial: _assistant()))
    ..push(TextDeltaEvent(contentIndex: 0, delta: reply, partial: partial))
    ..push(DoneEvent(reason: StopReason.stop, message: partial))
    ..end();
  return stream;
}

/// The CLI's `/tasks` view assembly: jobs from the job manager, the
/// supersedes map from the retained-subagent registry.
(Map<String, String>, List<String>) _tasksView(TaskToolConfig config) {
  final handles = config.subagentManager?.handles ?? const <SubagentHandle>[];
  return (
    <String, String>{
      for (final handle in handles)
        if (handle.supersedes != null) handle.id: handle.supersedes!,
    },
    taskJobLines(
      config.jobManager.jobs,
      dim: (s) => '[$s]',
      supersedesOf: <String, String>{
        for (final handle in handles)
          if (handle.supersedes != null) handle.id: handle.supersedes!,
      },
    ),
  );
}

void main() {
  late SubagentManager manager;
  late TaskToolConfig config;
  late AgentTool tool;

  setUp(() {
    manager = SubagentManager(parentSessionId: 'p');
    config = TaskToolConfig(
      childTools: const [],
      streamFunction: () => _echo,
      model: () => _model,
      subagentManager: manager,
    );
    tool = taskTool(config: config);
  });

  Future<void> spawnBackground(String name, String task) async {
    await tool.execute(
      {
        'context': 'ctx',
        'background': true,
        'tasks': [
          {'name': name, 'task': task},
        ],
      },
      null,
      null,
    );
    await config.jobManager.settled;
  }

  test(
    'a two-generation chain renders as ONE row annotated with supersedes',
    () async {
      await spawnBackground('Scout', 'first round');
      await spawnBackground('Scout', 'second round');
      expect(config.jobManager.jobs.map((j) => j.id), ['Scout', 'Scout-2']);
      expect(manager['Scout-2']!.supersedes, 'Scout');

      final (supersedesOf, lines) = _tasksView(config);
      expect(supersedesOf, {'Scout-2': 'Scout'});
      expect(lines, hasLength(2), reason: 'header + ONE row: $lines');
      expect(lines.last, contains('Scout-2'));
      expect(lines.last, contains('supersedes Scout'));
      expect(lines.last, isNot(contains('✓ Scout (task)')));
    },
  );

  test(
    'a three-generation chain folds into the head row with the full chain',
    () async {
      await spawnBackground('Scout', 'first round');
      await spawnBackground('Scout', 'second round');
      await spawnBackground('Scout', 'third round');
      expect(config.jobManager.jobs.map((j) => j.id), [
        'Scout',
        'Scout-2',
        'Scout-3',
      ]);

      final (_, lines) = _tasksView(config);
      expect(lines, hasLength(2), reason: 'header + ONE row: $lines');
      expect(lines.last, contains('Scout-3'));
      expect(lines.last, contains('supersedes Scout-2 ← Scout'));
    },
  );

  test('a superseded job whose successor is NOT listed still renders (never '
      'hide a row without showing its head)', () async {
    await spawnBackground('Scout', 'first round');
    // A BLOCKING respawn: it supersedes Scout but registers no job, so
    // /tasks would hide Scout while showing nothing for the successor.
    await tool.execute(
      {
        'context': 'ctx',
        'tasks': [
          {'name': 'Scout', 'task': 'second round'},
        ],
      },
      null,
      null,
    );
    expect(manager['Scout-2']!.supersedes, 'Scout');
    expect(config.jobManager.jobs.map((j) => j.id), ['Scout']);

    final (_, lines) = _tasksView(config);
    expect(lines, hasLength(2), reason: 'header + Scout row: $lines');
    expect(lines.last, contains('Scout'));
  });

  test('unrelated jobs never fold', () async {
    await spawnBackground('Scout', 'survey');
    await spawnBackground('Builder', 'build it');
    final (_, lines) = _tasksView(config);
    expect(lines, hasLength(3), reason: 'header + two rows: $lines');
    expect(lines[1], contains('Scout'));
    expect(lines[2], contains('Builder'));
    expect(lines.join('\n'), isNot(contains('supersedes')));
  });
}
