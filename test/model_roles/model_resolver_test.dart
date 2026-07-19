import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

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
    TextDeltaEvent(contentIndex: 0, delta: text, partial: full),
    DoneEvent(reason: StopReason.stop, message: full),
  ];
}

List<AssistantMessageEvent> _rateLimitTurn(Model model) {
  return [
    StartEvent(partial: _msg(model)),
    ErrorEvent(
      reason: StopReason.error,
      error: _msg(model, stop: StopReason.error, error: '429: rate limited'),
    ),
  ];
}

/// A fake `streamFactory` for [ModelRolesResolver]: scripted turns per
/// model id, recording the call order.
class _FactoryFake {
  final Map<String, List<List<AssistantMessageEvent>>> scripts;
  final calls = <String>[];

  _FactoryFake(this.scripts);

  StreamFunction call(String kind, String apiKey) {
    return (model, context, {cancelToken}) {
      calls.add(model.id);
      final queue = scripts[model.id]!;
      final stream = AssistantMessageEventStream();
      for (final event in queue.removeAt(0)) {
        stream.push(event);
      }
      stream.end();
      return stream;
    };
  }
}

StreamFunction _neverStream(String kind, String apiKey) {
  return (model, context, {cancelToken}) =>
      throw StateError('no stream expected');
}

