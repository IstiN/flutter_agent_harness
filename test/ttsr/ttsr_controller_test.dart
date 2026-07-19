import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

/// A text turn streamed in [chunks] (each chunk one delta).
List<AssistantMessageEvent> _textTurnChunks(List<String> chunks) {
  final empty = _assistant();
  final events = <AssistantMessageEvent>[
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
  ];
  var text = '';
  for (final chunk in chunks) {
    text += chunk;
    events.add(
      TextDeltaEvent(
        contentIndex: 0,
        delta: chunk,
        partial: _assistant(content: [TextContent(text: text)]),
      ),
    );
  }
  events.add(
    DoneEvent(
      reason: StopReason.stop,
      message: _assistant(content: [TextContent(text: text)]),
    ),
  );
  return events;
}

List<AssistantMessageEvent> _textTurn(String text) => _textTurnChunks([text]);

/// A thinking turn streamed in [chunks], then a short text answer.
List<AssistantMessageEvent> _thinkingTurnChunks(List<String> chunks) {
  final empty = _assistant();
  final events = <AssistantMessageEvent>[
    StartEvent(partial: empty),
    ThinkingStartEvent(contentIndex: 0, partial: empty),
  ];
  var thinking = '';
  for (final chunk in chunks) {
    thinking += chunk;
    events.add(
      ThinkingDeltaEvent(
        contentIndex: 0,
        delta: chunk,
        partial: _assistant(content: [ThinkingContent(thinking: thinking)]),
      ),
    );
  }
  final message = _assistant(
    content: [
      ThinkingContent(thinking: thinking),
      const TextContent(text: 'done'),
    ],
  );
  events.add(DoneEvent(reason: StopReason.stop, message: message));
  return events;
}

/// A tool-call turn streaming raw JSON argument fragments in [chunks].
List<AssistantMessageEvent> _toolCallTurnChunks(
  String toolName,
  String id,
  List<String> chunks,
) {
  ToolCall call(String partialArgs) => ToolCall(
    id: id,
    name: toolName,
    arguments: const {},
    partialArguments: partialArgs,
  );
  final empty = _assistant();
  final events = <AssistantMessageEvent>[
    StartEvent(partial: empty),
    ToolCallStartEvent(
      contentIndex: 0,
      partial: _assistant(content: [call('')]),
    ),
  ];
  var args = '';
  for (final chunk in chunks) {
    args += chunk;
    events.add(
      ToolCallDeltaEvent(
        contentIndex: 0,
        delta: chunk,
        partial: _assistant(
          content: [call(args)],
          stopReason: StopReason.toolUse,
        ),
      ),
    );
  }
  events.add(
    DoneEvent(
      reason: StopReason.toolUse,
      message: _assistant(
        content: [call(args)],
        stopReason: StopReason.toolUse,
      ),
    ),
  );
  return events;
}

/// Scripted [StreamFunction] replaying pre-recorded turns; honors the
/// [CancelToken] like a real provider: once cancelled, the remaining events
/// are dropped and an aborted [ErrorEvent] terminates the stream.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

  int get calls => contexts.length;

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
    final stream = AssistantMessageEventStream();
    final events = turns.removeAt(0);
    unawaited(() async {
      AssistantMessage? lastPartial;
      for (final event in events) {
        if (cancelToken?.isCancelled ?? false) {
          final base = lastPartial ?? _assistant();
          stream.push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: base.copyWith(
                stopReason: StopReason.aborted,
                errorMessage: 'Operation aborted',
              ),
            ),
          );
          stream.end();
          return;
        }
        stream.push(event);
        lastPartial = event.partial;
        await Future<void>.delayed(Duration.zero);
      }
      stream.end();
    }());
    return stream;
  }
}

/// Host persistence seam mirroring the CLI's batch model: messages persist
/// lazily at run end ([flush]); the controller flushes what it anchors
/// through [sink] on demand.
class _TestHost {
  _TestHost(this.session);

