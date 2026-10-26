// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// AC8/AC14 byte-scan coverage for the DAP env secret contract
/// (gh-1888 review): the env values (plaintext channel privs, hub
/// credentials, the key passphrase) and every runtime-resolved secret
/// MUST be registered with both masking systems, so they can never
/// appear in a tool result / session JSONL / provider context.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/startup.dart'
    show buildRedactionPipeline;
import 'package:flutter_agent_harness/src/hub/dap_secret_redaction.dart';
import 'package:test/test.dart';

void main() {
  const channelsJson =
      '[{"channel":"team","pub":"PB","priv":"PLAINTEXT_CHANNEL_PRIV"}]';
  const clientSecret = 'hub-client-secret-value-0123456789abcdef';
  const passphrase = 'human-memorable-passphrase-phrase';

  final env = <String, String>{
    'DAP_CHANNELS_JSON': channelsJson,
    'DAP_CLIENT_SECRET': clientSecret,
    'DAP_KEY_PASSPHRASE': passphrase,
    'DAP_HUB_URL': 'wss://hub.fa1.dev/ws', // NOT a secret — must not register
  };

  /// The simulated tool-result / session-JSONL bytes an `env` call would
  /// produce when the DAP contract is exported.
  String envDump(Map<String, String> environment) =>
      environment.entries.map((e) => '${e.key}=${e.value}').join('\n');

  test('every DAP env secret is registered with the legacy redactor — '
      'an env dump masks all of them (AC8 byte-scan)', () {
    final redactor = SecretRedactor();
    registerDapEnvSecrets(env, redactor: redactor);

    // Registration really happened for all three values (each rides
    // under its own env name).
    expect(
      redactor.names,
      containsAll([
        'DAP_CHANNELS_JSON',
        'DAP_CLIENT_SECRET',
        'DAP_KEY_PASSPHRASE',
      ]),
    );

    final redacted = redactor.redact(envDump(env));
    expect(redacted, isNot(contains(channelsJson)));
    expect(redacted, isNot(contains(clientSecret)));
    expect(redacted, isNot(contains(passphrase)));
    expect(redacted, contains('DAP_HUB_URL=wss://hub.fa1.dev/ws'));
    expect(redacted.split('***').length - 1, greaterThanOrEqualTo(3));
  });

  test('the layered pipeline receives the same values (issue #24 parity)', () {
    final pipeline = buildRedactionPipeline(null);
    registerDapEnvSecrets(env, redactionPipeline: pipeline);

    for (final value in [channelsJson, clientSecret, passphrase]) {
      expect(pipeline!.registeredSecrets, contains(value));
    }
    expect(pipeline!.registeredSecrets, isNot(contains('wss://hub.fa1.dev')));
  });

  test('runtime-resolved secrets (decrypted privs, auto-provisioned '
      'passphrases, memory-only hub credentials) register too', () {
    final redactor = SecretRedactor();
    final pipeline = buildRedactionPipeline(null);
    const decryptedPriv = 'decrypted-channel-private-key';
    const autoPassphrase = 'auto-provisioned-passphrase';

    registerDapSecret(decryptedPriv, redactor: redactor);
    registerDapSecret(autoPassphrase, redactor: redactor, pipeline: pipeline);

    final transcript =
        'channel key material: $decryptedPriv\npassphrase: $autoPassphrase';
    final redacted = redactor.redact(transcript);
    expect(redacted, isNot(contains(decryptedPriv)));
    expect(redacted, isNot(contains(autoPassphrase)));
    expect(pipeline!.registeredSecrets, contains(autoPassphrase));
  });

  test('absent/empty env names are skipped; short values are ignored by '
      'BOTH systems (the shared false-positive guard)', () {
    final redactor = SecretRedactor();
    final pipeline = buildRedactionPipeline(null);
    registerDapEnvSecrets(const {'DAP_CLIENT_SECRET': ''}, redactor: redactor);
    expect(redactor.isEmpty, isTrue);

    registerDapSecret('tiny', redactor: redactor, pipeline: pipeline);
    expect(redactor.isEmpty, isTrue, reason: 'below minValueLength');
    expect(pipeline!.registeredSecrets, isNot(contains('tiny')));
  });
}
