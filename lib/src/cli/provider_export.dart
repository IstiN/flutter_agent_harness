/// Headless `fa config export-providers` (issue #34 item 3, §S6 fallback
/// tier): writes the saved custom providers + their keys to a
/// passphrase-encrypted `.fahx` file, and the matching pure import.
///
/// Envelope (JSON, versioned):
///
/// ```json
/// {"version":1,
///  "kdf":{"algo":"pbkdf2-sha256","iterations":210000,"salt":"<b64>"},
///  "nonce":"<b64>",
///  "ct":"<b64>"}
/// ```
///
/// `ct` = XOR(plaintext, HMAC-CTR keystream) ‖ HMAC-SHA256(macKey,
/// nonce ‖ ciphertext) — encrypt-then-MAC; both keys derive from one
/// PBKDF2-HMAC-SHA256 run (enc key = first 32 bytes, mac key = last 32).
/// Wrong passphrase or a tampered file fails LOUDLY with
/// [ProviderExportException]; nothing is ever written on a failed
/// decrypt.
///
/// The format's pure codec (envelope decrypt, provider-entry parsing, and
/// the stateful SHA-256/HMAC crypto core — neither package:crypto (fresh
/// sink tree per message) nor pointycastle (a fresh ByteData view per
/// word) can reuse HMAC state, and a 210000-round KDF was allocating
/// ~4 KB per iteration → GC storms, issue #1850 AC1) lives in
/// `../providers/fahx_codec.dart`, shared with the browser extension's
/// `.fahx` import. The envelope bytes are unchanged and pinned by
/// test/cli/provider_export_compat_test.dart goldens.
///
/// Like `ext_cli.dart`, this file is bin-only (dart:io for the default
/// environment lookup); the core library never imports it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import '../env/execution_env.dart';
import '../model_roles/provider_catalog.dart' show parseAuthHeaderName;
import '../providers/fahx_codec.dart'
    show
        FahxException,
        decryptFahxEnvelope,
        fahxKeystream,
        fahxMacTag,
        fahxXor,
        parseFahxProviderEntry,
        pbkdf2Sha256;
import 'agent_cli.dart';
import 'cli_args.dart';
import 'custom_providers.dart';

// The golden-pinned PBKDF2 vectors in
// test/cli/provider_export_compat_test.dart call [pbkdf2Sha256] through
// this file; re-export it from the codec.
export '../providers/fahx_codec.dart' show pbkdf2Sha256;

/// Envelope + payload version.
const int providerExportVersion = 1;

/// Default PBKDF2-HMAC-SHA256 work factor (>= 100000 per the §S6 spec).
const int providerExportIterations = 210000;

/// Default `--out` file name.
const String providerExportDefaultFile = 'providers.fahx';

/// A loud, single failure type for every export/import error: bad shape,
/// unsupported version/kdf, wrong passphrase, tampered ciphertext. The
/// type itself lives in the shared codec; this alias keeps the CLI-side
/// name for every throw/catch site and test.
typedef ProviderExportException = FahxException;

/// One imported provider: the registry entry plus its transferred key
/// (null when the export carried none).
final class ExportedProvider {
  const ExportedProvider({required this.entry, this.key});

  final CustomProviderEntry entry;
  final String? key;
}

Uint8List _randomBytes(int count) {
  final bytes = Uint8List(count);
  final random = Random.secure();
  for (var i = 0; i < count; i++) {
    bytes[i] = random.nextInt(256);
  }
  return bytes;
}

