// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Redaction registration for the DAP env secret contract (issue #1825
/// AC8/AC14): `DAP_CHANNELS_JSON` carries PLAINTEXT channel private keys,
/// `DAP_CLIENT_SECRET` / `DAP_KEY_PASSPHRASE` are hub credentials — and
/// all of them live in the real process environment, so EVERY bash child
/// inherits them. One `env` / `printenv` tool call would otherwise put
/// plaintext key material into the tool result → the session JSONL and
/// the model context, unmasked. The entropy layers are not a substitute
/// (base64 with standard-alphabet `/` splits into tokens below the
/// entropy gate; human-memorable passphrases fail Shannon heuristics).
///
/// Every value registered here feeds BOTH masking systems — the legacy
/// exact-value [SecretRedactor] (tool-result/context hooks) and the
/// layered [RedactionPipeline] (issue #24) — the same dual registration
/// `buildSecretRedactor` performs for API keys.
library;

import '../redact/redaction_pipeline.dart';
import '../secrets/secret_redactor.dart';

/// Env names of the DAP contract whose VALUES are secrets.
const dapSecretEnvNames = [
  'DAP_CHANNELS_JSON',
  'DAP_CLIENT_SECRET',
  'DAP_KEY_PASSPHRASE',
];

/// Registers every DAP env secret present in [env] (absent/empty names
/// are skipped) with [redactor] and/or [redactionPipeline]. Each value
/// rides under its own env NAME in the legacy redactor (the map is
/// name-keyed — one shared name would overwrite all but the last value).
void registerDapEnvSecrets(
  Map<String, String> env, {
  SecretRedactor? redactor,
  RedactionPipeline? redactionPipeline,
}) {
  for (final name in dapSecretEnvNames) {
    final value = env[name];
    if (value == null || value.isEmpty) continue;
    redactor?.register(name, value);
    redactionPipeline?.registerSecret(value);
  }
}

var dapSecretSeq = 0;

/// Registers one runtime-resolved DAP secret (a decrypted channel
/// private key, a hub client secret, an auto-provisioned passphrase)
/// with [redactor] and/or [pipeline]. Values shorter than
/// [SecretRedactor.minValueLength] are ignored by both systems by
/// design (the false-positive guard), like any other registered secret.
void registerDapSecret(
  String value, {
  SecretRedactor? redactor,
  RedactionPipeline? pipeline,
}) {
  if (value.isEmpty) return;
  // The legacy redactor's map is name-keyed: every runtime secret gets
  // its own slot or the last one would overwrite the earlier ones.
  redactor?.register('dap-runtime-${dapSecretSeq++}', value);
  pipeline?.registerSecret(value);
}
