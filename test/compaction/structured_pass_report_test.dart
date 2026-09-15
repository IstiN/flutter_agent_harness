import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Issue #438 — the structured engine's pass reports must carry honest
/// counters: hidden counts that match the session's hidden_range records,
/// summarized counts that match the checkpoint's covered message records,
/// and the summary text itself. The adapter that maps structured passes
/// onto [AutoCompactorPass] is the surface the CLI report renders —
/// today it drops every counter (the fixture: 28 hidden on disk, «0
/// hidden · 0 summarized» on screen).
void main() {
  const model = Model(
    id: 'm1',
    api: 'anthropic-messages',
    provider: 'p',
    baseUrl: 'http://localhost:1',
    contextWindow: 8000,
    maxTokens: 4096,
  );

  AssistantMessage assistant(String text, {List<ToolCall>? calls}) =>
      AssistantMessage(
        content: [
          TextContent(text: text),
          ...?calls,
        ],
        api: 'anthropic-messages',
        provider: 'p',
        model: 'm1',
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );

  ToolResultMessage result(String callId, String text) => ToolResultMessage(
    toolCallId: callId,
    toolName: 'read',
    content: [TextContent(text: text)],
    isError: false,
    timestamp: DateTime.utc(2026),
  );

  const settings = CompactionSettings(
    enabled: true,
    reserveTokens: 2000,
    keepRecentTokens: 2000,
  );
  StreamFunction scriptedStream() => (model, context, {cancelToken}) {
    final last = context.messages.last;
    final promptText = switch (last) {
      UserMessage() =>
        last.content is String
            ? last.content as String
            : (last.content as List<Object>)
                  .whereType<TextContent>()
                  .map((b) => b.text)
                  .join(),
      _ => '',
    };
    final answer = promptText.contains('<conversation>')
        ? 'checkpoint: the login crash investigation so far'
        : '[1, 2, 3]';
    final stream = AssistantMessageEventStream();
    final partial = assistant(answer);
    stream
      ..push(StartEvent(partial: assistant('')))
      ..push(TextStartEvent(contentIndex: 0, partial: assistant('')))
      ..push(TextDeltaEvent(contentIndex: 0, delta: answer, partial: partial))
      ..push(DoneEvent(reason: StopReason.stop, message: partial));
    stream.end();
    return stream;
  };

  /// The fat synthetic session: user ask, three read pairs with 16k-char
  /// results, closing user ask — enough to push the 8k window over
  /// pressure for hide + checkpoint passes.
  Future<Session> buildSession(JsonlSessionRepo repo) async {
    final session = await repo.create(JsonlSessionCreateOptions(cwd: '/w'));
    await session.appendMessage(UserMessage.text('fix the login crash'));
    for (var i = 0; i < 3; i++) {
      await session.appendMessage(
        assistant(
          'step $i',
          calls: [ToolCall(id: 'c$i', name: 'read', arguments: {})],
        ),
      );
      await session.appendMessage(result('c$i', 'payload $i ${'x' * 16000}'));
      await session.appendMessage(assistant('analysis $i findings'));
    }
    await session.appendMessage(UserMessage.text('what was the exact error?'));
    return session;
  }

  test(
    'structured pass counters match the session hidden_range records',
    () async {
      final fs = MemoryFileSystem();
      final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
      final session = await buildSession(repo);
      final entries = await session.getEntries();
      final state = AgentState(
        model: model,
        messages: [
          for (final r in entries)
            if (r is MessageRecord) r.message,
        ],
      );

      final passes = <AutoCompactorPass>[];
      final ok = await AutoCompactorFactory(
        session: session,
        state: state,
        window: 8000,
        settings: settings,
        sources: AutoCompactorSources(
          smolStream: null,
          smolModel: null,
          mainStream: scriptedStream(),
          mainModel: model,
        ),
        hooks: _RecordingHooks(passes),
      ).run();

      expect(ok, isTrue, reason: 'the structured engine gets under pressure');
      expect(passes, isNotEmpty, reason: 'the fixture really folds');

      final hiddenRanges = (await session.getEntries())
          .whereType<HiddenRangeRecord>()
          .toList();
      expect(
        hiddenRanges,
        isNotEmpty,
        reason: 'the fixture must really hide records',
      );

      var renderedHidden = 0;
      var hidePassIndex = 0;
      for (final pass in passes) {
        final report = formatCompactionReport(pass, auto: true).join('\n');
        final match = RegExp(
          r'records: (\d+) hidden · (\d+) summarized',
        ).firstMatch(report);
        expect(
          match,
          isNotNull,
          reason: 'report must carry counters:\n$report',
        );
        final hidden = int.parse(match!.group(1)!);
        final summarized = int.parse(match.group(2)!);
        if (pass.summary != null) {
          // A checkpoint pass: the summarized count matches its covered
          // message records and the summary renders in the fenced block.
          expect(
            summarized,
            greaterThanOrEqualTo(1),
            reason:
                'a checkpoint that summarized nothing must not claim it:\n'
                '$report',
          );
          expect(
            report,
            contains(pass.summary!.trim()),
            reason: 'the summary text must render',
          );
        } else {
          // A hide pass: hidden matches the ids appended this pass.
          expect(
            hidden,
            hiddenRanges[hidePassIndex].recordIds.length,
            reason:
                'hide pass ${pass.pass} claims $hidden, session recorded '
                '${hiddenRanges[hidePassIndex].recordIds.length}',
          );
          hidePassIndex++;
        }
        renderedHidden += hidden;
      }
      expect(
        renderedHidden,
        hiddenRanges.fold(0, (sum, r) => sum + r.recordIds.length),
        reason: 'rendered hidden counts must match the session hidden_ranges',
      );
    },
  );

  test('checkpoint pass names its engine and summary in the report', () async {
    final fs = MemoryFileSystem();
    final repo = JsonlSessionRepo(fs: fs, sessionsRoot: '/sessions');
    final session = await buildSession(repo);
    final entries = await session.getEntries();
    final state = AgentState(
      model: model,
      messages: [
        for (final r in entries)
          if (r is MessageRecord) r.message,
      ],
    );

    final passes = <AutoCompactorPass>[];
    await AutoCompactorFactory(
      session: session,
      state: state,
      window: 8000,
      settings: settings,
      sources: AutoCompactorSources(
        smolStream: null,
        smolModel: null,
        mainStream: scriptedStream(),
        mainModel: model,
      ),
      hooks: _RecordingHooks(passes),
    ).run();

    final checkpoints = passes.where((p) => p.summary != null).toList();
    expect(checkpoints, isNotEmpty, reason: 'the fixture reaches checkpoint');
    final report = formatCompactionReport(checkpoints.first, auto: true);
    expect(report.first, contains('auto-compacted'));
    expect(
      report.join('\n'),
      contains('checkpoint: the login crash investigation'),
    );
  });
}

class _RecordingHooks implements AutoCompactorHooks {
  _RecordingHooks(this.passes);

  final List<AutoCompactorPass> passes;

  @override
  void onPass(AutoCompactorPass pass) => passes.add(pass);

  @override
  void onDone(int passes, int tokens) {}

  @override
  void onRetry(int attempt, int maxAttempts, Duration backoff, Object error) {}

  @override
  void onBothRolesFailed(Object lastError) {}

  @override
  void onAttemptStart(String label, int attempt, Duration budget) {}

  @override
  void onDelta(String delta) {}
}
