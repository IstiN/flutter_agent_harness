// gh-1617 IT: the run-idle watchdog obeys providerTimeouts.
//
// A scripted provider models a self-hosted llama.cpp warmup: it accepts
// the request, streams ZERO bytes until a fixed wall-clock moment (the
// warmup completes), then answers. The windows are milliseconds, the
// mechanics are the production ones — the agent's run-idle watchdog,
// the transient ladder's watchdog-replay class, and the gh-1554
// timeout precedence (model-scoped window > registry entry > global
// section > floor).
//
// AC1 configured-window survival · AC2 entry-override win ·
// AC3 default parity · AC4 connect-budget stop · AC5 window+source
// naming.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _baseModel = Model(
  id: 'warm-model',
  api: 'openai-completions',
  provider: 'kimi',
  baseUrl: 'https://llama.test/v1',
  contextWindow: 100000,
  maxTokens: 4096,
);

Model _model({Duration? idle, Duration? connect, String baseUrl = 'https://llama.test/v1'}) =>
    Model(
      id: 'warm-model',
      api: 'openai-completions',
      provider: 'kimi',
      baseUrl: baseUrl,
      contextWindow: 100000,
      maxTokens: 4096,
      streamIdleTimeout: idle,
      connectTimeout: connect,
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
    model: 'warm-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
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

/// The scripted warming-up endpoint: every request is accepted and
/// streams nothing until [readyAt] (a FIXED wall-clock moment set on
/// construction — the warmup progresses server-side across replays,
/// exactly like a real llama.cpp loading the model), then the answer
/// streams. A watchdog-killed attempt settles aborted with zero bytes.
final class _WarmingUpProvider {
  _WarmingUpProvider(this.warmup);

  final Duration warmup;
  late final DateTime readyAt = DateTime.now().add(warmup);
  int calls = 0;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    calls++;
    final stream = AssistantMessageEventStream();
    unawaited(() async {
      final remaining = readyAt.difference(DateTime.now());
      if (!remaining.isNegative) {
        final cancelled = (cancelToken?.onCancel ?? Completer<void>().future)
            .then<bool>((_) => true);
        final waited = await Future.any([
          Future<void>.delayed(remaining).then<bool>((_) => false),
          cancelled,
        ]);
        if (waited) {
          // The watchdog's machine cancel: zero bytes streamed.
          stream
            ..push(
              ErrorEvent(
                reason: StopReason.aborted,
                error: _assistant(
                  stopReason: StopReason.aborted,
                  errorMessage: 'Request was aborted',
                ),
              ),
            )
            ..end();
          return;
        }
      }
      for (final event in _textTurn('warmed up')) {
        stream.push(event);
      }
      stream.end();
    }());
    return stream;
  }
}

Agent _agent({
  required Model model,
  required _WarmingUpProvider provider,
  required Duration floor,
  void Function(Object error)? onFire,
}) {
  return Agent(
    model: model,
    streamFunction: transientRetryStreamFunction(
      provider.call,
      delay: const Duration(milliseconds: 5),
    ),
    toolExecutor: (_, _, _) async => ToolExecutionResult.text('unused'),
    runIdleTimeout: floor,
    onRunIdleTimeout: onFire,
  );
}

