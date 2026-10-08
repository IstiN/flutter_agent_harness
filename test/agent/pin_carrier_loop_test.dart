/// gh-1409 — the fold carrier rides the OUTGOING request payload inside the
/// agent loop (IT-PIN-1/2/3, E6):
///
/// - IT-PIN-1: a fake-LLM run over a post-compaction window carries the
///   verbatim pin block in the assembled request.
/// - IT-PIN-2: the carrier sits AFTER the compaction boundary — never
///   inside the summarized range (the block is the window's newest
///   context-adjacent message before the live turn).
/// - IT-PIN-3: with the body folded away AND its tool result truncated by
///   the summary serializer, the pins survive (F2: the pin never relies on
///   the summary path).
/// - E6: pre-boundary windows (skill body still in context) render NO
///   carrier — no duplication.
/// - REG-PIN-3 loop-level: the carrier is payload-only — the Agent state
///   (the transcript) is never mutated.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Skill _skill(String name, List<String> operative) {
  final frontmatter = StringBuffer(
    '---\nname: $name\ndescription: $name skill.\n',
  );
  if (operative.isNotEmpty) {
    frontmatter.writeln('operative:');
    for (final line in operative) {
      frontmatter.writeln('  - "$line"');
    }
  }
  frontmatter.writeln('---\nBody.\n');
  return skillFromText(
    frontmatter.toString(),
    filePath: '/work/.fah/skills/$name/SKILL.md',
    fallbackName: name,
    scope: SkillScope.project,
    source: SkillSource.fah,
  )!;
}

const _pin = 'use fleet_sweep.sh; never hand-roll the gh battery';

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

class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;
  final contexts = <Context>[];

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
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

UserMessage _user(String text) =>
    UserMessage(content: text, timestamp: DateTime.utc(2026));

/// A post-compaction window: the projected compaction summary rides as a
/// user message, then the live prompt.
Context _foldedContext() {
  return Context(
    messages: [
      _user('old user turn, folded'),
      _user(
        '$compactionSummaryPrefix\nThe folded checkpoint body.\n'
        '$compactionSummarySuffix',
      ),
    ],
  );
}

