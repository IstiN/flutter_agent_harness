import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

final _model = Model(
  id: 'gpt-4o',
  api: 'openai-completions',
  provider: 'openai',
  baseUrl: 'https://api.openai.com/v1',
  contextWindow: 128000,
  maxTokens: 16384,
);

Context _context() =>
    Context(messages: [UserMessage.text('hi', timestamp: DateTime.utc(2026))]);

AssistantMessageEventStream _okStream() {
  final message = AssistantMessage(
    content: [TextContent(text: 'ok')],
    api: 'openai-completions',
    provider: 'openai',
    model: 'gpt-4o',
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.utc(2026),
  );
  final stream = AssistantMessageEventStream();
  stream.push(StartEvent(partial: message));
  stream.push(DoneEvent(reason: StopReason.stop, message: message));
  stream.end();
  return stream;
}

/// A [StreamFunction] recording the active [StreamCacheRouting] override at
/// call time into [sink].
StreamFunction _recordInto(
  List<({String? sessionId, String? cacheRetention})?> sink,
) {
  return (model, context, {cancelToken}) {
    sink.add(StreamCacheRouting.current);
    return _okStream();
  };
}

void main() {
  group('StreamCacheRouting', () {
    test('is null outside an override and scoped inside runWith', () {
      expect(StreamCacheRouting.current, isNull);
      final seen = StreamCacheRouting.runWith(
        () {
          return StreamCacheRouting.current;
        },
        sessionId: 's',
        cacheRetention: 'none',
      );
      expect(seen, (sessionId: 's', cacheRetention: 'none'));
      expect(StreamCacheRouting.current, isNull);
    });
  });

  group('ModelRolesResolver session binding', () {
    ModelRolesResolver resolverWith(
      List<({String? sessionId, String? cacheRetention})?> sink,
    ) {
      return ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'default': [ModelRef(provider: 'openai', modelId: 'gpt-4o')],
          },
        ),
        secrets: const {'OPENAI_API_KEY': 'k'},
        streamFactory: (kind, apiKey) => _recordInto(sink),
      );
    }

    test('binds the resolver session id into resolved role streams', () async {
      final sink = <({String? sessionId, String? cacheRetention})?>[];
      final resolver = resolverWith(sink);
      // Set after construction, as hosts do once the session exists.
      resolver.sessionId = () => 'sess-9';

      final resolved = resolver.resolveRole('default')!;
      await resolved.stream(resolved.model, _context()).toList();
      expect(sink.single, (sessionId: 'sess-9', cacheRetention: null));
    });

    test(
      'an explicit per-call override wins over the bound session id',
      () async {
        final sink = <({String? sessionId, String? cacheRetention})?>[];
        final resolver = resolverWith(sink);
        resolver.sessionId = () => 'sess-9';

        final resolved = resolver.resolveRole('default')!;
        await StreamCacheRouting.runWith(
          () => resolved.stream(resolved.model, _context()).toList(),
          sessionId: 'fresh-id',
          cacheRetention: 'none',
        );
        expect(sink.single, (sessionId: 'fresh-id', cacheRetention: 'none'));
      },
    );

    test('overrides propagate through the fallback chain', () async {
      final sink = <({String? sessionId, String? cacheRetention})?>[];
      final wrapper = FallbackStreamFunction(
        entries: [
          ChainEntry(
            model: _model,
            keyRing: ApiKeyRing.fromSecrets(const {
              'OPENAI_API_KEY': 'k',
            }, 'OPENAI_API_KEY')!,
            streamForKey: (_) => _recordInto(sink),
          ),
        ],
      );
      // The zone must survive the wrapper's async retry/fallback machinery
      // (the compaction bypass wraps the whole call).
      await StreamCacheRouting.runWith(
        () => wrapper(_model, _context()).toList(),
        sessionId: 'compaction-id',
        cacheRetention: 'none',
      );
      expect(sink.single, (sessionId: 'compaction-id', cacheRetention: 'none'));
    });
  });
}