void main() {
  group('provider catalog', () {
    test('catalogProvider resolves names and the legacy alias', () {
      expect(catalogProvider('anthropic')!.kind, 'anthropic');
      expect(catalogProvider('openai-completions')!.name, 'openrouter');
      expect(catalogProvider(' OpenRouter ')!.name, 'openrouter');
      expect(catalogProvider('bogus'), isNull);
    });

    test('buildCatalogModel applies catalog defaults and overrides', () {
      final model = buildCatalogModel('anthropic', 'claude-x');
      expect(model.api, 'anthropic-messages');
      expect(model.provider, 'anthropic');
      expect(model.baseUrl, 'https://api.anthropic.com');
      expect(model.contextWindow, 200000);
      final custom = buildCatalogModel(
        'google',
        'gemini-x',
        baseUrl: 'https://proxy.example',
        contextWindow: 500,
        maxTokens: 100,
      );
      expect(custom.baseUrl, 'https://proxy.example');
      expect(custom.contextWindow, 500);
      expect(custom.maxTokens, 100);
      expect(
        () => buildCatalogModel('bogus', 'x'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('buildCliDefaultModel keeps the legacy CLI defaults', () {
      final anthropic = buildCliDefaultModel('anthropic');
      expect(anthropic.id, 'claude-sonnet-4-5');
      expect(anthropic.api, 'anthropic-messages');
      final google = buildCliDefaultModel('google');
      expect(google.id, 'gemini-2.5-pro');
      expect(google.contextWindow, 1000000);
      final openrouter = buildCliDefaultModel('openai-completions');
      expect(openrouter.provider, 'openrouter');
      expect(openrouter.baseUrl, 'https://openrouter.ai/api/v1');
      final custom = buildCliDefaultModel(
        'openai-completions',
        baseUrl: 'https://proxy.example/v1',
      );
      expect(custom.provider, 'openai');
      expect(custom.baseUrl, 'https://proxy.example/v1');
      expect(
        () => buildCliDefaultModel('bogus'),
        throwsA(isA<ConfigException>()),
      );
    });

    test(
      'providerStreamFunction builds adapters and rejects unknown kinds',
      () {
        for (final kind in const [
          'openai-completions',
          'anthropic',
          'google',
        ]) {
          expect(providerStreamFunction(kind, 'k'), isA<StreamFunction>());
        }
        expect(
          () => providerStreamFunction('bogus', 'k'),
          throwsA(isA<ConfigException>()),
        );
      },
    );
  });

  group('ModelRolesResolver', () {
    final config = ModelRolesConfig(
      roles: const {
        'default': [
          ModelRef(provider: 'anthropic', modelId: 'claude-main'),
          ModelRef(provider: 'openai', modelId: 'gpt-backup'),
        ],
        'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
      },
      pathOverrides: const [
        PathRoleOverride(
          pattern: '/special',
          roles: {
            'default': [ModelRef(provider: 'google', modelId: 'gemini-scoped')],
          },
        ),
      ],
    );

    test('resolves the role chain into catalog models and key rings', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {
          'ANTHROPIC_API_KEY': 'a-key',
          'ANTHROPIC_API_KEY_2': 'a-key-2',
          'OPENAI_API_KEY': 'o-key',
        },
        streamFactory: _neverStream,
      );
      final chain = resolver.chainFor('default')!;
      expect(chain, hasLength(2));
      expect(chain.first.model.id, 'claude-main');
      expect(chain.first.model.api, 'anthropic-messages');
      expect(chain.first.keyRing.length, 2); // rotation stack collected
      expect(chain.last.keyRing.baseName, 'OPENAI_API_KEY');
    });

    test('path-scoped overrides pin the chain for a matching cwd', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {'GOOGLE_API_KEY': 'g-key'},
        cwd: '/special/project',
        streamFactory: _neverStream,
      );
      expect(resolver.chainFor('default')!.single.model.id, 'gemini-scoped');
    });

    test('entries with missing keys are skipped, never silently', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {'OPENAI_API_KEY': 'o-key'},
        streamFactory: _neverStream,
      );
      final chain = resolver.chainFor('default')!;
      expect(chain.single.model.id, 'gpt-backup');
      expect(
        resolver.skippedEntries['default']!.single,
        contains('claude-main'),
      );
      expect(
        resolver.skippedEntries['default']!.single,
        contains('ANTHROPIC_API_KEY'),
      );
    });

    test('a role whose entries all miss keys throws ConfigException', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {},
        streamFactory: _neverStream,
      );
      expect(
        () => resolver.chainFor('smol'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('no usable chain entry'),
          ),
        ),
      );
    });

    test('unknown providers in a chain throw ConfigException', () {
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'default': [ModelRef(provider: 'bogus', modelId: 'x')],
          },
        ),
        secrets: const {},
        streamFactory: _neverStream,
      );
      expect(
        () => resolver.chainFor('default'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('resolveRole is null when neither role nor default is configured', () {
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'smol': [ModelRef(provider: 'anthropic', modelId: 'claude-smol')],
          },
        ),
        secrets: const {'ANTHROPIC_API_KEY': 'a-key'},
        streamFactory: _neverStream,
      );
      expect(resolver.resolveRole('default'), isNull);
      expect(resolver.resolveRole('smol'), isNotNull);
    });

    test('unset roles resolve through the default chain (inheritance)', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {
          'ANTHROPIC_API_KEY': 'a-key',
          'OPENAI_API_KEY': 'o-key',
        },
        streamFactory: _neverStream,
      );
      final plan = resolver.resolveRole('plan')!;
      expect(plan.model.id, 'claude-main');
    });

    test('applyToAgent runs the agent through the role chain', () async {
      final good = buildCatalogModel('openai', 'gpt-backup');
      final main = buildCatalogModel('anthropic', 'claude-main');
      final fake = _FactoryFake({
        // Both stacked keys 429: key rotation (free) precedes model
        // fallback (omp order).
        'claude-main': [_rateLimitTurn(main), _rateLimitTurn(main)],
        'gpt-backup': [_okTurn(good, 'backup answered')],
        'gpt-smol': [
          _okTurn(buildCatalogModel('openai', 'gpt-smol'), 'smol answered'),
        ],
      });
      final notices = <FallbackNotice>[];
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: const {
            'default': [
              ModelRef(provider: 'anthropic', modelId: 'claude-main'),
              ModelRef(provider: 'openai', modelId: 'gpt-backup'),
            ],
            // A distinct key stack: benches on the anthropic ring must not
            // starve the smol role.
            'smol': [ModelRef(provider: 'openai', modelId: 'gpt-smol')],
          },
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {
          'ANTHROPIC_API_KEY': 'a-key',
          'ANTHROPIC_API_KEY_2': 'a-key-2',
          'OPENAI_API_KEY': 'o-key',
        },
        onNotice: notices.add,
        streamFactory: fake.call,
      );
      final agent = Agent(
        toolRegistry: ToolRegistry(const []),
        streamFunction: _neverStream('unused', 'unused'),
      );

      resolver.applyToAgent(agent);
      expect(agent.state.model.id, 'claude-main');
      await agent.prompt('hi');

      expect(fake.calls, ['claude-main', 'claude-main', 'gpt-backup']);
      final assistant = agent.state.messages.last as AssistantMessage;
      expect(assistant.model, 'gpt-backup');
      expect(assistant.stopReason, StopReason.stop);
      expect(notices.map((n) => n.kind), [
        FallbackNoticeKind.keyRotation,
        FallbackNoticeKind.modelFallback,
      ]);

      // A run on another role uses that role's chain.
      resolver.applyToAgent(agent, role: 'smol');
      await agent.prompt('again');
      expect(fake.calls.last, 'gpt-smol');
      expect((agent.state.messages.last as AssistantMessage).model, 'gpt-smol');
    });

    test('setDefaultChain re-pins the default role', () {
      final resolver = ModelRolesResolver(
        config: config,
        secrets: const {
          'ANTHROPIC_API_KEY': 'a-key',
          'OPENAI_API_KEY': 'o-key',
        },
        streamFactory: _neverStream,
      );
      expect(resolver.resolveRole('default')!.model.id, 'claude-main');
      resolver.setDefaultChain(const [
        ModelRef(provider: 'openai', modelId: 'gpt-new'),
      ]);
      final resolved = resolver.resolveRole('default')!;
      expect(resolved.model.id, 'gpt-new');
      expect(() => resolver.setDefaultChain(const []), throwsArgumentError);
    });

    test('describeRoles renders chains with the active marker', () async {
      final fake = _FactoryFake({
        'claude-main': [
          _rateLimitTurn(buildCatalogModel('anthropic', 'claude-main')),
        ],
        'gpt-backup': [
          _okTurn(buildCatalogModel('openai', 'gpt-backup'), 'ok'),
        ],
      });
      final resolver = ModelRolesResolver(
        config: ModelRolesConfig(
          roles: config.roles,
          retry: const ModelRolesRetryPolicy(retriesPerEntry: 0),
        ),
        secrets: const {
          'ANTHROPIC_API_KEY': 'a-key',
          'OPENAI_API_KEY': 'o-key',
        },
        streamFactory: fake.call,
      );
      final before = resolver.describeRoles();
      expect(before, contains('default:'));
      expect(before, contains('anthropic/claude-main'));
      expect(before, contains('openai/gpt-backup'));
      expect(before, contains('smol:'));
      // plan is unset and inherits default.
      expect(before, contains('plan (inherits default):'));

      final agent = Agent(
        toolRegistry: ToolRegistry(const []),
        streamFunction: _neverStream('unused', 'unused'),
      );
      resolver.applyToAgent(agent);
      await agent.prompt('hi');
      final after = resolver.describeRoles();
      expect(after, contains('* openai/gpt-backup'));
      expect(after, contains('cooldown'));
    });
  });
}
