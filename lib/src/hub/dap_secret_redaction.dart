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

import 'dart:convert';

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
  // The whole JSON value is not enough: `env | jq` or a tool that decodes
  // the provisioning payload can print one private key on its own. Mask
  // every entry's priv synchronously at startup, before runtime joins (or
  // any tool call) can happen. Invalid JSON is already handled loudly by
  // parseDapEnvChannels; redaction registration stays best-effort.
  final rawChannels = env['DAP_CHANNELS_JSON'];
  if (rawChannels == null || rawChannels.isEmpty) return;
  try {
    final decoded = jsonDecode(rawChannels);
    if (decoded is! List) return;
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final priv = entry['priv'];
      if (priv is! String || priv.isEmpty) continue;
      registerDapSecret(priv, redactor: redactor, pipeline: redactionPipeline);
    }
  } on Object {
    // The complete raw value registered above is still masked; the parser
    // owns the user-facing malformed-env warning.
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
