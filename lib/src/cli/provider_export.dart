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
/// ponytail: the AEAD is HMAC-SHA256-based (package:crypto, a direct
/// dep) because package:cryptography (Chacha20.poly1305Aead) is not a
/// declared dependency of the core package — swapping in an AEAD cipher
/// is a version bump away (the envelope's version/kdf.algo gates it) if
/// `cryptography` ever lands in pubspec.
///
/// Like `ext_cli.dart`, this file is bin-only (dart:io for the default
/// environment lookup); the core library never imports it.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../env/execution_env.dart';
import 'agent_cli.dart';
import 'cli_args.dart';
import 'custom_providers.dart';

/// Envelope + payload version.
const int providerExportVersion = 1;

/// Default PBKDF2-HMAC-SHA256 work factor (>= 100000 per the §S6 spec).
const int providerExportIterations = 210000;

/// Default `--out` file name.
const String providerExportDefaultFile = 'providers.fahx';

/// A loud, single failure type for every export/import error: bad shape,
/// unsupported version/kdf, wrong passphrase, tampered ciphertext.
final class ProviderExportException implements Exception {
  const ProviderExportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One imported provider: the registry entry plus its transferred key
/// (null when the export carried none).
final class ExportedProvider {
  const ExportedProvider({required this.entry, this.key});

