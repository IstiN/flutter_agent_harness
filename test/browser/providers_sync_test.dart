// Providers sync payload (issue #34 item 3): pure encode/decode,
// provenance markers, key-mode separation, and total decoding on shapes
// it cannot trust.
@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  final entries = [
    CustomProviderEntry(
      name: 'zai',
      apiType: 'openai',
      baseUrl: 'https://api.z.ai/api/paas/v4',
      modelId: 'glm-4.6',
      keyName: 'FA_KEY_API_Z_AI',
    ),
    CustomProviderEntry(
      name: 'openrouter',
      apiType: 'openai',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'anthropic/claude-sonnet-4',
    ),
  ];
  group('buildProvidersSync', () {
    test('proxy mode carries metadata only — never a key', () {
      final payload = buildProvidersSync(
        entries,
        mode: ProvidersSyncMode.proxy,
        hostname: 'macbook',
        keys: {'zai': 'sk-secret'},
      );
      expect(payload.mode, ProvidersSyncMode.proxy);
      expect(payload.host, 'macbook');
      expect(payload.keys, isEmpty);
      expect(payload.providers, hasLength(2));
      // Provenance: every entry carries synced-from-cli@<host>.
      for (final provider in payload.providers) {
        expect(provider.provenance, 'synced-from-cli@macbook');
      }
      expect(payload.providers.first.name, 'zai');
      expect(payload.providers.first.apiType, 'openai');
      expect(payload.providers.first.baseUrl, 'https://api.z.ai/api/paas/v4');
      expect(payload.providers.first.modelId, 'glm-4.6');
      // Key bytes stay out of the serialized metadata entirely.
      final json = jsonEncode(payload.toJson());
      expect(json, isNot(contains('sk-secret')));
      expect(json, isNot(contains('FA_KEY_API_Z_AI')));
    });

    test('copy mode puts keys ONLY in the dedicated keys field', () {
      final payload = buildProvidersSync(
        entries,
        mode: ProvidersSyncMode.copy,
        hostname: 'macbook',
        keys: {'zai': 'sk-secret'},
      );
      expect(payload.mode, ProvidersSyncMode.copy);
      expect(payload.keys, {'zai': 'sk-secret'});
      final json = payload.toJson();
      final keysField = json['keys'] as Map<String, dynamic>;
      expect(keysField, {'zai': 'sk-secret'});
      // The per-provider metadata never carries a key.
      for (final provider in json['providers'] as List) {
        expect((provider as Map).containsKey('key'), isFalse);
      }
    });

    test('an entry without a resolved key still syncs (metadata is safe)', () {
      final payload = buildProvidersSync(
        entries,
        mode: ProvidersSyncMode.copy,
        hostname: 'h',
        keys: const {},
      );
      expect(payload.providers, hasLength(2));
      expect(payload.keys, isEmpty);
      // No keys field at all when nothing resolved.
      expect(payload.toJson().containsKey('keys'), isFalse);
    });
  });

  group('ProvidersSyncPayload.fromJson', () {
    test('round-trips through jsonEncode/jsonDecode', () {
      final payload = buildProvidersSync(
        entries,
        mode: ProvidersSyncMode.copy,
        hostname: 'macbook',
        keys: {'zai': 'sk-secret'},
      );
      final decoded = ProvidersSyncPayload.fromJson(
        jsonDecode(jsonEncode(payload.toJson())),
      );
      expect(decoded, isNotNull);
      expect(decoded!.mode, ProvidersSyncMode.copy);
      expect(decoded.host, 'macbook');
      expect(decoded.keys, {'zai': 'sk-secret'});
      expect(decoded.providers, hasLength(2));
      expect(decoded.providers.last.modelId, 'anthropic/claude-sonnet-4');
    });

    test('proxy mode drops any keys the sender illegally inlined', () {
      final decoded = ProvidersSyncPayload.fromJson({
        'version': 1,
        'mode': 'proxy',
        'host': 'h',
        'providers': [],
        'keys': {'x': 'sk-leak'},
      });
      expect(decoded!.keys, isEmpty);
    });

    for (final (name, json) in [
      ('not an object', 'nope'),
      (
        'a wrong version',
        {'version': 2, 'mode': 'proxy', 'host': 'h', 'providers': []},
      ),
      (
        'an unknown mode',
        {'version': 1, 'mode': 'teleport', 'host': 'h', 'providers': []},
      ),
      (
        'an empty host',
        {'version': 1, 'mode': 'proxy', 'host': '', 'providers': []},
      ),
      (
        'a non-list providers field',
        {'version': 1, 'mode': 'proxy', 'host': 'h', 'providers': 'nope'},
      ),
      (
        'a provider without a name',
        {
          'version': 1,
          'mode': 'proxy',
          'host': 'h',
          'providers': [
            {'baseUrl': 'https://x.test'},
          ],
        },
      ),
    ]) {
      test('rejects $name with null (never a throw)', () {
        expect(ProvidersSyncPayload.fromJson(json), isNull);
      });
    }

    test('ignores unknown fields from a newer peer (additive versioning)', () {
      final decoded = ProvidersSyncPayload.fromJson({
        'version': 1,
        'mode': 'proxy',
        'host': 'h',
        'providers': [
          {
            'name': 'p',
            'apiType': 'openai',
            'baseUrl': 'https://x.test',
            'modelId': 'm',
            'provenance': 'synced-from-cli@h',
            'futureField': {'nested': true},
          },
        ],
        'futureTopLevel': 42,
      });
      expect(decoded, isNotNull);
      expect(decoded!.providers.single.name, 'p');
    });
  });

  group('providersSyncProvenance', () {
    test('stamps the host', () {
      expect(providersSyncProvenance('macbook'), 'synced-from-cli@macbook');
    });
  });
}
