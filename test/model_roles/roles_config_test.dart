import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

YamlMap _yaml(String source) => loadYaml(source) as YamlMap;

void main() {
  group('ModelRef', () {
    test('parses the provider/modelId shorthand', () {
      final ref = ModelRef.parse('anthropic/claude-sonnet-4');
      expect(ref.provider, 'anthropic');
      expect(ref.modelId, 'claude-sonnet-4');
      expect(ref.apiKeyName, isNull);
    });

    test('keeps slashes in the model id (openrouter ids)', () {
      final ref = ModelRef.parse('openrouter/anthropic/claude-sonnet-4');
      expect(ref.provider, 'openrouter');
      expect(ref.modelId, 'anthropic/claude-sonnet-4');
    });

    test('rejects malformed shorthands', () {
      expect(() => ModelRef.parse('no-slash'), throwsA(isA<ConfigException>()));
      expect(() => ModelRef.parse('/model'), throwsA(isA<ConfigException>()));
      expect(
        () => ModelRef.parse('provider/'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('parses the map form with overrides', () {
      final ref = ModelRef.fromYaml(
        _yaml('''
provider: openai
model: gpt-4o
apiKeyName: OPENAI_API_KEY
baseUrl: https://api.openai.com/v1
contextWindow: 128000
maxTokens: 4096
'''),
      );
      expect(ref.provider, 'openai');
      expect(ref.modelId, 'gpt-4o');
      expect(ref.apiKeyName, 'OPENAI_API_KEY');
      expect(ref.baseUrl, 'https://api.openai.com/v1');
      expect(ref.contextWindow, 128000);
      expect(ref.maxTokens, 4096);
    });

    test('rejects maps without provider or model', () {
      expect(
        () => ModelRef.fromYaml(_yaml('model: gpt-4o\n')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRef.fromYaml(_yaml('provider: openai\n')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects invalid scalar overrides', () {
      expect(
        () => ModelRef.fromYaml(
          _yaml('provider: openai\nmodel: gpt-4o\ncontextWindow: -5\n'),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRef.fromYaml(
          _yaml('provider: openai\nmodel: gpt-4o\napiKeyName: 42\n'),
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('ModelRolesConfig.fromYaml', () {
    test('parses roles, overrides, and retry knobs', () {
      final config = ModelRolesConfig.fromYaml(
        _yaml('''
roles:
  default:
    - openrouter/anthropic/claude-sonnet-4
    - provider: openai
      model: gpt-4o
  smol:
    - openrouter/openai/gpt-4o-mini
modelOverrides:
  - path: ~/work/acme
    roles:
      plan:
        - anthropic/claude-opus-4-5
retry:
  retriesPerEntry: 3
  baseDelayMs: 250
  maxBackoffMs: 4000
  maxWaitMs: 60000
  keyBackoffMs: 30000
'''),
      );
      expect(config.roles.keys, containsAll(['default', 'smol']));
      expect(config.roles['default'], hasLength(2));
      expect(config.roles['default']![1].provider, 'openai');
      expect(config.roles['smol']!.single.modelId, 'openai/gpt-4o-mini');
      expect(config.pathOverrides.single.pattern, '~/work/acme');
      expect(
        config.pathOverrides.single.roles['plan']!.single.modelId,
        'claude-opus-4-5',
      );
      expect(config.retry.retriesPerEntry, 3);
      expect(config.retry.baseDelay, const Duration(milliseconds: 250));
      expect(config.retry.maxBackoff, const Duration(seconds: 4));
      expect(config.retry.maxWait, const Duration(minutes: 1));
      expect(config.retry.keyBackoff, const Duration(seconds: 30));
    });

    test('defaults the retry policy when the section is absent', () {
      final config = ModelRolesConfig.fromYaml(
        _yaml('roles:\n  default:\n    - openai/gpt-4o\n'),
      );
      expect(config.retry.retriesPerEntry, 2);
      expect(config.retry.baseDelay, const Duration(milliseconds: 500));
      expect(config.retry.maxBackoff, const Duration(seconds: 8));
      expect(config.retry.maxWait, const Duration(minutes: 5));
      expect(config.retry.keyBackoff, const Duration(minutes: 1));
    });

    test('rejects unknown roles', () {
      expect(
        () => ModelRolesConfig.fromYaml(
          _yaml('roles:\n  huge:\n    - openai/gpt-4o\n'),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown model role "huge"'),
          ),
        ),
      );
    });

    test('rejects empty chains and non-list chains', () {
      expect(
        () => ModelRolesConfig.fromYaml(_yaml('roles:\n  default: []\n')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRolesConfig.fromYaml(
          _yaml('roles:\n  default: openai/gpt-4o\n'),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a missing roles section and bad override entries', () {
      expect(
        () => ModelRolesConfig.fromYaml(_yaml('retry: {}\n')),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRolesConfig.fromYaml(
          _yaml('''
roles:
  default:
    - openai/gpt-4o
modelOverrides:
  - roles:
      default:
        - openai/gpt-4o
'''),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRolesConfig.fromYaml(
          _yaml('roles:\n  default:\n    - openai/gpt-4o\nretry: 5\n'),
        ),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => ModelRolesConfig.fromYaml(
          _yaml(
            'roles:\n  default:\n    - openai/gpt-4o\nretry:\n  retriesPerEntry: -1\n',
          ),
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('round-trips through toYaml', () {
      const source = '''
roles:
  default:
    - provider: openrouter
      model: anthropic/claude-sonnet-4
    - provider: openai
      model: gpt-4o
      apiKeyName: OPENAI_API_KEY
      baseUrl: https://proxy.example/v1
      contextWindow: 128000
      maxTokens: 4096
  smol:
    - provider: openrouter
      model: openai/gpt-4o-mini
modelOverrides:
  - path: ~/work/acme
    roles:
      default:
        - provider: anthropic
          model: claude-opus-4-5
retry:
  retriesPerEntry: 3
  baseDelayMs: 250
  maxBackoffMs: 4000
  maxWaitMs: 60000
  keyBackoffMs: 30000
''';
      final first = ModelRolesConfig.fromYaml(_yaml(source));
      final second = ModelRolesConfig.fromYaml(_yaml(first.toYaml()));
      expect(second.toYaml(), first.toYaml());
      expect(second.roles['default']![1].apiKeyName, 'OPENAI_API_KEY');
      expect(
        second.pathOverrides.single.roles['default']!.single.provider,
        'anthropic',
      );
      expect(second.retry.retriesPerEntry, 3);
    });
  });

  group('ModelRolesConfig.chainFor', () {
    final config = ModelRolesConfig.fromYaml(
      _yaml('''
roles:
  default:
    - openai/gpt-4o
  smol:
    - openai/gpt-4o-mini
modelOverrides:
  - path: /work
    roles:
      default:
        - anthropic/claude-sonnet-4-5
  - path: /work/acme/**
    roles:
      default:
        - google/gemini-2.5-pro
'''),
    );

    test('path overrides win over the top-level role chain', () {
      expect(
        config.chainFor('default', cwd: '/work')!.single.provider,
        'anthropic',
      );
      expect(
        config.chainFor('default', cwd: '/elsewhere')!.single.modelId,
        'gpt-4o',
      );
    });

    test('the longest matching override pattern wins', () {
      expect(
        config.chainFor('default', cwd: '/work/acme/src')!.single.provider,
        'google',
      );
    });

    test('an override not pinning the role falls through to the role', () {
      expect(
        config.chainFor('smol', cwd: '/work')!.single.modelId,
        'gpt-4o-mini',
      );
    });

    test('unset roles inherit the default chain', () {
      expect(
        config.chainFor('plan', cwd: '/elsewhere')!.single.modelId,
        'gpt-4o',
      );
      expect(config.chainFor('slow')!.single.modelId, 'gpt-4o');
    });

    test('returns null when nothing is configured', () {
      final empty = ModelRolesConfig(
        roles: const {
          'smol': [ModelRef(provider: 'openai', modelId: 'gpt-4o-mini')],
        },
      );
      expect(empty.chainFor('default'), isNull);
    });

    test('rejects unknown role ids', () {
      expect(() => config.chainFor('huge'), throwsA(isA<ConfigException>()));
    });
  });

  group('pathPatternMatches', () {
    test('matches the path itself and subdirectories', () {
      expect(pathPatternMatches('/work', '/work'), isTrue);
      expect(pathPatternMatches('/work', '/work/project'), isTrue);
      expect(pathPatternMatches('/work', '/workbench'), isFalse);
      expect(pathPatternMatches('/work', '/other'), isFalse);
    });

    test('tolerates trailing slashes', () {
      expect(pathPatternMatches('/work/', '/work'), isTrue);
      expect(pathPatternMatches('/work', '/work/'), isTrue);
    });

    test('expands ~ against homeDir', () {
      expect(
        pathPatternMatches('~/work', '/home/u/work', homeDir: '/home/u'),
        isTrue,
      );
      expect(pathPatternMatches('~/work', '/home/u/work'), isFalse);
      expect(pathPatternMatches('~', '/home/u', homeDir: '/home/u'), isTrue);
    });

    test('glob: * stays within a segment, ** crosses segments', () {
      expect(pathPatternMatches('/work/*', '/work/acme'), isTrue);
      expect(pathPatternMatches('/work/*', '/work/acme/src'), isFalse);
      expect(pathPatternMatches('/work/**', '/work/acme/src'), isTrue);
      expect(pathPatternMatches('/work/*/src', '/work/acme/src'), isTrue);
      expect(pathPatternMatches('/work/a*c', '/work/abc'), isTrue);
      expect(pathPatternMatches('/work/acme/**', '/work/other'), isFalse);
    });

    test('dots in patterns are literal', () {
      expect(pathPatternMatches('/work/a.b', '/work/a.b'), isTrue);
      expect(pathPatternMatches('/work/a.b', '/work/axb'), isFalse);
    });
  });

  group('ModelRolesRetryPolicy.backoffFor', () {
    test('exponential with cap and jitter bounds', () {
      const policy = ModelRolesRetryPolicy();
      // jitter 1.0 → full nominal value
      expect(policy.backoffFor(1, 1.0), const Duration(milliseconds: 500));
      expect(policy.backoffFor(2, 1.0), const Duration(seconds: 1));
      expect(policy.backoffFor(3, 1.0), const Duration(seconds: 2));
      expect(policy.backoffFor(4, 1.0), const Duration(seconds: 4));
      expect(policy.backoffFor(5, 1.0), const Duration(seconds: 8));
      expect(policy.backoffFor(9, 1.0), const Duration(seconds: 8));
      // jitter 0.0 → 75% of nominal
      expect(policy.backoffFor(1, 0.0), const Duration(milliseconds: 375));
    });
  });
}