  final CustomProviderEntry entry;
  final String? key;
}

// ---------------------------------------------------------------------------
// Crypto (package:crypto only).
// ---------------------------------------------------------------------------

/// PBKDF2-HMAC-SHA256 (RFC 2898) over package:crypto.
Uint8List pbkdf2Sha256(
  List<int> password,
  List<int> salt,
  int iterations,
  int dkLen,
) {
  final hmac = crypto.Hmac(crypto.sha256, password);
  final out = BytesBuilder(copy: false);
  var block = 1;
  while (out.length < dkLen) {
    var u = hmac.convert([
      ...salt,
      block >> 24,
      block >> 16,
      block >> 8,
      block,
    ]).bytes;
    final t = List<int>.of(u);
    for (var i = 1; i < iterations; i++) {
      u = hmac.convert(u).bytes;
      for (var j = 0; j < t.length; j++) {
        t[j] ^= u[j];
      }
    }
    out.add(t);
    block++;
  }
  return Uint8List.fromList(out.toBytes()).sublist(0, dkLen);
}

/// HMAC-SHA256 keystream in 32-byte blocks: block `n` =
/// HMAC(key, nonce ‖ u32le(n)) — an HKDF-Expand-shaped PRF stream.
List<int> _keystream(List<int> key, List<int> nonce, int length) {
  final hmac = crypto.Hmac(crypto.sha256, key);
  final out = BytesBuilder(copy: false);
  var counter = 0;
  while (out.length < length) {
    out.add(
      hmac.convert([
        ...nonce,
        counter & 0xff,
        (counter >> 8) & 0xff,
        (counter >> 16) & 0xff,
        (counter >> 24) & 0xff,
      ]).bytes,
    );
    counter++;
  }
  return out.toBytes();
}

List<int> _xor(List<int> data, List<int> keystream) => [
  for (var i = 0; i < data.length; i++) data[i] ^ keystream[i],
];

bool _constantTimeEquals(List<int> a, List<int> b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

List<int> _deriveKeys(String passphrase, List<int> salt, int iterations) =>
    pbkdf2Sha256(utf8.encode(passphrase), salt, iterations, 64);

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
  final keys = _deriveKeys(passphrase, usedSalt, iterations);
  final ciphertext = _xor(
    plainBytes,
    _keystream(keys.sublist(0, 32), usedNonce, plainBytes.length),
  );
  final tag = crypto.Hmac(
    crypto.sha256,
    keys.sublist(32),
  ).convert([...usedNonce, ...ciphertext]).bytes;
  return {
    'version': providerExportVersion,
    'kdf': {
      'algo': 'pbkdf2-sha256',
      'iterations': iterations,
      'salt': base64Encode(usedSalt),
    },
    'nonce': base64Encode(usedNonce),
    'ct': base64Encode([...ciphertext, ...tag]),
  };
}

/// Decrypts a `.fahx` envelope. Every failure is a loud
/// [ProviderExportException] — wrong passphrase and tampered ciphertext
/// are indistinguishable by design (same authentication failure).
String decryptProvidersExport(
  Map<String, dynamic> envelope,
  String passphrase,
) {
  if (envelope['version'] != providerExportVersion) {
    throw ProviderExportException(
      'unsupported .fahx version: ${envelope['version']}',
    );
  }
  final kdf = envelope['kdf'];
  if (kdf is! Map<String, dynamic> || kdf['algo'] != 'pbkdf2-sha256') {
    throw const ProviderExportException(
      'unsupported .fahx kdf (expected pbkdf2-sha256)',
    );
  }
  final iterations = kdf['iterations'];
  final saltB64 = kdf['salt'];
  final nonceB64 = envelope['nonce'];
  final ctB64 = envelope['ct'];
  if (iterations is! int ||
      iterations < 1 ||
      saltB64 is! String ||
      nonceB64 is! String ||
      ctB64 is! String) {
    throw const ProviderExportException('.fahx envelope is malformed');
  }
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List blob;
  try {
    salt = base64Decode(saltB64);
    nonce = base64Decode(nonceB64);
    blob = base64Decode(ctB64);
  } on FormatException {
    throw const ProviderExportException('.fahx envelope is malformed');
  }
  if (blob.length <= 32) {
    throw const ProviderExportException('.fahx envelope is malformed');
  }
  final ciphertext = blob.sublist(0, blob.length - 32);
  final tag = blob.sublist(blob.length - 32);
  final keys = _deriveKeys(passphrase, salt, iterations);
  final expected = crypto.Hmac(
    crypto.sha256,
    keys.sublist(32),
  ).convert([...nonce, ...ciphertext]).bytes;
  if (!_constantTimeEquals(expected, tag)) {
    throw const ProviderExportException(
      'wrong passphrase or corrupted .fahx file',
    );
  }
  return utf8.decode(
    _xor(ciphertext, _keystream(keys.sublist(0, 32), nonce, ciphertext.length)),
  );
}

// ---------------------------------------------------------------------------
// Pure import.
// ---------------------------------------------------------------------------

/// Decodes + decrypts + verifies a `.fahx` file's contents into entries.
/// Pure: reads nothing, writes nothing.
List<ExportedProvider> importProvidersExport(
  String contents,
  String passphrase,
) {
  final Object? envelope;
  try {
    envelope = jsonDecode(contents);
  } on FormatException {
    throw const ProviderExportException('.fahx file is not valid JSON');
  }
  if (envelope is! Map<String, dynamic>) {
    throw const ProviderExportException('.fahx file is not valid JSON');
  }
  final plaintext = decryptProvidersExport(envelope, passphrase);
  final Object? payload;
  try {
    payload = jsonDecode(plaintext);
  } on FormatException {
    throw const ProviderExportException('.fahx payload is not valid JSON');
  }
  if (payload is! Map<String, dynamic> ||
      payload['version'] != providerExportVersion ||
      payload['providers'] is! List) {
    throw const ProviderExportException('.fahx payload is malformed');
  }
  final imported = <ExportedProvider>[];
  for (final raw in payload['providers'] as List) {
    if (raw is! Map<String, dynamic>) {
      throw const ProviderExportException('.fahx payload is malformed');
    }
    final name = raw['name'];
    final apiType = raw['apiType'];
    final baseUrl = raw['baseUrl'];
    final modelId = raw['modelId'];
    if (name is! String ||
        name.isEmpty ||
        apiType is! String ||
        baseUrl is! String ||
        baseUrl.isEmpty ||
        modelId is! String) {
      throw const ProviderExportException('.fahx payload is malformed');
    }
    final keyName = raw['keyName'];
    final key = raw['key'];
    imported.add(
      ExportedProvider(
        entry: CustomProviderEntry(
          name: name,
          apiType: apiType,
          baseUrl: baseUrl,
          modelId: modelId,
          keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
        ),
        key: key is String && key.isNotEmpty ? key : null,
      ),
    );
  }
  return imported;
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
  io.writeln('enter passphrase:');
  final first = readPassphrase != null
      ? await readPassphrase()
      : await io.lines.first;
  io.writeln('confirm passphrase:');
  final second = readPassphrase != null
      ? await readPassphrase()
      : await io.lines.first;
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
