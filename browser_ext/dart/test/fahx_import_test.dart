// .fahx decrypt port tests (issue #34 item 3): the roundtrip runs against
// the CLI's OWN encrypt implementation (lib/src/cli/provider_export.dart —
// the root package is a path dep of browser_ext/dart), pinning bit-level
// compatibility of the PBKDF2 + HMAC-CTR envelope across both sides.
//
// Wrong passphrase and a tampered file must fail LOUDLY (FahxException)
// with nothing written — the import function is pure, so "nothing written"
// is enforced by the caller and asserted here as exception-only failure.
library;

import 'dart:convert';

import '../src/fahx_import.dart';
import 'package:flutter_agent_harness/src/cli/provider_export.dart';
import 'package:test/test.dart';

String envelopeJson(Map<String, dynamic> envelope) => jsonEncode(envelope);

Map<String, dynamic> payloadFor(List<Map<String, String>> providers) => {
  'version': fahxVersion,
  'providers': providers,
};

void main() {
  final entries = [
    {
      'name': 'openrouter',
      'apiType': 'openai',
      'baseUrl': 'https://openrouter.ai/api/v1',
      'modelId': 'anthropic/claude',
      'keyName': 'OPENROUTER_KEY',
      'key': 'sk-or-test',
    },
    {
      'name': 'local-llama',
      'apiType': 'openai',
      'baseUrl': 'http://127.0.0.1:8080/v1',
      'modelId': 'llama3',
    },
  ];

  test('roundtrip: a CLI-exported .fahx decrypts into registry entries', () {
    final envelope = encryptProvidersExport(
      jsonEncode(payloadFor(entries)),
      'correct horse battery',
    );
    final imported = importFahxProviders(
      envelopeJson(envelope),
      'correct horse battery',
    );
    expect(imported, hasLength(2));
    expect(imported.first.name, 'openrouter');
    expect(imported.first.baseUrl, 'https://openrouter.ai/api/v1');
    expect(imported.first.modelId, 'anthropic/claude');
    expect(imported.first.key, 'sk-or-test');
    expect(imported.last.name, 'local-llama');
    expect(imported.last.key, isNull, reason: 'keyless entries stay keyless');
  });

  test('wrong passphrase fails loudly', () {
    final envelope = encryptProvidersExport(
      jsonEncode(payloadFor(entries)),
      'right',
    );
    expect(
      () => importFahxProviders(envelopeJson(envelope), 'wrong'),
      throwsA(isA<FahxException>()),
    );
  });

  test('tampered ciphertext fails loudly (tag verification)', () {
    final envelope = encryptProvidersExport(
      jsonEncode(payloadFor(entries)),
      'pass',
    );
    final ct = envelope['ct'] as String;
    final bytes = base64Decode(ct);
    bytes[0] ^= 0xFF; // flip one bit
    envelope['ct'] = base64Encode(bytes);
    expect(
      () => importFahxProviders(envelopeJson(envelope), 'pass'),
      throwsA(isA<FahxException>()),
    );
  });

  test('unsupported version and malformed files fail loudly', () {
    expect(
      () => importFahxProviders('{"version":99}', 'p'),
      throwsA(isA<FahxException>()),
    );
    expect(
      () => importFahxProviders('not json at all', 'p'),
      throwsA(isA<FahxException>()),
    );
  });
}
