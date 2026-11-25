// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

/// GOAL #2394 — the compactor factory's mode table and no-fallback
/// contract (AC1/AC4/AC11/AC14: IT-04, IT-05, IT-12, IT-16, UT-30) on a
/// real session with a scripted main stream.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'm1',
  api: 'openai-completions',
  provider: 'p',
  baseUrl: 'http://localhost:1',
  contextWindow: 800,
  maxTokens: 4096,
);

/// Window 800, reserve 200 → hard trigger 600; keep-recent 200.
const _settings = CompactionSettings(
  enabled: true,
  reserveTokens: 200,
  keepRecentTokens: 200,
);

const _transfer =
    '## Open User Requests\n- fix the login crash\n## Hand-over\n'
    'The crash is a null deref; the guard is half-written.';

AssistantMessage _assistant(String text, {List<ToolCall>? calls}) =>
    AssistantMessage(
      content: [
        TextContent(text: text),
        ...?calls,
      ],
      api: 'openai-completions',
      provider: 'p',
      model: 'm1',
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.utc(2026),
    );

/// A scripted stream: answers `replies` in order, records every request,
/// or throws when [replies] is empty.
final class _Fake {
  _Fake(this.replies);
  final List<String> replies;
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
    if (contexts.length > replies.length) {
      throw StateError('hand-over call failed: boom');
    }
    final message = _assistant(replies[contexts.length - 1]);
    final stream = AssistantMessageEventStream();
    stream.push(StartEvent(partial: message));
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  }
}

final class _Hooks implements AutoCompactorHooks {
  final passes = <AutoCompactorPass>[];
  ({int passes, int tokens, String? reason})? done;
  final bothRolesFailed = <Object>[];

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onDelta(String delta) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onDone(int passes, int tokens, {String? reason}) =>
      done = (passes: passes, tokens: tokens, reason: reason);

  @override
  void onBothRolesFailed(Object lastError) => bothRolesFailed.add(lastError);
}

String _textOf(Message m) => switch (m) {
  UserMessage(:final content) =>
    content is String
        ? content
        : (content as List<ContentBlock>)
              .whereType<TextContent>()
              .map((b) => b.text)
              .join('\n'),
  AssistantMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  ToolResultMessage() =>
    m.content.whereType<TextContent>().map((b) => b.text).join('\n'),
  _ => '',
};

