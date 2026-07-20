import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn: stream start, text delta, done.
List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn that ends with a tool call.
List<AssistantMessageEvent> _toolTurn(
  String toolName, [
  Map<String, dynamic>? args,
]) {
  final empty = _assistant();
  final call = ToolCall(
    id: 'call-1',
    name: toolName,
    arguments: args ?? const {},
  );
  final partial = _assistant(content: [call], stopReason: StopReason.toolUse);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// A scripted provider error turn.
List<AssistantMessageEvent> _errorTurn(String errorMessage) {
  return [
    StartEvent(partial: _assistant()),
    ErrorEvent(
      reason: StopReason.error,
      error: _assistant(
        stopReason: StopReason.error,
        errorMessage: errorMessage,
      ),
    ),
  ];
}

/// One scripted route: calls whose last user message contains [match] replay
/// [turns] in order (one per call).
typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

/// Scripted fake [StreamFunction] for child agents: routes each call to a
/// turn queue by matching the last user message, and records every context
/// and model it was called with. Calls with no matching turns left answer a
/// default 'done' turn.
final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : _rules = List.of(rules);

  final List<_Rule> _rules;
  final contexts = <Context>[];
  final models = <Model>[];

  int get calls => contexts.length;

  /// The text of the most recent user message in [context] (children prompt
  /// with plain text; tool results in between do not hide the assignment).
  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        if (content is String) return content;
        if (content is List<ContentBlock>) {
          return content.whereType<TextContent>().map((b) => b.text).join('\n');
        }
      }
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    models.add(model);
    final text = lastUserText(context);
    for (final rule in _rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        final events = rule.turns.removeAt(0);
        return _streamOf(events);
      }
    }
    return _streamOf(_textTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

AgentTool _fakeTool(String name, ApprovalTier tier) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: tier,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name result'),
  );
}

List<AgentTool> _pool() => [
  _fakeTool('read', ApprovalTier.read),
  _fakeTool('write', ApprovalTier.write),
  _fakeTool('bash', ApprovalTier.exec),
];

final class _Harness {
  _Harness(this.tool, this.config, this.stream);

  final AgentTool tool;
  final TaskToolConfig config;
  final _ScriptedStream stream;
}

_Harness _harness({
  List<_Rule> rules = const [],
  List<AgentTool>? childTools,
  int maxConcurrent = defaultTaskMaxConcurrent,
  bool defaultBackground = false,
  List<TaskAgentDefinition> agentTypes = const [],
  ModelRolesResolver? rolesResolver,
  _ScriptedStream? stream,
}) {
  final s = stream ?? _ScriptedStream(rules);
  final config = TaskToolConfig(
    childTools: childTools ?? _pool(),
    streamFunction: s.call,
    model: _model,
    rolesResolver: rolesResolver,
    agentTypes: agentTypes,
    maxConcurrent: maxConcurrent,
    defaultBackground: defaultBackground,
  );
  return _Harness(taskTool(config: config), config, s);
}

String _resultText(ToolExecutionResult result) {
  return result.content.whereType<TextContent>().map((b) => b.text).join('\n');
}

Context _contextFor(_ScriptedStream stream, String fragment) {
  return stream.contexts.firstWhere(
    (context) => _ScriptedStream.lastUserText(context).contains(fragment),
  );
}

List<String> _toolNames(Context context) {
  return [for (final tool in context.tools ?? const <Tool>[]) tool.name];
}

const _findingsSchema = {
  'type': 'object',
  'properties': {
    'summary': {'type': 'string'},
    'findings': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
        'required': ['path'],
      },
    },
  },
  'required': ['summary', 'findings'],
};

