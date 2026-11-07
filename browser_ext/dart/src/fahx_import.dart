// `.fahx` import for the extension (issue #34 item 3, §S6 fallback tier):
// decrypts a passphrase-protected provider export written by the CLI's
// `fa config export-providers` and turns it into registry entries.
//
// The format codec (envelope decrypt, provider-entry parsing, and the
// crypto primitives) lives in the shared pure
// `package:flutter_agent_harness/src/providers/fahx_codec.dart` — this
// file used to carry a bit-compatible package:crypto port of it, but the
// extension already path-depends on the root package, so both sides now
// compile the one implementation (see that file's header for the format
// and the stateful-core rationale). The roundtrip against the CLI's own
// encrypt output is pinned in `test/fahx_import_test.dart`.
//
// Every failure (bad shape, unsupported version/kdf, wrong passphrase,
// tampered ciphertext) throws [FahxException] loudly; callers write
// nothing unless the whole decrypt succeeds.
library;

import 'dart:convert';

import 'package:flutter_agent_harness/src/providers/fahx_codec.dart'
    show
        FahxException,
        FahxProviderEntry,
        decryptFahxEnvelope,
        parseFahxProviderEntry;

export 'package:flutter_agent_harness/src/providers/fahx_codec.dart'
    show FahxException;

/// Envelope + payload version (matches the CLI exporter).
const int fahxVersion = 1;

/// One decrypted `.fahx` provider entry.
typedef FahxProvider = FahxProviderEntry;

/// Decodes + decrypts + verifies a `.fahx` file's contents into entries.
/// Pure: reads nothing, writes nothing.
List<FahxProvider> importFahxProviders(String contents, String passphrase) {
  final Object? envelope;
  try {
    envelope = jsonDecode(contents);
  } on FormatException {
    throw const FahxException('.fahx file is not valid JSON');
  }
  if (envelope is! Map<String, dynamic>) {
    throw const FahxException('.fahx file is not valid JSON');
  }
  final plaintext = decryptFahx(envelope, passphrase);
  final Object? payload;
  try {
    payload = jsonDecode(plaintext);
  } on FormatException {
    throw const FahxException('.fahx payload is not valid JSON');
  }
  if (payload is! Map<String, dynamic> ||
      payload['version'] != fahxVersion ||
      payload['providers'] is! List) {
    throw const FahxException('.fahx payload is malformed');
  }
  return [
    for (final raw in payload['providers'] as List) parseFahxProviderEntry(raw),
  ];
}

/// Decrypts a `.fahx` envelope map. Wrong passphrase and tampered
/// ciphertext are indistinguishable by design (same authentication
/// failure) — both throw [FahxException].
String decryptFahx(Map<String, dynamic> envelope, String passphrase) =>
    decryptFahxEnvelope(envelope, passphrase, version: fahxVersion);