void main() {
  late ProviderTimeoutsOverride? savedGlobal;
  late List<ProviderTuningEntry> savedEntries;
  late Future<bool> Function(Duration, CancelToken?) savedSleeper;

  setUp(() {
    savedGlobal = providerTimeoutsOverride;
    savedEntries = providerTuningRegistry.entries;
    savedSleeper = transientRetrySleeper;
    providerTimeoutsOverride = null;
    providerTuningRegistry.clear();
    // The ladder's inter-attempt pause is not under test here.
    transientRetrySleeper = (delay, token) async => true;
  });

  tearDown(() {
    providerTimeoutsOverride = savedGlobal;
    providerTuningRegistry.clear();
    providerTuningRegistry.registerAll(savedEntries);
    transientRetrySleeper = savedSleeper;
  });

  group('gh-1617 AC1 — a warming-up model survives under its configured '
      'window', () {
    test('config: streamIdleTimeoutMs above the floor — the warmup '
        'completes, the run answers, no (zero-byte stall) abort', () async {
      final provider = _WarmingUpProvider(const Duration(milliseconds: 240));
      final agent = _agent(
        model: _model(idle: const Duration(milliseconds: 150)),
        provider: provider,
        floor: const Duration(milliseconds: 60),
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      // Attempt 1 was killed at the configured window (150ms) and the
      // replay finished the warmup (240ms total) — the run SURVIVES.
      expect(provider.calls, 2, reason: 'the watchdog replay re-arms');
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
      expect(
        last.content.whereType<TextContent>().map((t) => t.text).join(),
        'warmed up',
      );
      final errors = agent.state.messages
          .whereType<AssistantMessage>()
          .where((m) => m.errorMessage?.contains('(zero-byte stall)') ?? false);
      expect(errors, isEmpty, reason: 'no zero-byte abort under config');
    });
  });

  group('gh-1617 AC2 — the entry override wins over the global section', () {
    test('the entry window keeps its endpoint alive while the global '
        'window aborts another endpoint', () async {
      // Entry override for llama.test only; the global section is
      // tighter than the warmup.
      providerTimeoutsOverride = ProviderTimeoutsOverride(
        streamIdle: const Duration(milliseconds: 80),
      );
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        streamIdle: const Duration(milliseconds: 150),
      );

      final warmup = _WarmingUpProvider(const Duration(milliseconds: 120));
      final covered = _agent(
        model: _model(),
        provider: warmup,
        floor: const Duration(milliseconds: 60),
      );
      await covered.prompt('hi');
      await covered.waitForIdle();
      final coveredLast = covered.state.messages.last as AssistantMessage;
      expect(coveredLast.stopReason, StopReason.stop,
          reason: 'the entry window (150ms) covers the warmup (120ms)');

      final otherWarmup = _WarmingUpProvider(const Duration(milliseconds: 120));
      final uncovered = _agent(
        model: _model(baseUrl: 'https://other.test/v1'),
        provider: otherWarmup,
        floor: const Duration(milliseconds: 60),
      );
      await uncovered.prompt('hi');
      await uncovered.waitForIdle();
      final uncoveredLast = uncovered.state.messages.last as AssistantMessage;
      expect(uncoveredLast.stopReason, StopReason.error,
          reason: 'the global window (80ms) never covers the warmup');
      expect(uncoveredLast.errorMessage, contains('(zero-byte stall)'));
    });
  });

  group('gh-1617 AC3 — unset config keeps today\'s behavior', () {
    test('no config: two watchdog kills, then the zero-byte terminal '
        '(the pre-ticket 2-kill abort)', () async {
      var fires = 0;
      final provider = _WarmingUpProvider(const Duration(milliseconds: 500));
      final agent = _agent(
        model: _baseModel,
        provider: provider,
        floor: const Duration(milliseconds: 60),
        onFire: (_) => fires++,
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(provider.calls, 2, reason: 'the replay budget is bounded');
      expect(fires, 2, reason: 'both silent attempts were watchdog-killed');
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('(zero-byte stall)'));
      expect(last.errorMessage, contains('after 2 attempt(s)'));
    });
  });

  group('gh-1617 AC4 — the replay stops at the connect budget', () {
    test('connectTimeoutMs below the window: one attempt, terminal names '
        'both values', () async {
      final provider = _WarmingUpProvider(const Duration(milliseconds: 500));
      final agent = _agent(
        model: _model(
          idle: const Duration(milliseconds: 150),
          connect: const Duration(milliseconds: 100),
        ),
        provider: provider,
        floor: const Duration(milliseconds: 60),
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(provider.calls, 1,
          reason: 'the connect budget buys no replay (100ms < 150ms window)');
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.error);
      expect(last.errorMessage, contains('(zero-byte stall)'));
      // AC4: the terminal names BOTH values.
      expect(last.errorMessage, contains('100ms'));
      expect(last.errorMessage, contains('150ms'));
    });

    test('connectTimeoutMs == window: the replay still runs (AC1 '
        'shape survives its own budget)', () async {
      final provider = _WarmingUpProvider(const Duration(milliseconds: 240));
      final agent = _agent(
        model: _model(
          idle: const Duration(milliseconds: 150),
          connect: const Duration(milliseconds: 150),
        ),
        provider: provider,
        floor: const Duration(milliseconds: 60),
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(provider.calls, 2, reason: 'budget == window keeps one replay');
      final last = agent.state.messages.last as AssistantMessage;
      expect(last.stopReason, StopReason.stop);
    });
  });

  group('gh-1617 AC5 — the fire names the governing window and source', () {
    test('a raised window names the value and its precedence source', () async {
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        streamIdle: const Duration(milliseconds: 150),
      );
      final errors = <Object>[];
      final provider = _WarmingUpProvider(const Duration(milliseconds: 240));
      final agent = _agent(
        model: _model(),
        provider: provider,
        floor: const Duration(milliseconds: 60),
        onFire: errors.add,
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(errors, isNotEmpty);
      final fire = errors.first.toString();
      expect(fire, contains('run idle watchdog'));
      expect(fire, contains('150ms'));
      expect(fire, contains('provider:llama-local'));
    });

    test('the default fire message stays byte-for-byte (AC3)', () async {
      final errors = <Object>[];
      final provider = _WarmingUpProvider(const Duration(milliseconds: 500));
      final agent = _agent(
        model: _baseModel,
        provider: provider,
        floor: const Duration(milliseconds: 60),
        onFire: errors.add,
      );
      await agent.prompt('hi');
      await agent.waitForIdle();

      expect(errors, isNotEmpty);
      expect(
        errors.first.toString(),
        'agent run produced no events for 0s (run idle watchdog)',
        reason: 'the 60ms floor renders as 0s — the pre-ticket wording',
      );
    });

    test('runIdleWindow exposes the effective window + source for the '
        'stall surfaces', () {
      providerTuningRegistry.register(
        name: 'llama-local',
        baseUrl: 'https://llama.test/v1',
        streamIdle: const Duration(minutes: 33),
      );
      final provider = _WarmingUpProvider(const Duration(milliseconds: 10));
      final agent = _agent(
        model: _model(),
        provider: provider,
        floor: defaultRunIdleTimeout,
      );
      final info = agent.runIdleWindow;
      expect(info.window, const Duration(minutes: 33));
      expect(info.source, 'provider:llama-local');
      expect(info.raised, isTrue);

      final plain = _agent(
        model: _baseModel,
        provider: provider,
        floor: defaultRunIdleTimeout,
      );
      final plainInfo = plain.runIdleWindow;
      expect(plainInfo.window, defaultRunIdleTimeout);
      expect(plainInfo.raised, isFalse);
    });
  });
}
