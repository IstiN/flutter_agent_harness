// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  test('hubUrlWithBrowserBearer adds an url-encoded token and keeps query', () {
    final url = Uri.parse('wss://hub.fa1.dev/ws?channel=abc');
    final authed = hubUrlWithBrowserBearer(url, 's e/c+r&et');
    expect(authed.queryParameters['channel'], 'abc');
    expect(authed.queryParameters['token'], 's e/c+r&et');
    expect(authed.scheme, 'wss');
    expect(authed.path, '/ws');
    // The raw query must be encoded (a naive concat would inject params).
    expect(authed.query, contains('token='));
    expect(authed.query, isNot(contains('&et')));
    expect(authed.queryParameters['dap_token'], isNull);
  });

  test('hub identity key-file codec round-trips the same address', () async {
    final identity = await HubIdentity.generate();
    final encoded = await hubIdentityToKeyFile(identity);
    final restored = await hubIdentityFromKeyFile(encoded);
    expect(restored.agentId, identity.agentId);
    expect(
      await restored.dhKeyPair.extractPrivateKeyBytes(),
      await identity.dhKeyPair.extractPrivateKeyBytes(),
    );
  });

  test('hub identity key-file codec rejects garbage', () async {
    await expectLater(
      hubIdentityFromKeyFile('not a key file'),
      throwsA(anything),
    );
  });
}