void main() {
  group('batch fan-out', () {
    test('N items complete with typed, ordered results', () async {
      final h = _harness(
        rules: [
          (match: 'first job', turns: [_textTurn('result one')]),
          (
            match: 'second job',
            turns: [_textTurn('{"summary": "two", "findings": []}')],
          ),
          (match: 'third job', turns: [_textTurn('result three')]),
        ],
      );
      final result = await h.tool.execute(
        {
          'context': 'shared ctx',
          'tasks': [
            {'name': 'One', 'task': 'first job'},
            {
              'name': 'Two',
              'agent': 'explore',
              'task': 'second job',
              'outputSchema': _findingsSchema,
            },
            {'name': 'Three', 'agent': 'review', 'task': 'third job'},
          ],
        },
        null,
        null,
      );

      final text = _resultText(result);
      expect(text, contains('3 subagents finished'));
      expect(text, isNot(contains('failed')));
      final one = text.indexOf('## One (task) — ok');
      final two = text.indexOf('## Two (explore) — ok [schema: valid]');
      final three = text.indexOf('## Three (review) — ok');
      expect(one, greaterThanOrEqualTo(0));
      expect(two, greaterThan(one));
      expect(three, greaterThan(two));
      expect(text, contains('result one'));
      expect(text, contains('[Full output: agent://One]'));

      // Typed outputs are addressable: the schema item's stored output IS
      // the validated JSON object.
      final resolution = resolveAgentUrl(
        'agent://Two/summary',
        h.config.outputs,
      );
      expect(resolution.content, '"two"');
      expect(h.config.outputs.get('One'), 'result one');
      // Results are ordered (text sections above); the store is in
      // completion order, which concurrent spawns do not guarantee.
      expect(
        h.config.outputs.availableIds,
        containsAll(<String>['One', 'Two', 'Three']),
      );
    });

    test('shared context lands in every child system prompt', () async {
      final h = _harness();
      await h.tool.execute(
        {
          'context': 'THE SHARED BACKGROUND',
          'tasks': [
            {'task': 'job a'},
            {'task': 'job b'},
          ],
        },
        null,
        null,
      );
      expect(h.stream.calls, 2);
      for (final context in h.stream.contexts) {
        expect(context.systemPrompt, contains('# CONTEXT'));
        expect(context.systemPrompt, contains('THE SHARED BACKGROUND'));
      }
    });

    test('unnamed items get the capitalized agent type, uniquified', () async {
      final h = _harness();
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'agent': 'explore', 'task': 'job a'},
            {'agent': 'explore', 'task': 'job b'},
            {'task': 'job c'},
          ],
        },
        null,
        null,
      );
      expect(
        h.config.outputs.availableIds,
        containsAll(<String>['Explore', 'Explore-2', 'Task']),
      );
    });

    test('a child tool call round-trips through the loop', () async {
      final h = _harness(
        rules: [
          (
            match: 'read then report',
            turns: [_toolTurn('read'), _textTurn('the report')],
          ),
        ],
      );
      final result = await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'task': 'read then report'},
          ],
        },
        null,
        null,
      );
      expect(_resultText(result), contains('the report'));
      // Two model calls: the tool-call turn and the final answer.
      expect(h.stream.calls, 2);
    });

    test(
      'a child failure becomes a per-item error entry, not a batch failure',
      () async {
        final h = _harness(
          rules: [
            (match: 'bad job', turns: [_errorTurn('provider exploded')]),
            (match: 'good job', turns: [_textTurn('fine')]),
          ],
        );
        final result = await h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'name': 'Bad', 'task': 'bad job'},
              {'name': 'Good', 'task': 'good job'},
            ],
          },
          null,
          null,
        );
        final text = _resultText(result);
        expect(text, contains('— 1 failed'));
        expect(text, contains('## Bad (task) — failed'));
        expect(text, contains('provider exploded'));
        expect(text, contains('## Good (task) — ok'));
      },
    );

    test('progress streams through onUpdate', () async {
      final h = _harness();
      final updates = <String>[];
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'Solo', 'task': 'job a'},
          ],
        },
        null,
        (partial) => updates.add(_resultText(partial)),
      );
      expect(updates, isNotEmpty);
      expect(updates.last, contains('1/1 settled'));
      expect(updates.last, contains('✓ Solo (task) — done'));
    });
  });

  group('concurrency', () {
    test('the session semaphore bounds concurrent children', () async {
      var inFlight = 0;
      var maxSeen = 0;
      AssistantMessageEventStream gated(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        inFlight++;
        if (inFlight > maxSeen) maxSeen = inFlight;
        final stream = AssistantMessageEventStream();
        Timer(const Duration(milliseconds: 60), () {
          inFlight--;
          for (final event in _textTurn('done')) {
            stream.push(event);
          }
          stream.end();
        });
        return stream;
      }

      final config = TaskToolConfig(
        childTools: _pool(),
        streamFunction: gated,
        model: _model,
        maxConcurrent: 2,
      );
      final tool = taskTool(config: config);
      await tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            for (var i = 0; i < 5; i++) {'task': 'job $i'},
          ],
        },
        null,
        null,
      );
      expect(maxSeen, 2);
      expect(config.outputs.availableIds, hasLength(5));
    });
  });

  group('agent-type registry', () {
    test(
      'explore is read-only, the default worker keeps write tools',
      () async {
        final h = _harness();
        await h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'agent': 'explore', 'task': 'scout the code'},
              {'task': 'do the work'},
            ],
          },
          null,
          null,
        );
        expect(_toolNames(_contextFor(h.stream, 'scout the code')), ['read']);
        expect(_toolNames(_contextFor(h.stream, 'do the work')), [
          'read',
          'write',
          'bash',
        ]);
      },
    );

    test('review is read-only too', () async {
      final h = _harness();
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'agent': 'review', 'task': 'review the diff'},
          ],
        },
        null,
        null,
      );
      expect(_toolNames(_contextFor(h.stream, 'review the diff')), ['read']);
    });

    test(
      'the child surface never contains task (no nested task calls)',
      () async {
        final h = _harness(childTools: _pool());
        // The host's pool includes the task tool itself.
        h.config.childTools.add(h.tool);
        await h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'task': 'do the work'},
            ],
          },
          null,
          null,
        );
        final names = _toolNames(_contextFor(h.stream, 'do the work'));
        expect(names, isNot(contains('task')));
        expect(names, containsAll(['read', 'write', 'bash']));
      },
    );

    test('config types override built-ins and add allowlisted types', () async {
      final h = _harness(
        agentTypes: [
          const TaskAgentDefinition(
            name: 'task',
            description: 'restricted worker',
            systemPrompt: 'custom worker prompt',
            toolNames: {'read'},
          ),
          const TaskAgentDefinition(
            name: 'writer',
            description: 'writes files',
            systemPrompt: 'writer prompt',
            toolNames: {'read', 'write'},
          ),
        ],
      );
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'task': 'default job'},
            {'agent': 'writer', 'task': 'writer job'},
          ],
        },
        null,
        null,
      );
      expect(_toolNames(_contextFor(h.stream, 'default job')), ['read']);
      expect(_toolNames(_contextFor(h.stream, 'writer job')), [
        'read',
        'write',
      ]);
      expect(
        _contextFor(h.stream, 'default job').systemPrompt,
        startsWith('custom worker prompt'),
      );
    });

    test('the description lists available agents', () {
      final h = _harness();
      expect(h.tool.description, contains('### task'));
      expect(h.tool.description, contains('### explore (READ-ONLY)'));
      expect(h.tool.description, contains('### review (READ-ONLY)'));
    });
  });

  group('schema validation', () {
    TaskExecutor executor(_ScriptedStream stream, AgentOutputStore store) {
      return TaskExecutor(
        childTools: _pool(),
        streamFunction: stream.call,
        model: _model,
        registry: TaskAgentRegistry(),
        semaphore: Semaphore(0),
        store: store,
      );
    }

    test('valid output passes and is stored as the typed object', () async {
      final stream = _ScriptedStream([
        (
          match: 'structured job',
          turns: [
            _textTurn(
              'Here you go:\n```json\n{"summary": "s", "findings": [{"path": "a.dart"}]}\n```',
            ),
          ],
        ),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(
          task: 'structured job',
          outputSchema: _findingsSchema,
        ),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(result.structuredOutput!.status, StructuredValidationStatus.valid);
      expect(result.error, isNull);
      // The fenced JSON was extracted; the store holds the typed object, so
      // its fields are agent://-addressable.
      expect(store.get('Task'), contains('"summary": "s"'));
      final resolution = resolveAgentUrl('agent://Task/findings.0.path', store);
      expect(resolution.content, '"a.dart"');
    });

    test('invalid output gets ONE fix retry with the issue list', () async {
      final stream = _ScriptedStream([
        (match: 'structured job', turns: [_textTurn('{"findings": []}')]),
        (
          match: 'failed schema validation',
          turns: [_textTurn('{"summary": "fixed", "findings": []}')],
        ),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(
          task: 'structured job',
          outputSchema: _findingsSchema,
        ),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(result.structuredOutput!.status, StructuredValidationStatus.valid);
      expect(stream.calls, 2);
      final fixMessage = _ScriptedStream.lastUserText(stream.contexts[1]);
      expect(fixMessage, contains('failed schema validation'));
      expect(fixMessage, contains('summary: missing required parameter'));
      expect(fixMessage, contains('only retry'));
    });

    test('output invalid after the retry becomes an error entry', () async {
      final stream = _ScriptedStream([
        (match: 'structured job', turns: [_textTurn('{"findings": []}')]),
        (
          match: 'failed schema validation',
          turns: [_textTurn('{"summary": 42, "findings": "nope"}')],
        ),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(
          task: 'structured job',
          outputSchema: _findingsSchema,
        ),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.failed);
      expect(result.exitCode, 1);
      expect(result.error, contains('schema_violation'));
      expect(
        result.structuredOutput!.status,
        StructuredValidationStatus.invalid,
      );
      expect(result.structuredOutput!.data, isNotNull);
      expect(stream.calls, 2); // exactly one retry, no more
    });

    test('a final message without JSON fails after one retry', () async {
      final stream = _ScriptedStream([
        (match: 'structured job', turns: [_textTurn('no json at all')]),
        (match: 'failed schema validation', turns: [_textTurn('still none')]),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(
          task: 'structured job',
          outputSchema: _findingsSchema,
        ),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.failed);
      expect(result.error, contains('no JSON document'));
    });

    test('outputSchema true accepts any JSON document', () async {
      final stream = _ScriptedStream([
        (match: 'structured job', turns: [_textTurn('[1, 2, 3]')]),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(task: 'structured job', outputSchema: true),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(result.structuredOutput!.status, StructuredValidationStatus.valid);
      expect(result.structuredOutput!.data, [1, 2, 3]);
    });

    test('an unusable schema is reported unvalidated, not failed', () async {
      final stream = _ScriptedStream([
        (match: 'structured job', turns: [_textTurn('free text')]),
      ]);
      final store = AgentOutputStore();
      final result = await executor(stream, store).runSpawn(
        item: const TaskItem(task: 'structured job', outputSchema: 'bogus'),
        index: 0,
        context: 'ctx',
      );
      expect(result.status, TaskSpawnStatus.completed);
      expect(
        result.structuredOutput!.status,
        StructuredValidationStatus.unavailable,
      );
    });

    test('the schema instructions land in the child prompt', () async {
      final stream = _ScriptedStream();
      final store = AgentOutputStore();
      await executor(stream, store).runSpawn(
        item: const TaskItem(
          task: 'structured job',
          outputSchema: _findingsSchema,
        ),
        index: 0,
        context: 'ctx',
      );
      // The default 'done' answer is not JSON, so a fix retry follows; the
      // FIRST prompt carries the assignment and the schema instructions.
      final prompt = _ScriptedStream.lastUserText(stream.contexts.first);
      expect(prompt, contains('structured job'));
      expect(prompt, contains('JSON Schema'));
    });
  });

  group('background execution', () {
    _Harness gatedHarness(Map<String, Completer<void>> gates) {
      AssistantMessageEventStream gated(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        final text = _ScriptedStream.lastUserText(context);
        final key = gates.keys.firstWhere(
          (k) => text.contains(k),
          orElse: () => '',
        );
        var gate = gates[key];
        gate ??= Completer<void>()..complete();
        unawaited(
          gate.future.then((_) {
            for (final event in _textTurn('finished $key')) {
              stream.push(event);
            }
            stream.end();
          }),
        );
        // Providers surface aborts as error events (the errors-as-events
        // contract); the loop cannot end a stream that never terminates.
        unawaited(
          cancelToken?.onCancel.then((_) {
                stream.push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: _assistant(
                      stopReason: StopReason.aborted,
                      errorMessage: 'cancelled by caller',
                    ),
                  ),
                );
                stream.end();
              }) ??
              Future<void>.value(),
        );
        return stream;
      }

      final config = TaskToolConfig(
        childTools: _pool(),
        streamFunction: gated,
        model: _model,
      );
      return _Harness(taskTool(config: config), config, _ScriptedStream());
    }

    test(
      'jobs are returned immediately and settle into typed results',
      () async {
        final gates = {'job a': Completer<void>(), 'job b': Completer<void>()};
        final h = gatedHarness(gates);
        final completed = <TaskJob>[];
        final sub = h.config.jobManager.completions.listen(completed.add);

        final result = await h.tool.execute(
          {
            'context': 'ctx',
            'background': true,
            'tasks': [
              {'name': 'A', 'task': 'job a'},
              {'name': 'B', 'agent': 'explore', 'task': 'job b'},
            ],
          },
          null,
          null,
        );

        // The call returned without waiting for the (still closed) gates.
        final text = _resultText(result);
        expect(
          text,
          contains('Spawned 2 background agents using task, explore'),
        );
        expect(text, contains('- `A` (task, job `A`)'));
        expect(text, contains('- `B` (explore, job `B`)'));

        await pumpEventQueue();
        expect(h.config.jobManager.job('A')!.status, TaskJobStatus.running);
        expect(h.config.jobManager.job('B')!.status, TaskJobStatus.running);
        expect(h.config.outputs.availableIds, isEmpty);

        gates['job a']!.complete();
        gates['job b']!.complete();
        await h.config.jobManager.settled;

        expect(h.config.jobManager.job('A')!.status, TaskJobStatus.completed);
        expect(h.config.jobManager.job('B')!.status, TaskJobStatus.completed);
        expect(
          h.config.jobManager.job('A')!.result!.status,
          TaskSpawnStatus.completed,
        );
        expect(h.config.outputs.get('A'), 'finished job a');
        expect(h.config.outputs.get('B'), 'finished job b');
        // Broadcast completion events are delivered asynchronously.
        await pumpEventQueue();
        expect(completed.map((j) => j.id), containsAll(<String>['A', 'B']));
        await sub.cancel();
      },
    );

    test(
      'a settled failed child marks its job failed, not the batch',
      () async {
        final gates = {'job a': Completer<void>()};
        final h = gatedHarness(gates);
        await h.tool.execute(
          {
            'context': 'ctx',
            'background': true,
            'tasks': [
              {'name': 'A', 'task': 'job a', 'outputSchema': _findingsSchema},
            ],
          },
          null,
          null,
        );
        gates['job a']!.complete();
        // The child answers 'finished job a' (no JSON) twice: initial + retry.
        await h.config.jobManager.settled;
        expect(h.config.jobManager.job('A')!.status, TaskJobStatus.failed);
        expect(
          h.config.jobManager.job('A')!.result!.error,
          contains('schema_violation'),
        );
      },
    );

    test('cancelling a job aborts its child', () async {
      final gates = {'job a': Completer<void>()};
      final h = gatedHarness(gates);
      await h.tool.execute(
        {
          'context': 'ctx',
          'background': true,
          'tasks': [
            {'name': 'A', 'task': 'job a'},
          ],
        },
        null,
        null,
      );
      await pumpEventQueue();
      h.config.jobManager.job('A')!.cancel();
      // The gated stream never completes; cancellation alone must settle.
      await h.config.jobManager.settled;
      expect(h.config.jobManager.job('A')!.status, TaskJobStatus.aborted);
    });

    test('defaultBackground comes from the config', () async {
      final gates = {'job a': Completer<void>()};
      AssistantMessageEventStream gated(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        gates['job a']!.future.then((_) {
          for (final event in _textTurn('done')) {
            stream.push(event);
          }
          stream.end();
        });
        return stream;
      }

      final config = TaskToolConfig(
        childTools: _pool(),
        streamFunction: gated,
        model: _model,
        defaultBackground: true,
      );
      final tool = taskTool(config: config);
      final result = await tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'A', 'task': 'job a'},
          ],
        },
        null,
        null,
      );
      expect(_resultText(result), contains('Spawned 1 background agent'));
      gates['job a']!.complete();
      await config.jobManager.settled;
      expect(config.jobManager.job('A')!.status, TaskJobStatus.completed);
    });
  });

  group('cancellation', () {
    _Harness cancelAwareHarness({
      int maxConcurrent = defaultTaskMaxConcurrent,
    }) {
      AssistantMessageEventStream cancelAware(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        stream.push(StartEvent(partial: _assistant()));
        unawaited(
          cancelToken?.onCancel.then((_) {
                stream.push(
                  ErrorEvent(
                    reason: StopReason.aborted,
                    error: _assistant(
                      stopReason: StopReason.aborted,
                      errorMessage: 'cancelled by caller',
                    ),
                  ),
                );
                stream.end();
              }) ??
              Future<void>.value(),
        );
        return stream;
      }

      final config = TaskToolConfig(
        childTools: _pool(),
        streamFunction: cancelAware,
        model: _model,
        maxConcurrent: maxConcurrent,
      );
      return _Harness(taskTool(config: config), config, _ScriptedStream());
    }

    test('cancelling the parent token aborts in-flight children', () async {
      final h = cancelAwareHarness();
      final source = CancelTokenSource();
      final future = h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'A', 'task': 'job a'},
            {'name': 'B', 'task': 'job b'},
          ],
        },
        source.token,
        null,
      );
      await pumpEventQueue(); // both children start (semaphore is unbounded)
      source.cancel();
      final result = await future;
      final text = _resultText(result);
      expect(text, contains('## A (task) — aborted'));
      expect(text, contains('## B (task) — aborted'));
      expect(text, contains('— 2 failed'));
    });

    test('queued items abort at the semaphore without running', () async {
      final h = cancelAwareHarness(maxConcurrent: 1);
      final source = CancelTokenSource();
      final future = h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'A', 'task': 'job a'},
            {'name': 'B', 'task': 'job b'},
          ],
        },
        source.token,
        null,
      );
      await pumpEventQueue(); // A starts; B waits on the semaphore
      source.cancel();
      final result = await future;
      final text = _resultText(result);
      expect(text, contains('## A (task) — aborted'));
      expect(text, contains('## B (task) — aborted'));
      // B never reached a model call.
      expect(h.config.outputs.availableIds, isEmpty);
    });

    test('a pre-cancelled token yields aborted entries only', () async {
      final h = cancelAwareHarness();
      final source = CancelTokenSource()..cancel();
      final result = await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'A', 'task': 'job a'},
          ],
        },
        source.token,
        null,
      );
      expect(_resultText(result), contains('## A (task) — aborted'));
    });
  });

  group('model roles', () {
    ModelRolesResolver resolver(_ScriptedStream smolStream) {
      return ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            smolModelRole: [
              ModelRef(
                provider: 'anthropic',
                modelId: 'test-haiku',
                contextWindow: 1000,
                maxTokens: 128,
              ),
            ],
          },
        ),
        secrets: const {'ANTHROPIC_API_KEY': 'test-key'},
        streamFactory: (kind, apiKey) => smolStream.call,
      );
    }

    test('explore runs on the smol role when configured', () async {
      final smolStream = _ScriptedStream([
        (match: 'scout it', turns: [_textTurn('findings')]),
      ]);
      final parentStream = _ScriptedStream([
        (match: 'work it', turns: [_textTurn('worked')]),
      ]);
      final h = _harness(
        stream: parentStream,
        rolesResolver: resolver(smolStream),
      );
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'agent': 'explore', 'task': 'scout it'},
            {'task': 'work it'},
          ],
        },
        null,
        null,
      );
      expect(smolStream.calls, 1);
      expect(smolStream.models.single.id, 'test-haiku');
      expect(parentStream.calls, 1);
      expect(parentStream.models.single.id, _model.id);
    });

    test('an unconfigured smol role falls back to the parent wiring', () async {
      final parentStream = _ScriptedStream();
      final emptyResolver = ModelRolesResolver(
        config: ModelRolesConfig(roles: const {}),
        secrets: const {},
        streamFactory: (kind, apiKey) =>
            throw StateError('no stream without keys'),
      );
      final h = _harness(stream: parentStream, rolesResolver: emptyResolver);
      await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'agent': 'explore', 'task': 'scout it'},
          ],
        },
        null,
        null,
      );
      expect(parentStream.calls, 1);
      expect(parentStream.models.single.id, _model.id);
    });
  });

  group('call validation', () {
    test('rejects an empty context', () async {
      final h = _harness();
      expect(
        () => h.tool.execute(
          {
            'context': '  ',
            'tasks': [
              {'task': 'job'},
            ],
          },
          null,
          null,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('context'),
          ),
        ),
      );
    });

    test('rejects an empty batch', () async {
      final h = _harness();
      expect(
        () => h.tool.execute(
          {'context': 'ctx', 'tasks': <Object?>[]},
          null,
          null,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('at least one'),
          ),
        ),
      );
    });

    test('rejects an item without a task', () async {
      final h = _harness();
      expect(
        () => h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'task': '   '},
            ],
          },
          null,
          null,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('tasks[0].task'),
          ),
        ),
      );
    });

    test('rejects duplicate names case-insensitively', () async {
      final h = _harness();
      expect(
        () => h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'name': 'Dup', 'task': 'job a'},
              {'name': 'dup', 'task': 'job b'},
            ],
          },
          null,
          null,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('duplicate'),
          ),
        ),
      );
    });

    test('rejects an unknown agent type listing the available ones', () async {
      final h = _harness();
      expect(
        () => h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'agent': 'nope', 'task': 'job a'},
            ],
          },
          null,
          null,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Unknown agent type "nope"'), contains('explore')),
          ),
        ),
      );
    });
  });
}
