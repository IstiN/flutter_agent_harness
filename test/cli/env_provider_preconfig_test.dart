// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The `FA_PROVIDER_*` env preconfig parser. Env values arrive via an
/// injected reader, so every case wires a map-backed closure; no
/// `dart:io` is involved on either side.
///
/// The declaration is machine-written and self-contained: `baseUrl` and
/// `model` are required, `apiKeyEnvVar` is optional-but-strict (declared →
/// the named var MUST resolve; absent → keyless, no env-name probing),
/// every text input has a `_BASE64` twin, and nothing falls back to the
/// catalog spec values.
void main() {
  String? Function(String) envFrom(Map<String, String> vars) =>
      (name) => vars[name];

  String b64(String value) => base64.encode(utf8.encode(value));

  EnvProviderPreconfig? parse({
    String? providerType,
    String? providerName,
    String? providerConfig,
    String? providerConfigBase64,
    Map<String, String> vars = const {},
    Iterable<String> takenNames = const [],
  }) => parseEnvProviderPreconfig(
    providerType: providerType,
    providerName: providerName,
    providerConfig: providerConfig,
    providerConfigBase64: providerConfigBase64,
    envVarValue: envFrom(vars),
    takenNames: takenNames,
  );

  /// A minimal declaration for [type] (required keys only).
  String config(String type) => switch (type) {
    'zai' =>
      '{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"glm-5.3"}',
    _ => '{"baseUrl":"https://relay.internal/v1","model":"test-model"}',
  };

  final throwsConfig = isA<ConfigException>();

  group('feature off', () {
    test('null / blank type returns null', () {
      expect(parse(), isNull);
      expect(parse(providerType: ''), isNull);
      expect(parse(providerType: '   '), isNull);
    });
  });

  group('required fields', () {
    test('a missing config with a set type is an error', () {
      expect(
        () => parse(providerType: 'zai'),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            contains('FA_PROVIDER_CONFIG'),
          ),
        ),
      );
    });

    test('an empty config with a set type is an error', () {
      expect(
        () => parse(providerType: 'zai', providerConfig: '  '),
        throwsA(throwsConfig),
      );
    });

    test('a missing baseUrl is named, not defaulted', () {
      expect(
        () => parse(providerType: 'zai', providerConfig: '{"model":"glm-5.3"}'),
        throwsA(
          throwsConfig.having((e) => e.message, 'message', contains('baseUrl')),
        ),
      );
    });

    test('a missing model is named, not defaulted', () {
      expect(
        () => parse(
          providerType: 'zai',
          providerConfig: '{"baseUrl":"https://api.z.ai/api/coding/paas/v4"}',
        ),
        throwsA(
          throwsConfig.having((e) => e.message, 'message', contains('model')),
        ),
      );
    });
  });

  group('apiKeyEnvVar: optional but strict', () {
    test('a declared, set key ref is applied', () {
      final pre = parse(
        providerType: 'zai',
        providerConfig:
            '{"baseUrl":"https://relay.internal/v1","model":"glm-5.3",'
            '"apiKeyEnvVar":"ZAI_API_KEY"}',
        vars: {'ZAI_API_KEY': 'zk'},
      )!;
      expect(pre.apiKeyEnvVar, 'ZAI_API_KEY');
      expect(pre.apiKey, 'zk');
    });

    test('a declared but missing key ref fails loud, naming the var', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig:
              '{"baseUrl":"https://api.minimax.io/v1","model":"MiniMax-M3",'
              '"apiKeyEnvVar":"MISSING_KEY_VAR"}',
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            contains('MISSING_KEY_VAR'),
          ),
        ),
      );
    });

    test('a declared but empty key ref fails loud too', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig:
              '{"baseUrl":"https://api.minimax.io/v1","model":"MiniMax-M3",'
              '"apiKeyEnvVar":"EMPTY_KEY_VAR"}',
          vars: {'EMPTY_KEY_VAR': ''},
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            contains('EMPTY_KEY_VAR'),
          ),
        ),
      );
    });

    test('no key ref boots keyless — spec env names are NOT probed', () {
      // MINIMAX_API_KEY is in the environment, but the declaration does
      // not name it: absent means absent, the boot stays keyless instead
      // of silently picking up whatever key happened to be around.
      final pre = parse(
        providerType: 'minimax',
        providerConfig: config('minimax'),
        vars: {'MINIMAX_API_KEY': 'mm-key'},
      )!;
      expect(pre.apiKeyEnvVar, isNull);
      expect(pre.apiKey, '');
    });
  });

  group('apiKeyEnvVar genericity: any catalog type', () {
    test('anthropic boots end-to-end from env with a custom key var', () {
      final pre = parse(
        providerType: 'anthropic',
        providerConfig:
            '{"baseUrl":"https://api.anthropic.com","model":"claude-sonnet-4-5",'
            '"apiKeyEnvVar":"MY_ANTHROPIC_KEY"}',
        vars: {'MY_ANTHROPIC_KEY': 'sk-ant'},
      )!;
      expect(pre.spec.name, 'anthropic');
      expect(pre.baseUrl, 'https://api.anthropic.com');
      expect(pre.modelId, 'claude-sonnet-4-5');
      expect(pre.apiKeyEnvVar, 'MY_ANTHROPIC_KEY');
      expect(pre.apiKey, 'sk-ant');
    });

    test('openai boots end-to-end from env the same way', () {
      final pre = parse(
        providerType: 'openai',
        providerConfig:
            '{"baseUrl":"https://api.openai.com/v1","model":"gpt-5.2",'
            '"apiKeyEnvVar":"MY_OPENAI_KEY"}',
        vars: {'MY_OPENAI_KEY': 'sk-oai'},
      )!;
      expect(pre.spec.name, 'openai');
      expect(pre.apiKey, 'sk-oai');
    });
  });

  group('base64 twins: config blob', () {
    test('the _BASE64 twin is used when the plain var is unset', () {
      final pre = parse(
        providerType: 'zai',
        providerConfigBase64: b64(config('zai')),
      )!;
      expect(pre.baseUrl, 'https://api.z.ai/api/coding/paas/v4');
      expect(pre.modelId, 'glm-5.3');
    });

    test('the plain var wins when both carry the same value', () {
      final pre = parse(
        providerType: 'zai',
        providerConfig: config('zai'),
        providerConfigBase64: b64(config('zai')),
      )!;
      expect(pre.modelId, 'glm-5.3');
    });

    test('both set with different values is ambiguous — error', () {
      expect(
        () => parse(
          providerType: 'zai',
          providerConfig: config('zai'),
          providerConfigBase64: b64(config('minimax')),
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            allOf(contains('ambiguous'), contains('FA_PROVIDER_CONFIG')),
          ),
        ),
      );
    });

    test('malformed base64 is an error naming the twin var', () {
      expect(
        () => parse(providerType: 'zai', providerConfigBase64: 'not-base64!!!'),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            allOf(contains('FA_PROVIDER_CONFIG_BASE64'), contains('base64')),
          ),
        ),
      );
    });
  });

  group('base64 twins: key var', () {
    final zaiWithKeyRef =
        '{"baseUrl":"https://api.z.ai/api/coding/paas/v4","model":"glm-5.3",'
        '"apiKeyEnvVar":"ZAI_API_KEY"}';

    test('the _BASE64 twin is used when the plain var is unset', () {
      final pre = parse(
        providerType: 'zai',
        providerConfig: zaiWithKeyRef,
        vars: {'ZAI_API_KEY_BASE64': b64('sk-zai')},
      )!;
      expect(pre.apiKey, 'sk-zai');
    });

    test('the plain var wins when both carry the same value', () {
      final pre = parse(
        providerType: 'zai',
        providerConfig: zaiWithKeyRef,
        vars: {'ZAI_API_KEY': 'sk-zai', 'ZAI_API_KEY_BASE64': b64('sk-zai')},
      )!;
      expect(pre.apiKey, 'sk-zai');
    });

    test('both set with different values is ambiguous — error', () {
      expect(
        () => parse(
          providerType: 'zai',
          providerConfig: zaiWithKeyRef,
          vars: {
            'ZAI_API_KEY': 'sk-plain',
            'ZAI_API_KEY_BASE64': b64('sk-twin'),
          },
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            allOf(contains('ambiguous'), contains('ZAI_API_KEY_BASE64')),
          ),
        ),
      );
    });

    test('malformed base64 is an error naming the twin var', () {
      expect(
        () => parse(
          providerType: 'zai',
          providerConfig: zaiWithKeyRef,
          vars: {'ZAI_API_KEY_BASE64': '@@not base64@@'},
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            contains('ZAI_API_KEY_BASE64'),
          ),
        ),
      );
    });
  });

  group('no-fallback regressions (catalog values never fill gaps)', () {
    test(
      'a catalog-backed type with no baseUrl throws instead of guessing',
      () {
        // zai HAS a spec default endpoint; the preconfig must not use it.
        expect(
          () => parse(providerType: 'zai', providerConfig: '{"model":"x"}'),
          throwsA(
            throwsConfig.having(
              (e) => e.message,
              'message',
              contains('baseUrl'),
            ),
          ),
        );
      },
    );

    test('a catalog-backed type with no model throws instead of guessing', () {
      // glm-5.3 is the catalog default; the preconfig must not pick it.
      expect(
        () => parse(
          providerType: 'zai',
          providerConfig: '{"baseUrl":"https://api.z.ai/api/coding/paas/v4"}',
        ),
        throwsA(
          throwsConfig.having((e) => e.message, 'message', contains('model')),
        ),
      );
    });
  });

  group('config strictness', () {
    test('unknown key names the key and the supported set', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig: '{"foo":"bar","baseUrl":"https://x","model":"m"}',
        ),
        throwsA(
          throwsConfig.having(
            (e) => e.message,
            'message',
            allOf(contains('foo'), contains('apiKeyEnvVar')),
          ),
        ),
      );
    });

    test('non-string value is rejected', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig: '{"baseUrl":"https://x","model":42}',
        ),
        throwsA(throwsConfig),
      );
    });

    test('malformed JSON quotes the problem', () {
      expect(
        () => parse(providerType: 'minimax', providerConfig: '{oops'),
        throwsA(
          throwsConfig.having(
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
          throwsConfig.having(
            (e) => e.message,
            'message',
            contains('must be a JSON object'),
          ),
        ),
      );
    });

    test('blank required values are treated as absent — error', () {
      expect(
        () => parse(
          providerType: 'minimax',
          providerConfig: '{"baseUrl":"https://x","model":"  "}',
        ),
        throwsA(
          throwsConfig.having((e) => e.message, 'message', contains('model')),
        ),
      );
    });
  });

  group('name auto-resolve', () {
    test('taken default name gets -2, then -3', () {
      expect(
        parse(
          providerType: 'minimax',
          providerConfig: config('minimax'),
          takenNames: ['minimax'],
        )!.name,
        'minimax-2',
      );
      expect(
        parse(
          providerType: 'minimax',
          providerConfig: config('minimax'),
          takenNames: ['minimax', 'minimax-2'],
        )!.name,
        'minimax-3',
      );
    });

    test('a non-colliding explicit name is kept verbatim', () {
      expect(
        parse(
          providerType: 'minimax',
          providerConfig: config('minimax'),
          providerName: 'my-relay',
        )!.name,
        'my-relay',
      );
    });

    test('an explicit name colliding with a saved entry gets -2', () {
      expect(
        parse(
          providerType: 'anthropic',
          providerConfig: config('anthropic'),
          providerName: 'my-relay',
          takenNames: ['my-relay'],
        )!.name,
        'my-relay-2',
      );
    });

    test('a name colliding with a catalog provider gets -2', () {
      expect(
        parse(
          providerType: 'minimax',
          providerConfig: config('minimax'),
          providerName: 'anthropic',
        )!.name,
        'anthropic-2',
      );
    });
  });

  group('FA_PROVIDERS filter interplay', () {
    tearDown(() => providerFilterEnvOverride = null);

    test('a filtered-out type no longer resolves', () {
      providerFilterEnvOverride = 'minimax';
      expect(
        () => parse(
          providerType: 'anthropic',
          providerConfig: config('anthropic'),
        ),
        throwsA(throwsConfig),
      );
      expect(
        parse(providerType: 'minimax', providerConfig: config('minimax')),
        isNotNull,
      );
    });

    test('uniquify still avoids names filtered out of resolution', () {
      providerFilterEnvOverride = 'minimax';
      expect(
        parse(
          providerType: 'minimax',
          providerConfig: config('minimax'),
          providerName: 'dial',
        )!.name,
        'dial-2',
      );
    });
  });
}