  Session? session;
  var persistedCount = 0;

  TtsrSessionSink get sink => TtsrSessionSink(
    session: () => session,
    persistedMessageCount: () => persistedCount,
    persistMessage: (message) async {
      await session!.appendMessage(message);
      persistedCount++;
    },
    persistInjection: (content, rules) async {
      await session!.appendCustomMessageEntry(
        customType: ttsrInjectionCustomType,
        content: content,
        display: false,
        details: {'rules': rules},
      );
      await session!.appendCustomEntry(
        customType: ttsrInjectionRecordType,
        data: {'rules': rules},
      );
      persistedCount++;
    },
  );

  /// Simulates the host's run-end batch persistence.
  Future<void> flush(Agent agent) async {
    final messages = agent.state.messages;
    for (final message in messages.skip(persistedCount)) {
      await session!.appendMessage(message);
    }
    persistedCount = messages.length;
  }
}

TtsrRule _rule(String name, String pattern, {TtsrScope? scope}) {
  return TtsrRule(
    name: name,
    patterns: [pattern],
    body: 'rule body for $name',
    scope: scope ?? TtsrScope.defaultScope,
  );
}

TtsrSettings _settings({TtsrContextMode? contextMode, int? maxInjections}) {
  return TtsrSettings(
    contextMode: contextMode ?? TtsrContextMode.discard,
    maxInjectionsPerTurn: maxInjections ?? 3,
    retryDelay: Duration.zero,
  );
}

Agent _agent(_FakeStreamFunction fake, {TransformContextHook? transform}) {
  return Agent(
    model: _model,
    streamFunction: fake.call,
    toolExecutor: (toolCall, cancelToken, onUpdate) async {
      return ToolExecutionResult.text('executed ${toolCall.name}');
    },
    transformContext: transform,
  );
}

String _render(Message message) {
  return switch (message) {
    UserMessage(:final content) =>
      content is String
          ? content
          : (content as List<ContentBlock>)
                .whereType<TextContent>()
                .map((block) => block.text)
                .join(),
    AssistantMessage(:final content) =>
      content.whereType<TextContent>().map((block) => block.text).join(),
    ToolResultMessage(:final content) =>
      content.whereType<TextContent>().map((block) => block.text).join(),
    _ => '',
  };
}

