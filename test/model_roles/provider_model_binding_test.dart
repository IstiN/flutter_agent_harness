// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('ProviderModelBinding.resolve — identity shape', () {
    test('resolves a catalog record to its wire kind and default endpoint', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'claude-sonnet-4-5',
        provenance: BindingProvenance.flag,
      );
      expect(binding.providerKind, 'anthropic');
      expect(
        binding.baseUrl,
        resolveCliProviderSpec('anthropic')!.defaultBaseUrl,
      );
      expect(binding.modelId, 'claude-sonnet-4-5');
      expect(binding.recordName, isNull);
      expect(binding.provenance, BindingProvenance.flag);
      expect(binding.wireOverride, isFalse);
    });

    test('resolves a catalog NAME record with its own endpoint', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'kimi',
        modelId: 'kimi-k2',
        recordName: 'kimi',
        provenance: BindingProvenance.restore,
      );
      expect(binding.providerKind, 'openai-completions');
      expect(binding.baseUrl, 'https://api.kimi.com/coding/v1');
    });

    test('a key env ref is carried as an indirection, never a value', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'openai/gpt-4o-mini',
        keyEnvRef: 'OPENROUTER_API_KEY',
        provenance: BindingProvenance.env,
      );
      expect(binding.keyEnvRef, 'OPENROUTER_API_KEY');
      expect(binding.echo(), contains('key: \$OPENROUTER_API_KEY'));
    });

    test('bindings with identical identity fields are equal across '
        'provenance (I5 round-trip)', () {
      final a = ProviderModelBinding.resolve(
        providerKind: 'kimi',
        modelId: 'kimi-k2',
        recordName: 'kimi',
        provenance: BindingProvenance.restore,
      );
      final b = ProviderModelBinding.resolve(
        providerKind: 'kimi',
        modelId: 'kimi-k2',
        recordName: 'kimi',
        provenance: BindingProvenance.command,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('echo names record, wire, endpoint and model (I2 report shape)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'kimi',
        modelId: 'kimi-k2',
        recordName: 'kimi',
        provenance: BindingProvenance.env,
      );
      final echo = binding.echo();
      expect(echo, contains('kimi'));
      expect(echo, contains('openai-completions'));
      expect(echo, contains('https://api.kimi.com/coding/v1'));
      expect(echo, contains('kimi-k2'));
    });
  });

  group('ProviderModelBinding.resolve — wire ⇄ endpoint (AC2)', () {
    test('a known endpoint of another dialect is rejected', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'claude-sonnet-4-5',
          baseUrl: 'https://api.openai.com/v1',
          provenance: BindingProvenance.env,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('api.openai.com'), contains('anthropic')),
          ),
        ),
      );
    });

    test('a trailing-slash spelling of a foreign endpoint is caught too '
        '(S4 normalized comparison)', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'claude-sonnet-4-5',
          baseUrl: 'https://api.z.ai/api/coding/paas/v4/',
          provenance: BindingProvenance.env,
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('the explicit wire: override passes and is echoed (E6)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'zai/glm-5.3-flashx',
        baseUrl: 'http://192.168.1.10:8080/v1',
        wire: 'openai-completions',
        provenance: BindingProvenance.env,
      );
      expect(binding.providerKind, 'openai-completions');
      expect(binding.wireOverride, isTrue);
      expect(binding.echo(), contains('wire override'));
    });

    test('an unknown wire: value is rejected', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'claude-sonnet-4-5',
          baseUrl: 'https://api.anthropic.com',
          wire: 'smoke-signals',
          provenance: BindingProvenance.env,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('smoke-signals'),
          ),
        ),
      );
    });

    test('an anthropic-dialect proxy on the anthropic wire passes (no '
        'false positive on unknown endpoints)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'claude-sonnet-4-5',
        baseUrl: 'http://192.168.1.10:8080',
        provenance: BindingProvenance.env,
      );
      expect(binding.providerKind, 'anthropic');
    });
  });

  group('ProviderModelBinding.resolve — model ⇄ endpoint (AC3)', () {
    test('a known openai family id over a known anthropic endpoint is '
        'rejected naming both (H2: --model gpt-5 on saved anthropic)', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'gpt-5',
          provenance: BindingProvenance.flag,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('gpt-5'), contains('api.anthropic.com')),
          ),
        ),
      );
    });

    test('a known google family id over the canonical openai endpoint is '
        'rejected (family-exclusive endpoints carry a verdict)', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'openai',
          modelId: 'gemini-2.5-pro',
          baseUrl: 'https://api.openai.com/v1',
          provenance: BindingProvenance.flag,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('gemini-2.5-pro'), contains('api.openai.com')),
          ),
        ),
      );
    });

    test('a family id over a ROUTER endpoint passes (routers serve many '
        'families — openrouter, copilot, dial carry no verdict)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'gemini-2.5-pro',
        provenance: BindingProvenance.flag,
      );
      expect(binding.modelId, 'gemini-2.5-pro');
    });

    test('a vendor-prefixed id on an openai-dialect binding passes (the '
        'routing convention — openrouter zai/glm ids)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'zai/glm-5.3-flashx',
        provenance: BindingProvenance.command,
      );
      expect(binding.modelId, 'zai/glm-5.3-flashx');
    });

    test('an unknown family id on any endpoint passes (no list to check)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'my-finetune-7b',
        provenance: BindingProvenance.flag,
      );
      expect(binding.modelId, 'my-finetune-7b');
    });

    test('a foreign-family id on an UNKNOWN endpoint passes (D2 unverified '
        'territory, not a rejection)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'gpt-5',
        baseUrl: 'http://192.168.1.10:8080/v1',
        provenance: BindingProvenance.flag,
      );
      expect(binding.modelId, 'gpt-5');
    });
  });

  // gh-1624 REG matrix: the vendor-prefix dialect verdict is scoped to
  // KNOWN catalog endpoints (mirroring _validateWireEndpoint's "unknown
  // endpoints pass" rule). Translating proxies (bifrost/LiteLLM/one-api)
  // serve multiple dialect paths and route "vendor/model" prefixes as
  // keys — a prefix mismatch on such an endpoint is a WARNING, never the
  // exit 64 the 1.0.576 preflight produced. This group runs on every PR
  // touching provider_model_binding.dart.
  group('ProviderModelBinding.resolve — vendor-prefix endpoint scoping '
      '(gh-1624 REG, AC1/AC2/AC3)', () {
    test('AC1: vendor-prefixed model of another dialect on an UNKNOWN '
        'endpoint boots with a warning (was exit 64)', () {
      // The exact factory binding from gh-1624: zai/glm-5.3 through
      // bifrost's anthropic path — the prefix is a routing key there.
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'zai/glm-5.3',
        baseUrl: 'http://192.168.1.23:8080/anthropic',
        provenance: BindingProvenance.env,
      );
      expect(binding.providerKind, 'anthropic');
      expect(binding.baseUrl, 'http://192.168.1.23:8080/anthropic');
      expect(binding.warnings, hasLength(1));
      expect(
        binding.warnings.single,
        allOf(
          contains('zai/glm-5.3'),
          contains('"zai"'),
          contains('openai-completions'),
          contains('"anthropic-messages"'),
          contains('http://192.168.1.23:8080/anthropic'),
          contains('routing key'),
        ),
      );
    });

    test('AC2: the same mismatch on a KNOWN vendor endpoint is still '
        'fatal (gh-1570 fail-fast preserved)', () {
      // openai-prefixed id on the anthropic record's own endpoint: the
      // catalog verdict stands, the boot dies naming both sides.
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'openai/gpt-4o',
          provenance: BindingProvenance.env,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('openai/gpt-4o'),
              contains('"openai"'),
              contains('api.anthropic.com'),
            ),
          ),
        ),
      );
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'zai/glm-5.3',
          baseUrl: 'https://api.anthropic.com',
          provenance: BindingProvenance.env,
        ),
        throwsA(isA<ConfigException>()),
      );
    });

    test('AC2: an anthropic-wire binding on a known OPENAI endpoint with '
        'a claude id stays rejected (family-exclusive verdict intact)',
        () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'claude-sonnet-4-5',
          baseUrl: 'https://api.openai.com/v1',
          provenance: BindingProvenance.env,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('api.openai.com'), contains('anthropic')),
          ),
        ),
      );
    });

    test('AC3: wire: override (declaredWire != record kind) skips both '
        'checks — even where they would fire — and yields no warning',
        () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'zai/glm-5.3',
        baseUrl: 'https://api.anthropic.com',
        wire: 'openai-completions',
        provenance: BindingProvenance.env,
      );
      expect(binding.providerKind, 'openai-completions');
      expect(binding.wireOverride, isTrue);
      expect(binding.warnings, isEmpty);
    });

    test('AC3 caveat: wire: EQUAL to the record kind does NOT engage the '
        'override — the checks still run', () {
      // The undocumented footgun from gh-1624: record anthropic +
      // `wire: anthropic` changes nothing — the vendor-prefix verdict on
      // the known endpoint still fires, and a passing binding carries no
      // override marker.
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'anthropic',
          modelId: 'openai/gpt-4o',
          baseUrl: 'https://api.anthropic.com',
          wire: 'anthropic',
          provenance: BindingProvenance.env,
        ),
        throwsA(isA<ConfigException>()),
      );
      final binding = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'claude-sonnet-4-5',
        baseUrl: 'https://api.anthropic.com',
        wire: 'anthropic',
        provenance: BindingProvenance.env,
      );
      expect(binding.wireOverride, isFalse);
      expect(binding.warnings, isEmpty);
    });

    test('warnings are report notes, not identity (I5 round-trip)', () {
      final plain = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'zai/glm-5.3',
        baseUrl: 'http://192.168.1.23:8080/anthropic',
        provenance: BindingProvenance.env,
      );
      final same = ProviderModelBinding.resolve(
        providerKind: 'anthropic',
        modelId: 'zai/glm-5.3',
        baseUrl: 'http://192.168.1.23:8080/anthropic',
        provenance: BindingProvenance.restore,
      );
      expect(plain, equals(same));
      expect(plain.hashCode, same.hashCode);
    });
  });
  group('ProviderModelBinding.resolve — endpoint-shared wires (M5)', () {
    test('openai-completions without baseUrl or record is rejected', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'openai-completions',
          modelId: 'glm-4.6',
          provenance: BindingProvenance.queue,
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('openai-completions'), contains('baseUrl')),
          ),
        ),
      );
    });

    test('a custom baseUrl resolves to the openai record (legacy rule)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openai-completions',
        modelId: 'qwen3',
        baseUrl: 'http://localhost:8080/v1',
        provenance: BindingProvenance.queue,
      );
      expect(binding.providerKind, 'openai-completions');
      expect(binding.baseUrl, 'http://localhost:8080/v1');
    });

    test('baseUrl normalization strips one trailing slash (E1)', () {
      final a = ProviderModelBinding.resolve(
        providerKind: 'openai-completions',
        modelId: 'qwen3',
        baseUrl: 'http://localhost:8080/v1/',
        provenance: BindingProvenance.queue,
      );
      final b = ProviderModelBinding.resolve(
        providerKind: 'openai-completions',
        modelId: 'qwen3',
        baseUrl: 'http://localhost:8080/v1',
        provenance: BindingProvenance.queue,
      );
      expect(a, equals(b));
    });
  });

  group('ProviderModelBinding.resolve — id shape (E5) and key ref (S3)', () {
    for (final bad in <String>[
      '',
      '   ',
      'has space',
      'tab\tid',
      'http://evil.example/x',
      'id\ninjected',
      "quote'id",
      // C1 controls (U+0080–U+009F) are not letters — NEL/CSI must not
      // ride the `rune >= 0x80` non-ASCII pass (gh-1570 E5 review).
      'ctl\u0091x',
      'id\u0085next',
    ]) {
      test('rejects model id ${bad.isEmpty ? '(empty)' : '"$bad"'}', () {
        expect(
          () => ProviderModelBinding.resolve(
            providerKind: 'openrouter',
            modelId: bad,
            provenance: BindingProvenance.command,
          ),
          throwsA(isA<ConfigException>()),
        );
      });
    }

    test('accepts a lowercase env name — a legacy apiKeyEnvVar/apiKeyEnv '
        'keeps booting (gh-1570 key-ref review)', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'openai/gpt-4o-mini',
        keyEnvRef: 'my_key',
        provenance: BindingProvenance.env,
      );
      expect(binding.keyEnvRef, 'my_key');
    });

    test('key ref stays an env REFERENCE: whitespace and = are rejected '
        '(a value never enters a binding, S3)', () {
      for (final bad in const ['has space', 'KEY=value', 'tab\tref']) {
        expect(
          () => ProviderModelBinding.resolve(
            providerKind: 'openrouter',
            modelId: 'openai/gpt-4o-mini',
            keyEnvRef: bad,
            provenance: BindingProvenance.queue,
          ),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              allOf(contains(bad), isNot(contains('is not an environment'))),
            ),
          ),
          reason: 'key ref "$bad"',
        );
      }
    });

    test('accepts a well-formed id with dots, slashes, colons and plus', () {
      final binding = ProviderModelBinding.resolve(
        providerKind: 'openrouter',
        modelId: 'openai/gpt-4.1-mini',
        provenance: BindingProvenance.command,
      );
      expect(binding.modelId, 'openai/gpt-4.1-mini');
    });

    test('an unknown provider id is rejected (fail loud, not a guess)', () {
      expect(
        () => ProviderModelBinding.resolve(
          providerKind: 'from-the-future',
          modelId: 'x',
          provenance: BindingProvenance.restore,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