void main() {
  final skills = [
    _skill('fleet', [_pin]),
  ];

  test(
    'IT-PIN-1: the assembled request carries the verbatim pin block',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      await agentLoop(
        prompts: [UserMessage.text('continue the sweep')],
        context: _foldedContext(),
        config: AgentLoopConfig(model: _model, operativeSkills: skills),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;
      expect(fake.contexts, hasLength(1));
      final texts = [
        for (final message in fake.contexts.single.messages)
          if (message is UserMessage && message.content is String)
            message.content as String,
      ];
      expect(
        texts.any((t) => t.contains(pinBlockOpenTag) && t.contains('"$_pin"')),
        isTrue,
      );
      expect(texts.any((t) => t.contains('pinned from skill `fleet`')), isTrue);
    },
  );

  test('IT-PIN-2: the carrier sits immediately after the compaction '
      'boundary', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    await agentLoop(
      prompts: [UserMessage.text('continue the sweep')],
      context: _foldedContext(),
      config: AgentLoopConfig(model: _model, operativeSkills: skills),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    ).result;
    final messages = fake.contexts.single.messages;
    final boundaryIndex = messages.indexWhere(
      (message) =>
          message is UserMessage &&
          (message.content as String).startsWith(compactionSummaryPrefix),
    );
    final carrierIndex = messages.indexWhere(
      (message) =>
          message is UserMessage &&
          message.content is String &&
          (message.content as String).contains(pinBlockOpenTag),
    );
    expect(carrierIndex, boundaryIndex + 1);
  });

  test(
    'IT-PIN-3/F2: body folded and summary oblivious — the pin still '
    'rides verbatim (repaired from the registry, never the summary)',
    () async {
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      // The projected summary text makes no mention of the pin at all (the
      // summarizer dropped it) — the carrier is the repair.
      await agentLoop(
        prompts: [UserMessage.text('continue the sweep')],
        context: _foldedContext(),
        config: AgentLoopConfig(model: _model, operativeSkills: skills),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;
      final requestText = fake.contexts.single.messages
          .map(
            (message) => message is UserMessage && message.content is String
                ? message.content as String
                : '',
          )
          .join('\n');
      expect(requestText.contains(_pin), isTrue);
    },
  );

  test('E6: a pre-boundary window (body still in context) renders no '
      'carrier', () async {
    final fake = _FakeStreamFunction([_textTurn('ok')]);
    await agentLoop(
      prompts: [UserMessage.text('continue the sweep')],
      context: Context(messages: [_user('fresh session, no folds yet')]),
      config: AgentLoopConfig(model: _model, operativeSkills: skills),
      streamFunction: fake.call,
      toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    ).result;
    final requestText = fake.contexts.single.messages
        .map(
          (message) => message is UserMessage && message.content is String
              ? message.content as String
              : '',
        )
        .join('\n');
    expect(requestText.contains(pinBlockOpenTag), isFalse);
  });

  test(
    'E9: a tiny model window shrinks the pin budget proportionally',
    () async {
      // Under the 512-char parse cap, but the pair cannot fit the
      // tiny window's shrunk budget.
      final longA = 'A' * 450;
      final longB = 'B' * 450;
      final tinySkills = [
        _skill('old', [longA]),
        _skill('new', [longB]),
      ];
      final fake = _FakeStreamFunction([_textTurn('ok')]);
      final tinyModel = Model(
        id: 'tiny',
        api: 'test-api',
        provider: 'test-provider',
        baseUrl: 'https://example.test',
        contextWindow: 4096,
        maxTokens: 1024,
      );
      await agentLoop(
        prompts: [UserMessage.text('continue')],
        context: _foldedContext(),
        config: AgentLoopConfig(model: tinyModel, operativeSkills: tinySkills),
        streamFunction: fake.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;
      final requestText = fake.contexts.single.messages
          .whereType<UserMessage>()
          .map((m) => m.content is String ? m.content as String : '')
          .join('\n');
      final carriesA = requestText.contains('"$longA"');
      final carriesB = requestText.contains('"$longB"');
      expect(carriesA || carriesB, isTrue, reason: 'at least one pin rides');
      expect(carriesA && carriesB, isFalse, reason: 'E9: the pair never fits');
      // Same window, no budget pressure: a 1M window carries both.
      final big = _FakeStreamFunction([_textTurn('ok')]);
      await agentLoop(
        prompts: [UserMessage.text('continue')],
        context: _foldedContext(),
        config: AgentLoopConfig(model: _model, operativeSkills: tinySkills),
        streamFunction: big.call,
        toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
      ).result;
      final bigText = big.contexts.single.messages
          .whereType<UserMessage>()
          .map((m) => m.content is String ? m.content as String : '')
          .join('\n');
      expect(bigText.contains('"$longA"'), isTrue);
      expect(bigText.contains('"$longB"'), isTrue);
    },
  );

  test('P1: the carrier is payload-only — Agent transcript state is never '
      'mutated', () async {
    Future<ToolExecutionResult> unusedExecutor(_, _, _) async {
      return ToolExecutionResult.text('unused');
    }

    final agent = Agent(
      model: _model,
      streamFunction: _FakeStreamFunction([_textTurn('ok')]).call,
      toolExecutor: unusedExecutor,
      operativeSkills: skills,
    );
    agent.state.systemPrompt = 'test';
    final foldedWindow = <Message>[
      _user('old user turn, folded'),
      _user(
        '$compactionSummaryPrefix\nThe folded checkpoint body.\n'
        '$compactionSummarySuffix',
      ),
    ];
    agent.state.messages = List.of(foldedWindow);
    final before = List.of(agent.state.messages);
    await agent.prompt('continue the sweep');
    expect(agent.state.messages.length, before.length + 2); // prompt + reply
    for (var i = 0; i < before.length; i++) {
      expect(identical(agent.state.messages[i], before[i]), isTrue);
    }
    final transcriptText = agent.state.messages
        .map(
          (message) => message is UserMessage && message.content is String
              ? message.content as String
              : '',
        )
        .join('\n');
    expect(transcriptText.contains(pinBlockOpenTag), isFalse);
  });
}