/// Encrypts [plaintext] into the `.fahx` envelope map.
Map<String, dynamic> encryptProvidersExport(
  String plaintext,
  String passphrase, {
  int iterations = providerExportIterations,
  List<int>? salt,
  List<int>? nonce,
}) {
  final usedSalt = salt ?? _randomBytes(16);
  final usedNonce = nonce ?? _randomBytes(16);
  final plainBytes = utf8.encode(plaintext);
  final keys = pbkdf2Sha256(utf8.encode(passphrase), usedSalt, iterations, 64);
  final ciphertext = fahxXor(
    plainBytes,
    fahxKeystream(keys.sublist(0, 32), usedNonce, plainBytes.length),
  );
  final tag = fahxMacTag(keys.sublist(32), usedNonce, ciphertext);
  final blob = Uint8List(ciphertext.length + tag.length);
  blob
    ..setRange(0, ciphertext.length, ciphertext)
    ..setRange(ciphertext.length, blob.length, tag);
  return {
    'version': providerExportVersion,
    'kdf': {
      'algo': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64Encode(usedSalt),
    },
    'nonce': base64Encode(usedNonce),
    'ct': base64Encode(blob),
  };
}

/// Decrypts a `.fahx` envelope. Every failure is a loud
/// [ProviderExportException] — wrong passphrase and tampered ciphertext
/// are indistinguishable by design (same authentication failure).
String decryptProvidersExport(
  Map<String, dynamic> envelope,
  String passphrase,
) => decryptFahxEnvelope(envelope, passphrase, version: providerExportVersion);

// ---------------------------------------------------------------------------
// Pure import.
// ---------------------------------------------------------------------------

/// Decodes + decrypts + verifies a `.fahx` file's contents into entries.
/// Pure: reads nothing, writes nothing.
List<ExportedProvider> importProvidersExport(
  String contents,
  String passphrase,
) {
  final envelope = _decodeJsonObject(contents, '.fahx file is not valid JSON');
  final payload = _decodeJsonObject(
    decryptProvidersExport(envelope, passphrase),
    '.fahx payload is not valid JSON',
  );
  if (payload['version'] != providerExportVersion ||
      payload['providers'] is! List) {
    throw const ProviderExportException('.fahx payload is malformed');
  }
  return [
    for (final raw in payload['providers'] as List) _parseProviderEntry(raw),
  ];
}

/// Decodes [text] and requires a JSON object; anything else is a loud
/// [ProviderExportException] with [message].
Map<String, dynamic> _decodeJsonObject(String text, String message) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    throw ProviderExportException(message);
  }
  if (decoded is! Map<String, dynamic>) {
    throw ProviderExportException(message);
  }
  return decoded;
}

/// Validates one `providers` list entry and decodes it into an
/// [ExportedProvider]; a missing name/apiType/baseUrl/modelId is malformed.
ExportedProvider _parseProviderEntry(Object? raw) {
  final entry = parseFahxProviderEntry(raw);
  return ExportedProvider(
    entry: CustomProviderEntry(
      name: entry.name,
      apiType: entry.apiType,
      baseUrl: entry.baseUrl,
      modelId: entry.modelId,
      keyName: entry.keyName,
      authHeader: parseAuthHeaderName(
        (raw as Map<String, dynamic>)['authHeader'],
        'exported "${entry.name}"',
      ),
    ),
    key: entry.key,
  );
}

// ---------------------------------------------------------------------------
// CLI command.
// ---------------------------------------------------------------------------

/// Runs one `fa config <verb>` command and returns the process exit code.
///
/// All file access goes through [env]; key resolution consults
/// [environment] first, then [secureRead] (the secure-store snapshot) —
/// the same order as the interactive CLI. Key values NEVER appear in
/// output lines.
Future<int> runProviderExportCommand(
  ConfigCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required List<CustomProviderEntry> entries,
  String? Function(String keyName)? secureRead,
  Map<String, String>? environment,
  Future<String> Function()? readPassphrase,
  int iterations = providerExportIterations,
}) async {
  // The parser admits only export-providers today; kept switch-shaped so
  // the next verb extends, not forks.
  switch (cmd.verb) {
    case 'export-providers':
      return _exportProviders(
        cmd,
        io: io,
        env: env,
        entries: entries,
        secureRead: secureRead,
        environment: environment,
        readPassphrase: readPassphrase,
        iterations: iterations,
      );
    default:
      io.writeln('unknown config verb: ${cmd.verb}');
      return 1;
  }
}