void main() {
  late JsonlSessionRepo repo;

  setUp(() {
    repo = JsonlSessionRepo(fs: MemoryFileSystem(), sessionsRoot: '/sessions');
  });

  Future<Session> newSession() {
    return repo.create(JsonlSessionCreateOptions(cwd: '/work'));
  }

  group('TtsrController abort/inject/retry', () {
    test(
      'aborts mid-stream, injects the reminder, and retries corrected',
      () async {
        final fake = _FakeStreamFunction([
          _textTurnChunks(['I will use con', 'sole.log(', ') here']),
          _textTurn('Switched to the logger.'),
        ]);
        final agent = _agent(fake);
        final manager = TtsrManager(settings: _settings())
          ..addRule(_rule('no-console', r'console\.log\('));
        final triggered = <List<String>>[];
        final controller = TtsrController(
          agent: agent,
          manager: manager,
          onTriggered: (rules) =>
              triggered.add([for (final rule in rules) rule.name]),
        );

        await agent.prompt('add logging');
        await controller.settled;

        expect(fake.calls, 2);
        expect(triggered, [
          ['no-console'],
        ]);
        final messages = agent.state.messages;
        // Discard mode: the violating partial is dropped.
        final assistants = messages.whereType<AssistantMessage>().toList();
        expect(assistants, hasLength(1));
        expect(assistants.single.stopReason, StopReason.stop);
        expect(
          (assistants.single.content.single as TextContent).text,
          'Switched to the logger.',
        );
        // Order: prompt, hidden injection, corrected answer.
        expect(messages, hasLength(3));
        final injection = messages[1] as UserMessage;
        expect(
          injection.content as String,
          contains(
            '<system-interrupt reason="rule_violation" rule="no-console"',
          ),
        );
        expect(
          injection.content as String,
          contains('rule body for no-console'),
        );
        expect(injection.content as String, contains('</system-interrupt>'));
        // A clean retry ends the chain.
        expect(controller.injectionsThisChain, 0);
        expect(controller.isAbortPending, isFalse);
      },
    );

    test(
      'the retry context carries the injection, not the violation',
      () async {
        final fake = _FakeStreamFunction([
          _textTurnChunks(['using con', 'sole.log(']),
          _textTurn('fixed'),
        ]);
        final transformed = <List<Message>>[];
        final agent = _agent(
          fake,
          transform: (messages, cancelToken) {
            transformed.add(List.of(messages));
            return messages;
          },
        );
        final manager = TtsrManager(settings: _settings())
          ..addRule(_rule('no-console', r'console\.log\('));
        final controller = TtsrController(agent: agent, manager: manager);

        await agent.prompt('go');
        await controller.settled;

        expect(transformed, hasLength(2));
        final retryMessages = transformed[1];
        // transformContext sees the injected reminder on the retry.
        expect(
          retryMessages.any(
            (message) =>
                message is UserMessage &&
                (message.content as String).contains('<system-interrupt'),
          ),
          isTrue,
        );
        // The violating partial is not in the retry context (discard).
        final retryText = retryMessages.map(_render).join('\n');
        expect(retryText.contains('console.log('), isFalse);
        // Same for the raw context the provider received.
        final providerText = fake.contexts[1].messages.map(_render).join('\n');
        expect(providerText.contains('<system-interrupt'), isTrue);
        expect(providerText.contains('console.log('), isFalse);
      },
    );

    test('contextMode keep retains the partial before the reminder', () async {
      final fake = _FakeStreamFunction([
        _textTurnChunks(['bad con', 'sole.log(']),
        _textTurn('fixed'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(
        settings: _settings(contextMode: TtsrContextMode.keep),
      )..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      final messages = agent.state.messages;
      expect(messages, hasLength(4));
      final partial = messages[1] as AssistantMessage;
      expect(partial.stopReason, StopReason.aborted);
      expect((partial.content.single as TextContent).text, 'bad console.log(');
      expect(
        (messages[2] as UserMessage).content as String,
        contains('<system-interrupt'),
      );
      expect((messages[3] as AssistantMessage).stopReason, StopReason.stop);
    });

    test('a fired rule does not re-fire on the retry', () async {
      final fake = _FakeStreamFunction([
        _textTurnChunks(['using con', 'sole.log( now']),
        _textTurnChunks(['still con', 'sole.log( here']),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      // The retry violates the same rule, but it is already injected
      // (repeatMode once) — no second abort.
      expect(fake.calls, 2);
      expect(manager.injectedRuleNames, ['no-console']);
      final assistants = agent.state.messages
          .whereType<AssistantMessage>()
          .toList();
      expect(assistants, hasLength(1));
      expect(assistants.single.stopReason, StopReason.stop);
      expect(
        (assistants.single.content.single as TextContent).text,
        'still console.log( here',
      );
    });

    test('the per-turn injection cap stops the retry storm', () async {
      final fake = _FakeStreamFunction([
        _textTurn('alpha one'),
        _textTurn('beta two'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings(maxInjections: 1))
        ..addRule(_rule('rule-a', 'alpha'))
        ..addRule(_rule('rule-b', 'beta'));
      final warnings = <String>[];
      final controller = TtsrController(
        agent: agent,
        manager: manager,
        onWarning: warnings.add,
      );

      await agent.prompt('go');
      await controller.settled;

      // rule-b matches on the retry, but the chain already used its one
      // injection: no second abort, no injection for rule-b.
      expect(fake.calls, 2);
      expect(manager.injectedRuleNames, ['rule-a']);
      expect(warnings.any((w) => w.contains('cap reached')), isTrue);
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
      expect((last.content.single as TextContent).text, 'beta two');
      expect(controller.injectionsThisChain, 0);
    });

    test('thinking deltas trigger rules scoped to thinking', () async {
      final fake = _FakeStreamFunction([
        _thinkingTurnChunks(['plan: use con', 'sole.log(']),
        _textTurn('fixed'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(
          _rule(
            'no-console-thinking',
            r'console\.log\(',
            scope: const TtsrScope(
              allowText: false,
              allowThinking: true,
              allowAnyTool: false,
            ),
          ),
        );
      final triggered = <String>[];
      final controller = TtsrController(
        agent: agent,
        manager: manager,
        onTriggered: (rules) => triggered.add(rules.single.name),
      );

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 2);
      expect(triggered, ['no-console-thinking']);
    });

    test('default-scope rules do not watch thinking deltas', () async {
      final fake = _FakeStreamFunction([
        _thinkingTurnChunks(['plan: use console.log(']),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 1);
      expect(manager.injectedRuleNames, isEmpty);
    });

    test('tool-call argument deltas trigger tool-scoped rules', () async {
      final fake = _FakeStreamFunction([
        _toolCallTurnChunks('edit', 'call-1', [
          '{"path":"a.ts","oldText":"con',
          'sole.log("x")","newText":""}',
        ]),
        _textTurn('rewrote without console.log'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final triggered = <String>[];
      final controller = TtsrController(
        agent: agent,
        manager: manager,
        onTriggered: (rules) => triggered.add(rules.single.name),
      );

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 2);
      expect(triggered, ['no-console']);
      // The aborted tool call never executed.
      expect(agent.state.messages.whereType<ToolResultMessage>(), isEmpty);
    });

    test('tool-name-scoped rules ignore other tools', () async {
      final fake = _FakeStreamFunction([
        _toolCallTurnChunks('write', 'call-1', [
          '{"path":"a.ts","content":"console.log(1)"}',
        ]),
        _textTurn('done'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(
          _rule(
            'no-console-in-edit',
            r'console\.log\(',
            scope: const TtsrScope(
              allowText: false,
              allowAnyTool: false,
              toolNames: {'edit'},
            ),
          ),
        );
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      // No abort (the rule scopes to edit only); the write tool call
      // executed and the loop continued with a second, clean turn.
      expect(fake.calls, 2);
      expect(manager.injectedRuleNames, isEmpty);
      expect(agent.state.messages.whereType<ToolResultMessage>(), hasLength(1));
    });

    test('no rules configured: the stream is never interrupted', () async {
      final fake = _FakeStreamFunction([_textTurn('console.log(1)')]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings());
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 1);
      expect(agent.state.messages.last, isA<AssistantMessage>());
    });

    test('disabled TTSR never interrupts', () async {
      final fake = _FakeStreamFunction([_textTurn('console.log(1)')]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: const TtsrSettings(enabled: false))
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 1);
      expect(manager.hasRules(), isFalse);
    });

    test('reset clears pending state and injected rules', () async {
      final fake = _FakeStreamFunction([
        _textTurnChunks(['using con', 'sole.log(']),
        _textTurn('fixed'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(agent: agent, manager: manager);

      await agent.prompt('go');
      await controller.settled;
      expect(manager.injectedRuleNames, ['no-console']);

      controller.reset();
      expect(manager.injectedRuleNames, isEmpty);
      expect(controller.injectionsThisChain, 0);
      expect(controller.isAbortPending, isFalse);
    });
  });

  group('TtsrController persistence', () {
    test(
      'injection persists as records and survives compaction rebuild',
      () async {
        final host = _TestHost(await newSession());
        final fake = _FakeStreamFunction([
          _textTurnChunks(['I will use con', 'sole.log(']),
          _textTurn('Switched to the logger.'),
        ]);
        final agent = _agent(fake);
        final manager = TtsrManager(settings: _settings())
          ..addRule(_rule('no-console', r'console\.log\('));
        final controller = TtsrController(
          agent: agent,
          manager: manager,
          sink: host.sink,
        );

        await agent.prompt('add logging');
        await controller.settled;
        await host.flush(agent);

        // The injection is a hidden ttsr-injection custom message...
        var branch = await host.session!.getBranch();
        final customMessages = branch
            .whereType<CustomMessageRecord>()
            .where((r) => r.customType == ttsrInjectionCustomType)
            .toList();
        expect(customMessages, hasLength(1));
        expect(customMessages.single.display, isFalse);
        expect((customMessages.single.details as Map)['rules'], ['no-console']);
        expect(
          customMessages.single.content as String,
          contains('<system-interrupt reason="rule_violation"'),
        );
        // ...plus a ttsr_injection record of the rule names.
        final records = branch
            .whereType<CustomRecord>()
            .where((r) => r.customType == ttsrInjectionRecordType)
            .toList();
        expect(records, hasLength(1));
        expect(((records.single.data as Map)['rules'] as List).cast<String>(), [
          'no-console',
        ]);
        expect(await readPersistedTtsrInjections(host.session!), [
          'no-console',
        ]);

        // Discard mode: the violating partial never reached the tree.
        var rebuilt = await host.session!.buildContextMessages();
        final rebuiltText = rebuilt.map(_render).join('\n');
        expect(rebuiltText.contains('console.log('), isFalse);
        expect(rebuiltText.contains('<system-interrupt'), isTrue);

        // A compaction rebuild keeps the recent injection verbatim...
        final compactor = CompactionManager(
          summarize: (request) async => SummarizationResult.success('summary'),
        );
        final record = await compactor.compactSession(host.session!);
        expect(record, isNotNull);
        rebuilt = await host.session!.buildContextMessages();
        final compactedText = rebuilt.map(_render).join('\n');
        expect(compactedText.contains('<system-interrupt'), isTrue);
        // ...and the injected-rule record still restores.
        expect(await readPersistedTtsrInjections(host.session!), [
          'no-console',
        ]);
        branch = await host.session!.getBranch();
        expect(branch.whereType<CompactionRecord>(), hasLength(1));
      },
    );

    test('an older injection joins the compaction summary input', () async {
      final host = _TestHost(await newSession());
      final fake = _FakeStreamFunction([
        _textTurnChunks(['using con', 'sole.log(']),
        _textTurn('fixed'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(
        agent: agent,
        manager: manager,
        sink: host.sink,
      );

      await agent.prompt('go');
      await controller.settled;
      await host.flush(agent);

      // Push the injection out of the kept-recent region.
      for (var i = 0; i < 30; i++) {
        await host.session!.appendMessage(
          UserMessage.text('filler $i ${'x' * 4000}'),
        );
      }
      final prompts = <String>[];
      final compactor = CompactionManager(
        summarize: (request) async {
          prompts.add(request.prompt);
          return SummarizationResult.success('summary');
        },
      );
      final record = await compactor.compactSession(host.session!);
      expect(record, isNotNull);
      // The correction survived into the summary the model will see.
      expect(
        prompts.single,
        contains('<system-interrupt reason="rule_violation"'),
      );
      expect(prompts.single, contains('rule body for no-console'));
    });

    test('a session-less host degrades to in-memory injection only', () async {
      final host = _TestHost(null);
      final fake = _FakeStreamFunction([
        _textTurnChunks(['using con', 'sole.log(']),
        _textTurn('fixed'),
      ]);
      final agent = _agent(fake);
      final manager = TtsrManager(settings: _settings())
        ..addRule(_rule('no-console', r'console\.log\('));
      final controller = TtsrController(
        agent: agent,
        manager: manager,
        sink: host.sink,
      );

      await agent.prompt('go');
      await controller.settled;

      expect(fake.calls, 2);
      expect(
        (agent.state.messages[1] as UserMessage).content as String,
        contains('<system-interrupt'),
      );
    });
  });
}
