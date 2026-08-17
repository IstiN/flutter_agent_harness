// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  const envNames = ['OPENROUTER_API_KEY'];
  const defaultUrl = 'https://openrouter.ai/api/v1';

  String? Function(String) envOf(Map<String, String> env) =>
      (name) => env[name];
  String? Function(String) storeOf(Map<String, String> store) =>
      (name) => store[name];

  group('resolveEndpointKey (the CLI/app shared chain)', () {
    test('a genuine environment value wins over the store', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-stored'}),
      );
      expect(key, 'sk-env');
    });

    test('an env-looking value that merely mirrors the store does not count '
        'as a genuine environment value', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-same'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-same'}),
      );
      expect(key, 'sk-same'); // via the legacy env-name store entry
    });

    test('the host-scoped FA_KEY_<HOST> entry beats the legacy env-name '
        'store entry', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf(const {}),
        storeRead: storeOf({
          'OPENROUTER_API_KEY': 'sk-legacy',
          'FA_KEY_OPENROUTER_AI': 'sk-scoped',
        }),
      );
      expect(key, 'sk-scoped');
    });

    test('custom endpoints resolve ONLY scoped store keys — catalog env '
        'names never hijack another endpoint', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: storeOf({'OPENROUTER_API_KEY': 'sk-stored'}),
      );
      expect(key, isNull);
    });

    test('a custom endpoint resolves its host-scoped store key', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf({'FA_KEY_API_ACME_EXAMPLE': 'sk-acme'}),
      );
      expect(key, 'sk-acme');
    });

    test('the active custom entry key name wins over the host-scoped one', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: 'https://api.acme.example/v1',
        envRead: envOf(const {}),
        storeRead: storeOf({
          'FA_KEY_API_ACME_EXAMPLE': 'sk-host',
          'FA_KEY_API_ACME_EXAMPLE_WORK': 'sk-named',
        }),
        activeCustomKeyName: 'FA_KEY_API_ACME_EXAMPLE_WORK',
      );
      expect(key, 'sk-named');
    });

    test('a null store resolves env-only (web/tests)', () {
      final key = resolveEndpointKey(
        envNames: envNames,
        defaultBaseUrl: defaultUrl,
        baseUrl: defaultUrl,
        envRead: envOf({'OPENROUTER_API_KEY': 'sk-env'}),
        storeRead: null,
      );
      expect(key, 'sk-env');
    });
  });
}