Future<int> _exportProviders(
  ConfigCliCommand cmd, {
  required CliIO io,
  required ExecutionEnv env,
  required List<CustomProviderEntry> entries,
  String? Function(String keyName)? secureRead,
  Map<String, String>? environment,
  Future<String> Function()? readPassphrase,
  required int iterations,
}) async {
  final passphrase = await _readPassphrase(
    cmd,
    io: io,
    readPassphrase: readPassphrase,
  );
  if (passphrase == null) return 1;
  final providers = <Map<String, dynamic>>[];
  final envMap = environment ?? Platform.environment;
  for (final entry in entries) {
    final keyName = _keyNameFor(entry);
    final fromEnv = envMap[keyName];
    final stored = secureRead?.call(keyName);
    final key = fromEnv != null && fromEnv.isNotEmpty
        ? fromEnv
        : (stored != null && stored.isNotEmpty ? stored : null);
    if (key == null) {
      io.writeln(
        'warning: no key for "${entry.name}" ($keyName) — '
        'entry exported without it',
      );
    }
    providers.add({
      'name': entry.name,
      'apiType': entry.apiType,
      'baseUrl': entry.baseUrl,
      'modelId': entry.modelId,
      'authMethod': entry.authMethod.name,
      'keyName': ?entry.keyName,
      'authHeader': ?entry.authHeader,
      'key': ?key,
    });
  }
  final envelope = encryptProvidersExport(
    jsonEncode({
      'version': providerExportVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'providers': providers,
    }),
    passphrase,
    iterations: iterations,
  );
  final target = cmd.out ?? providerExportDefaultFile;
  final result = await env.writeFile(target, '${jsonEncode(envelope)}\n');
  switch (result) {
    case Err(:final error):
      io.writeln('fa: cannot write $target: $error');
      return 1;
    case Ok():
      break;
  }
  final withKeys = providers.where((p) => p['key'] != null).length;
  io.writeln(
    'wrote $target: ${providers.length} providers, '
    '$withKeys keys (passphrase-encrypted .fahx)',
  );
  return 0;
}

/// Reads the passphrase: one stdin line in `--passphrase-stdin` mode,
/// else the double prompt (empty or mismatched → null, exit).
Future<String?> _readPassphrase(
  ConfigCliCommand cmd, {
  required CliIO io,
  Future<String> Function()? readPassphrase,
}) async {
  if (cmd.passphraseStdin) {
    return _readPassphraseStdin(io, readPassphrase: readPassphrase);
  }
  return _readPassphrasePrompt(io, readPassphrase: readPassphrase);
}

/// The `--passphrase-stdin` mode: one line from the injected reader.
Future<String?> _readPassphraseStdin(
  CliIO io, {
  required Future<String> Function()? readPassphrase,
}) async {
  if (readPassphrase == null) {
    io.writeln('fa: --passphrase-stdin needs a stdin reader');
    return null;
  }
  final value = await readPassphrase();
  if (value.isEmpty) {
    io.writeln('fa: passphrase must not be empty');
    return null;
  }
  return value;
}

/// The interactive double prompt: empty or mismatched pair → null.
Future<String?> _readPassphrasePrompt(
  CliIO io, {
  required Future<String> Function()? readPassphrase,
}) async {
  Future<String> readLine() =>
      readPassphrase != null ? readPassphrase() : io.lines.first;
  io.writeln('enter passphrase:');
  final first = await readLine();
  io.writeln('confirm passphrase:');
  final second = await readLine();
  if (first.isEmpty) {
    io.writeln('fa: passphrase must not be empty');
    return null;
  }
  if (first != second) {
    io.writeln('fa: passphrases do not match');
    return null;
  }
  return first;
}

String _keyNameFor(CustomProviderEntry entry) =>
    entry.keyName ??
    CustomProviderRegistry.keyNameFor(entry.baseUrl, providerName: entry.name);
