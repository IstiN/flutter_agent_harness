// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The `FA_PROVIDER_*` env preconfig parser. Env values arrive via an
/// injected reader, so every case wires a map-backed closure; no
/// `dart:io` is involved on either side.
void main() {
  String? Function(String) envFrom(Map<String, String> vars) =>
      (name) => vars[name];

  EnvProviderPreconfig? parse({
    String? providerType,
    String? providerName,
    String? providerConfig,
    Map<String, String> vars = const {},
    Iterable<String> takenNames = const [],
  }) => parseEnvProviderPreconfig(
    providerType: providerType,
    providerName: providerName,
    providerConfig: providerConfig,
    envVarValue: envFrom(vars),
    takenNames: takenNames,
  );

  group('feature off', () {
    test('null / blank type returns null', () {
      expect(parse(), isNull);
      expect(parse(providerType: ''), isNull);
      expect(parse(providerType: '   '), isNull);
    });
  });

  group('minimal resolution (type only)', () {
    test('minimax defaults to spec baseUrl, catalog model, spec env key', () {
      final pre = parse(
        providerType: 'minimax',
        vars: {'MINIMAX_API_KEY': 'mm-key'},
      )!;
      expect(pre.spec.name, 'minimax');
      expect(pre.name, 'minimax');
      expect(pre.baseUrl, 'https://api.minimax.io/v1');
      expect(pre.modelId, 'MiniMax-M3');
      expect(pre.apiKeyEnvVar, isNull);
      expect(pre.apiKey, 'mm-key');
    });

    test(
      'zai resolves case-insensitively and falls to the second env name',
      () {
        final pre = parse(providerType: ' ZAI ', vars: {'Z_AI_API_KEY': 'z2'})!;
        expect(pre.spec.name, 'zai');
        expect(pre.baseUrl, 'https://api.z.ai/api/coding/paas/v4');
        expect(pre.modelId, 'glm-5.3');
        expect(pre.apiKey, 'z2');
      },
    );

    test('no env key at all yields a keyless, still-valid preconfig', () {
      final pre = parse(providerType: 'anthropic')!;
      expect(pre.apiKey, '');
      expect(pre.apiKeyEnvVar, isNull);
    });
  });

  group('explicit FA_PROVIDER_CONFIG', () {
    test('baseUrl, model, and key ref are all applied', () {
      final pre = parse(
        providerType: 'zai',
        providerConfig:
            '{"baseUrl":"https://relay.internal/v1","model":"glm-5.3",'
            '"apiKeyEnvVar":"ZAI_API_KEY"}',
        vars: {'ZAI_API_KEY': 'zk'},
      )!;
      expect(pre.baseUrl, 'https://relay.internal/v1');
      expect(pre.modelId, 'glm-5.3');
      expect(pre.apiKeyEnvVar, 'ZAI_API_KEY');
      expect(pre.apiKey, 'zk');
    });

    test('a set-but-empty key ref fails loud, naming the var', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig: '{"apiKeyEnvVar":"MISSING_KEY_VAR"}',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('MISSING_KEY_VAR'),
          ),
        ),
      );
    });

    test('blank config values are treated as absent', () {
      final pre = parse(
        providerType: 'minimax',
        providerConfig: '{"model":"  ","baseUrl":""}',
      )!;
      expect(pre.modelId, 'MiniMax-M3');
      expect(pre.baseUrl, 'https://api.minimax.io/v1');
    });
  });

  group('config strictness', () {
    test('unknown key names the key and the supported set', () {
      expect(
        () => parse(providerType: 'minimax', providerConfig: '{"foo":"bar"}'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('foo'), contains('apiKeyEnvVar')),
          ),
        ),
      );
    });

    test('non-string value is rejected', () {
      expect(
        () => parse(providerType: 'minimax', providerConfig: '{"model":42}'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('malformed JSON quotes the problem', () {
      expect(
        () => parse(providerType: 'minimax', providerConfig: '{oops'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('not valid JSON'),
          ),
        ),
      );
    });

    test('non-object JSON is rejected', () {
      expect(
        () => parse(providerType: 'minimax', providerConfig: '["m"]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('must be a JSON object'),
          ),
        ),
      );
    });
  });

  group('name auto-resolve', () {
    test('taken default name gets -2, then -3', () {
      expect(
        parse(providerType: 'minimax', takenNames: ['minimax'])!.name,
        'minimax-2',
      );
      expect(
        parse(
          providerType: 'minimax',
          takenNames: ['minimax', 'minimax-2'],
        )!.name,
        'minimax-3',
      );
    });

    test('a non-colliding explicit name is kept verbatim', () {
      expect(
        parse(providerType: 'minimax', providerName: 'my-relay')!.name,
        'my-relay',
      );
    });

    test('an explicit name colliding with a saved entry gets -2', () {
      expect(
        parse(
          providerType: 'anthropic',
          providerName: 'my-relay',
          takenNames: ['my-relay'],
        )!.name,
        'my-relay-2',
      );
    });

    test('a name colliding with a catalog provider gets -2', () {
      expect(
        parse(providerType: 'minimax', providerName: 'anthropic')!.name,
        'anthropic-2',
      );
    });
  });

  group('model requirement', () {
    test('dial with no default and no config model demands one', () {
      expect(
        () => parse(providerType: 'dial'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('model'),
          ),
        ),
      );
    });

    test('dial with an explicit model boots', () {
      final pre = parse(
        providerType: 'dial',
        providerConfig: '{"model":"gpt-4o"}',
      )!;
      expect(pre.modelId, 'gpt-4o');
      expect(pre.baseUrl, 'https://ai-proxy.lab.epam.com');
    });

    test('unknown type lists the enabled providers', () {
      expect(
        () => parse(providerType: 'nope'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(contains('supported providers'), contains('anthropic')),
          ),
        ),
      );
    });
  });

  group('FA_PROVIDERS filter interplay', () {
    tearDown(() => providerFilterEnvOverride = null);

    test('a filtered-out type no longer resolves', () {
      providerFilterEnvOverride = 'minimax';
      expect(
        () => parse(providerType: 'anthropic'),
        throwsA(isA<ConfigException>()),
      );
      expect(parse(providerType: 'minimax'), isNotNull);
    });

    test('uniquify still avoids names filtered out of resolution', () {
      providerFilterEnvOverride = 'minimax';
      expect(
        parse(providerType: 'minimax', providerName: 'dial')!.name,
        'dial-2',
      );
    });
  });
}