void main() {
  late MemoryFileSystem fs;
  late JsonlSessionRepo repo;

  setUp(() {
    fs = MemoryFileSystem();
    repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
  });

  /// user ask (seq 2) · 3 tool pairs with 100-token results · 3 filler
  /// turns · closing user ask (~350 tokens: under the hard line 600).
  Future<Session> session() async {
    final s = await repo.create(JsonlSessionCreateOptions(cwd: '/work'));
    await s.appendMessage(UserMessage.text('fix the login crash'));
    for (var i = 0; i < 3; i++) {
      await s.appendMessage(
        _assistant(
          'step $i',
          calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
        ),
      );
      await s.appendMessage(
        ToolResultMessage(
          toolCallId: 'c$i',
          toolName: 'read',
          content: [TextContent(text: 'payload $i ${'x' * 400}')],
          isError: false,
          timestamp: DateTime.utc(2026),
        ),
      );
      await s.appendMessage(_assistant('analysis $i findings'));
    }
    for (var i = 0; i < 3; i++) {
      await s.appendMessage(_assistant('filler $i'));
    }
    await s.appendMessage(UserMessage.text('what was the exact error?'));
    return s;
  }

  /// The S0 epoch the way the agent loop captures it.
  Future<RequestSnapshot> snapshotOf(Session s, {Model model = _model}) async {
    final projection = await s.buildTranscriptProjection();
    return RequestSnapshot(
      model: model,
      messages: tagTranscript(projection.messages, projection.seqMap),
      systemPrompt: 'sys',
      tools: const [Tool(name: 'read', description: 'd', parameters: {})],
      seqMap: projection.seqMap,
      sentAt: DateTime.now(),
    );
  }

  /// Runs the factory over [s] with the scripted stream and no digest
  /// role; [snapshot] is the S0 the mode table reads.
  Future<bool> runFor(
    Session s,
    _Fake fake,
    _Hooks hooks, {
    RequestSnapshot? snapshot,
    bool softTriggered = false,
    bool force = false,
  }) async => AutoCompactorFactory(
    session: s,
    state: AgentState(model: _model, messages: await s.buildContextMessages()),
    window: 800,
    settings: _settings,
    sources: AutoCompactorSources(
      smolStream: null,
      smolModel: null,
      mainStream: fake.call,
      mainModel: _model,
    ),
    hooks: hooks,
    prompts: const CompactionPrompts(),
    requestSnapshot: snapshot,
    softTriggered: softTriggered,
    force: force,
  ).run();

  bool hasHandOverInstruction(Context context) =>
      context.messages.any((m) => _textOf(m).contains('Fold range: records'));

  test(
    'UT-30 the mode table is exhaustive and selects by its three inputs',
    () {
      // Table: engine × snapshot × role → mode (compaction_mode_test walks
      // every row; here the factory-facing reading of it).
      expect(
        selectCompactionMode(
          engine: CompactionEngine.structured,
          snapshotValid: true,
          separateDigestRole: false,
        ),
        CompactionMode.merged,
      );
      expect(
        selectCompactionMode(
          engine: CompactionEngine.structured,
          snapshotValid: false,
          separateDigestRole: false,
        ),
        CompactionMode.standalone,
      );
      expect(
        selectCompactionMode(
          engine: CompactionEngine.classic,
          snapshotValid: true,
          separateDigestRole: false,
        ),
        CompactionMode.classic,
      );
    },
  );

  group('IT-04 merged mode (valid S0, no separate digest role)', () {
    test('ONE call on the SESSION stream: S0 prefix + instruction; the pass '
        'reports hand-over metrics; no classic record', () async {
      final s = await session();
      final fake = _Fake(['7 old read output\n-\n$_transfer']);
      final hooks = _Hooks();
      final snapshot = await snapshotOf(s);
      expect(
        await runFor(s, fake, hooks, snapshot: snapshot, force: true),
        isTrue,
      );
      expect(fake.contexts, hasLength(1));
      final sent = fake.contexts.single;
      expect(
        [for (final m in sent.messages.take(snapshot.prefixLength)) m.toJson()],
        [for (final m in snapshot.messages) m.toJson()],
      );
      expect(sent.messages, hasLength(snapshot.prefixLength + 1));
      expect(hasHandOverInstruction(sent), isTrue);
      // The judge never ran: no request carried the judge system prompt.
      expect(
        fake.contexts.any(
          (c) => c.systemPrompt == const CompactionPrompts().hideJudgeSystem,
        ),
        isFalse,
      );
      final pass = hooks.passes.single;
      expect(pass.fallback, 'structured·hand-over');
      expect(pass.ok, isTrue);
      expect(pass.handOver, isNotNull);
      expect(pass.handOver!.calls, 1);
      expect(pass.handOver!.hideList, '1 snapped');
      expect(pass.handOver!.transfer, 'text');
      expect(hooks.done?.passes, 1);
      final records = await s.getEntries();
      expect(records.whereType<HiddenRangeRecord>(), hasLength(1));
      expect(records.whereType<CompactCheckpointRecord>(), hasLength(1));
      expect(records.whereType<CompactionRecord>(), isEmpty);
    });

    test(
      'AC11 a soft-armed run waives the hard gate (no force needed)',
      () async {
        final s = await session();
        final fake = _Fake(['7 old read output\n-\n$_transfer']);
        final hooks = _Hooks();
        final snapshot = await snapshotOf(s);
        expect(await runFor(s, fake, hooks, snapshot: snapshot), isTrue);
        expect(fake.contexts, isEmpty, reason: 'under the hard line: no run');
        expect(hooks.done?.reason, contains('trigger gate'));
        expect(
          await runFor(s, fake, hooks, snapshot: snapshot, softTriggered: true),
          isTrue,
        );
        expect(fake.contexts, hasLength(1));
        expect(hooks.passes.single.fallback, 'structured·hand-over');
      },
    );
  });

  group('IT-05 standalone mode (no usable S0)', () {
    test('no snapshot → the judge ladder as today; no hand-over instruction, '
        'no hand-over metrics', () async {
      final s = await session();
      final fake = _Fake(['{"hide":[]}', 'SUMMARY TEXT']);
      final hooks = _Hooks();
      expect(await runFor(s, fake, hooks, force: true), isTrue);
      expect(fake.contexts, isNotEmpty);
      // The standalone ladder's first call is the checkpoint summarizer
      // on its own system prompt (the judge runs only when a hide pass
      // is still warranted after the fold).
      expect(fake.contexts, isNotEmpty);
      expect(fake.contexts.any(hasHandOverInstruction), isFalse);
      expect(hooks.passes.any((p) => p.handOver != null), isFalse);
      expect(
        hooks.passes.any((p) => p.fallback == 'structured·hand-over'),
        isFalse,
      );
    });

    test(
      'a snapshot captured for ANOTHER model is not S0 → standalone',
      () async {
        final s = await session();
        final fake = _Fake(['{"hide":[]}', 'SUMMARY TEXT']);
        final hooks = _Hooks();
        final other = await snapshotOf(
          s,
          model: const Model(
            id: 'other',
            api: 'openai-completions',
            provider: 'p',
            baseUrl: 'http://localhost/1',
            contextWindow: 800,
            maxTokens: 4096,
          ),
        );
        expect(
          await runFor(s, fake, hooks, snapshot: other, force: true),
          isTrue,
        );
        expect(fake.contexts.any(hasHandOverInstruction), isFalse);
      },
    );

    test('a separate smol digest role keeps the standalone ladder even with '
        'a valid S0', () async {
      final s = await session();
      final fake = _Fake(['{"hide":[]}', 'SUMMARY TEXT']);
      final hooks = _Hooks();
      final snapshot = await snapshotOf(s);
      final smol = const Model(
        id: 'smol',
        api: 'openai-completions',
        provider: 'p',
        baseUrl: 'http://localhost/1',
        contextWindow: 8000,
        maxTokens: 4096,
      );
      final compactor = AutoCompactorFactory(
        session: s,
        state: AgentState(
          model: _model,
          messages: await s.buildContextMessages(),
        ),
        window: 800,
        settings: _settings,
        sources: AutoCompactorSources(
          smolStream: fake.call,
          smolModel: smol,
          mainStream: fake.call,
          mainModel: _model,
        ),
        hooks: hooks,
        prompts: const CompactionPrompts(),
        requestSnapshot: snapshot,
        force: true,
      );
      expect(await compactor.run(), isTrue);
      expect(fake.contexts.any(hasHandOverInstruction), isFalse);
      expect(hooks.passes.any((p) => p.handOver != null), isFalse);
    });
  });

  test('IT-12 a soft-armed run in a non-merged mode runs NOTHING and says '
      'why (the hard gate is kept)', () async {
    final s = await session();
    final fake = _Fake(['x']);
    final hooks = _Hooks();
    expect(await runFor(s, fake, hooks, softTriggered: true), isTrue);
    expect(fake.contexts, isEmpty);
    expect(hooks.passes, isEmpty);
    expect(hooks.done?.passes, 0);
    expect(hooks.done?.reason, contains('soft trigger: mode standalone'));
  });

  test('IT-16 a failed merged call → NO fallback: ONE request, a loud failed '
      'run, nothing appended', () async {
    final s = await session();
    final count = (await s.getEntries()).length;
    final fake = _Fake([]);
    final hooks = _Hooks();
    final snapshot = await snapshotOf(s);
    expect(
      await runFor(s, fake, hooks, snapshot: snapshot, force: true),
      isFalse,
    );
    expect(fake.contexts, hasLength(1), reason: 'no classic summarizer call');
    expect(hooks.passes.where((p) => !p.ok), hasLength(1));
    expect(hooks.passes.single.fallback, 'structured·hand-over');
    expect('${hooks.passes.single.error}', contains('hand-over call failed'));
    expect(hooks.bothRolesFailed, hasLength(1));
    expect(hooks.done?.passes, 1);
    expect(await s.getEntries(), hasLength(count));
    expect((await s.getEntries()).whereType<CompactionRecord>(), isEmpty);
  });

  group('AC11/AC14 tuning keys', () {
    test('compaction.softRatio and compaction.handOver.* parse strictly and '
        'merge project over global', () {
      final tuning = CompactionTuning.fromSection({
        'softRatio': 0.5,
        'handOver': {'maxTokens': 4096, 'hysteresisTurns': 5},
      }, label: 'test')!;
      expect(tuning.softRatio, 0.5);
      expect(tuning.handOverMaxTokens, 4096);
      expect(tuning.handOverHysteresisTurns, 5);
      expect(tuning.isEmpty, isFalse);
      final global = CompactionTuning.fromSection({
        'softRatio': 0.4,
        'handOver': {'maxTokens': 2048, 'hysteresisTurns': 2},
      }, label: 'global')!;
      final merged = mergeCompactionTuning(global: global, project: tuning)!;
      expect(merged.softRatio, 0.5);
      expect(merged.handOverMaxTokens, 4096);
      expect(merged.handOverHysteresisTurns, 5);
      final partial = CompactionTuning.fromSection({
        'handOver': {'hysteresisTurns': 7},
      }, label: 'partial')!;
      final mixed = mergeCompactionTuning(global: global, project: partial)!;
      expect(mixed.handOverMaxTokens, 2048);
      expect(mixed.handOverHysteresisTurns, 7);
      expect(mixed.softRatio, 0.4);
      // A section naming only the #2394 keys leaves the hard curve alone.
      final untouched = applyCompactionTuning(
        _settings,
        window: 800,
        tuning: partial,
      );
      expect(untouched.enabled, _settings.enabled);
      expect(untouched.reserveTokens, _settings.reserveTokens);
      expect(untouched.keepRecentTokens, _settings.keepRecentTokens);
    });

    test('invalid values are config errors, never silently ignored', () {
      for (final node in [
        {'softRatio': 1.5},
        {'softRatio': 0},
        {'softRatio': 'half'},
        {'handOver': 3},
        {
          'handOver': {'maxTokens': 0},
        },
        {
          'handOver': {'maxTokens': '8192'},
        },
        {
          'handOver': {'hysteresisTurns': -1},
        },
      ]) {
        expect(
          () => CompactionTuning.fromSection(node, label: 't'),
          throwsA(isA<ConfigException>()),
          reason: '$node',
        );
      }
      // Absent keys mean "no opinion".
      expect(
        CompactionTuning.fromSection({
          'triggerRatio': 0.5,
        }, label: 't')!.handOverMaxTokens,
        isNull,
      );
      expect(
        CompactionTuning.fromSection(const {}, label: 't')!.isEmpty,
        isTrue,
      );
    });

    test('the host wiring carries the knobs (Flutter + CLI share it)', () {
      final wiring = resolveCompactionHostWiring(
        mainModel: _model,
        tuning: CompactionTuning.fromSection({
          'softRatio': 0.6,
          'handOver': {'maxTokens': 1024, 'hysteresisTurns': 4},
        }, label: 't'),
      );
      expect(wiring.softRatio, 0.6);
      expect(wiring.handOverMaxTokens, 1024);
      expect(wiring.handOverHysteresisTurns, 4);
      final plain = resolveCompactionHostWiring(mainModel: _model);
      expect(plain.softRatio, isNull);
      expect(plain.handOverMaxTokens, isNull);
    });
  });
}
