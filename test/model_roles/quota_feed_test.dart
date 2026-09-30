// Issue #823 AC8: the QuotaFeed depletion hint SOFT-BENCHES a provider —
// deprioritized in chain selection, never a hard block. The feed is
// consulted fresh at every decision (no caching) and a throwing feed must
// never break streaming.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Model _model(String provider, String id) => Model(
  id: id,
  api: 'test-api',
  provider: provider,
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _msg(
  Model model, {
  String text = '',
  StopReason stop = StopReason.stop,
  String? error,
}) {
  return AssistantMessage(
    content: text.isEmpty ? const [] : [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stop,
    errorMessage: error,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _okTurn(Model model, String text) {
  final empty = _msg(model);
  final full = _msg(model, text: text);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: full),
    DoneEvent(reason: StopReason.stop, message: full),
  ];
}

List<AssistantMessageEvent> _rateLimitTurn(Model model) {
  final partial = _msg(model);
  return [
    StartEvent(partial: partial),
    ErrorEvent(
      reason: StopReason.error,
      error: _msg(
        model,
        stop: StopReason.error,
        error: '429: rate limit exceeded',
      ),
    ),
  ];
}

/// A scripted stream factory: serves pre-recorded turns per API-key value.
class _Probe {
  final Map<String, List<List<AssistantMessageEvent>>> scriptsByKey;
  final calls = <String>[];

  _Probe(this.scriptsByKey);

  StreamFunction streamForKey(String apiKey) {
    return (model, context, {cancelToken}) {
      calls.add(apiKey);
      final queue = scriptsByKey[apiKey];
      if (queue == null || queue.isEmpty) {
        throw StateError('no scripted turn left for key $apiKey');
      }
      final stream = AssistantMessageEventStream();
      for (final event in queue.removeAt(0)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    };
  }
}

String _signature(AssistantMessageEvent event) => switch (event) {
  StartEvent(:final partial) => 'start:${partial.model}',
  TextStartEvent() => 'textStart',
  TextDeltaEvent(:final delta) => 'delta:$delta',
  DoneEvent(:final message) => 'done:${message.model}',
  ErrorEvent(:final reason, :final error) =>
    'error(${reason.name}):${error.model}:${error.errorMessage}',
  _ => event.runtimeType.toString(),
};

class _FakeFeed implements QuotaFeed {
  _FakeFeed(this.depleted);
  final Set<String> depleted;

  @override
  bool isDepleted(String providerId) => depleted.contains(providerId);
}

class _ThrowingFeed implements QuotaFeed {
  @override
  bool isDepleted(String providerId) => throw StateError('feed exploded');
}

void main() {
  group('quotaFeed soft-bench (issue #823 AC8)', () {
    late DateTime now;
    late List<Duration> sleeps;

    setUp(() {
      now = DateTime.utc(2026);
      sleeps = [];
    });

    ChainEntry entry(_Probe probe, Model model, String keyValue) {
      return ChainEntry(
        model: model,
        keyRing: ApiKeyRing(
          baseName: 'K_${model.provider}',
          credentials: [ApiKeyCredential('K_${model.id}', keyValue)],
          startIndex: 0,
          now: () => now,
        ),
        streamForKey: probe.streamForKey,
      );
    }

    FallbackStreamFunction wrapper(
      List<ChainEntry> entries, {
      QuotaFeed? quotaFeed,
      ModelRolesRetryPolicy policy = const ModelRolesRetryPolicy(),
    }) {
      return FallbackStreamFunction(
        entries: entries,
        policy: policy,
        now: () => now,
        jitterFraction: () => 1.0,
        sleeper: (delay, token) async {
          sleeps.add(delay);
          now = now.add(delay);
          return true;
        },
        quotaFeed: quotaFeed,
      );
    }

    Future<List<String>> run(FallbackStreamFunction w) async {
      final stream = w.call(
        _model('ignored', 'ignored'),
        const Context(messages: []),
      );
      return [for (final event in await stream.toList()) _signature(event)];
    }

    test('depleted provider is skipped: the turn lands on A/C, never B', () async {
      final a = _model('prov-a', 'm-a');
      final b = _model('prov-b', 'm-b');
      final c = _model('prov-c', 'm-c');
      final probe = _Probe({
        'v-a': [_okTurn(a, 'from a'), _okTurn(a, 'from a again')],
        'v-b': [_okTurn(b, 'from b')],
        'v-c': [_okTurn(c, 'from c')],
      });
      final feed = _FakeFeed({'prov-b'});
      final w = wrapper([
        entry(probe, a, 'v-a'),
        entry(probe, b, 'v-b'),
        entry(probe, c, 'v-c'),
      ], quotaFeed: feed);

      // B is depleted: the fresh pick is A (first healthy, non-depleted).
      expect(await run(w), [
        'start:m-a',
        'textStart',
        'delta:from a',
        'done:m-a',
      ]);
      expect(probe.calls, ['v-a']);

      // A depletes too: the scan steps past BOTH depleted entries to C.
      feed.depleted.addAll(['prov-a']);
      expect(await run(w), [
        'start:m-c',
        'textStart',
        'delta:from c',
        'done:m-c',
      ]);
      expect(probe.calls, ['v-a', 'v-c'], reason: 'depleted B never serves');
    });

    test('every candidate depleted: the chain still serves (no hard block)', () async {
      final a = _model('prov-a', 'm-a');
      final b = _model('prov-b', 'm-b');
      final probe = _Probe({
        'v-a': [_okTurn(a, 'from a')],
        'v-b': [_okTurn(b, 'from b')],
      });
      final w = wrapper(
        [entry(probe, a, 'v-a'), entry(probe, b, 'v-b')],
        quotaFeed: _FakeFeed({'prov-a', 'prov-b'}),
      );

      // Soft hint only: the order-based pick still serves rather than
      // dead-ending the run.
      expect(await run(w), [
        'start:m-a',
        'textStart',
        'delta:from a',
        'done:m-a',
      ]);
      expect(probe.calls, ['v-a']);
      expect(sleeps, isEmpty);
    });

    test('feed flips an entry healthy again: it returns to rotation', () async {
      final a = _model('prov-a', 'm-a');
      final b = _model('prov-b', 'm-b');
      final c = _model('prov-c', 'm-c');
      final probe = _Probe({
        'v-b': [_okTurn(b, 'from b')],
        'v-c': [_okTurn(c, 'from c')],
      });
      final feed = _FakeFeed({'prov-a', 'prov-b'});
      final w = wrapper([
        entry(probe, a, 'v-a'),
        entry(probe, b, 'v-b'),
        entry(probe, c, 'v-c'),
      ], quotaFeed: feed);

      // A and B both depleted: C serves.
      expect(await run(w), [
        'start:m-c',
        'textStart',
        'delta:from c',
        'done:m-c',
      ]);
      expect(probe.calls, ['v-c']);

      // B flips healthy: the scan past depleted A now lands on B.
      feed.depleted.remove('prov-b');
      expect(await run(w), [
        'start:m-b',
        'textStart',
        'delta:from b',
        'done:m-b',
      ]);
      expect(probe.calls, ['v-c', 'v-b'], reason: 'B is back in rotation');
    });

    test('quotaFeed == null: routing identical to the pre-#823 behavior', () async {
      final a = _model('prov-a', 'm-a');
      final b = _model('prov-b', 'm-b');
      final probe = _Probe({
        'v-a': [_rateLimitTurn(a)],
        'v-b': [_okTurn(b, 'from b')],
      });
      // No quotaFeed argument at all — the historical call shape.
      final w = wrapper(
        [entry(probe, a, 'v-a'), entry(probe, b, 'v-b')],
        policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
      );

      expect(await run(w), [
        'start:m-b',
        'textStart',
        'delta:from b',
        'done:m-b',
      ]);
      expect(probe.calls, ['v-a', 'v-b']);
      expect(sleeps, isEmpty); // model switches are delay-0 (omp rule)
    });

    test('a throwing feed never breaks streaming', () async {
      final a = _model('prov-a', 'm-a');
      final b = _model('prov-b', 'm-b');
      final probe = _Probe({
        'v-a': [_okTurn(a, 'from a'), _rateLimitTurn(a)],
        'v-b': [_okTurn(b, 'from b')],
      });
      final w = wrapper(
        [entry(probe, a, 'v-a'), entry(probe, b, 'v-b')],
        quotaFeed: _ThrowingFeed(),
        policy: const ModelRolesRetryPolicy(retriesPerEntry: 0),
      );

      // Start-of-chain pick: the throw is swallowed, the order pick serves.
      expect(await run(w), [
        'start:m-a',
        'textStart',
        'delta:from a',
        'done:m-a',
      ]);
      expect(probe.calls, ['v-a']);

      // Run 2 starts at A again (the throw counts as "not depleted"), A
      // rate-limits, and the failover pick swallows the throw again: B
      // serves. Streaming is unaffected throughout.
      expect(await run(w), [
        'start:m-b',
        'textStart',
        'delta:from b',
        'done:m-b',
      ]);
      expect(probe.calls, ['v-a', 'v-a', 'v-b']);
    });
  });

  group('ProviderQueueRuntime.build threads quotaFeed', () {
    late DateTime now;

    setUp(() {
      now = DateTime.utc(2026);
    });

    ProviderQueueRuntime runtime(
      List<ProviderQueueEntry> entries,
      _Probe probe, {
      QuotaFeed? quotaFeed,
    }) => ProviderQueueRuntime.build(
      ProviderQueueResolution(
        scope: ProviderQueueScope.env,
        entries: entries,
        notices: const [],
      ),
      secrets: {'K_API_KEY': 'key-head', 'K2_API_KEY': 'key-two'},
      now: () => now,
      jitterFraction: () => 1.0,
      sleeper: (delay, token) async {
        now = now.add(delay);
        return true;
      },
      streamFactory: (kind, apiKey) => probe.streamForKey(apiKey),
      quotaFeed: quotaFeed,
    );

    test('depleted head provider: the chain starts at the healthy entry', () async {
      final probe = _Probe({
        'key-two': [_okTurn(_model('openai', 'm2'), 'from m2')],
      });
      final rt = runtime(
        [
          ProviderQueueEntry(
            providerType: 'anthropic',
            model: 'm1',
            apiKeyEnv: 'K_API_KEY',
          ),
          ProviderQueueEntry(
            providerType: 'openai-completions',
            model: 'm2',
            baseUrl: 'https://gate.test/v1',
            apiKeyEnv: 'K2_API_KEY',
          ),
        ],
        probe,
        quotaFeed: _FakeFeed({'anthropic'}),
      );

      // The depleted anthropic head is soft-benched; the turn lands on the
      // openai entry.
      expect(rt.streamFunction.currentModel.id, 'm2');
      final stream = rt.streamFunction(
        _model('ignored', 'ignored'),
        const Context(messages: []),
      );
      final signatures = [
        for (final event in await stream.toList()) _signature(event),
      ];
      expect(signatures, [
        'start:m2',
        'textStart',
        'delta:from m2',
        'done:m2',
      ]);
      expect(probe.calls, ['key-two'], reason: 'depleted head never serves');
    });

    test('quotaFeed omitted: the queue head stays primary (today\'s behavior)', () {
      final rt = runtime(
        [
          ProviderQueueEntry(
            providerType: 'anthropic',
            model: 'm1',
            apiKeyEnv: 'K_API_KEY',
          ),
          ProviderQueueEntry(
            providerType: 'openai-completions',
            model: 'm2',
            baseUrl: 'https://gate.test/v1',
            apiKeyEnv: 'K2_API_KEY',
          ),
        ],
        _Probe(const {}),
      );

      expect(rt.streamFunction.currentModel.id, 'm1');
    });
  });
}
