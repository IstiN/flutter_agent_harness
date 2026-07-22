import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Creates the [SecretsStore] for IO platforms: entries from a `.env` file
/// in the current working directory (when present) merged under an
/// in-memory overlay.
SecretsStore createSecretsStore() =>
    DotEnvSecretsStore('${Directory.current.path}/.env');

/// A [SecretsStore] that reads `.env`-style entries from [path] and merges
/// an in-memory overlay on top (overlay wins).
///
// TODO(secrets-card): back the store with flutter_secure_storage on mobile
// (Keychain/Keystore) instead of a plaintext file + process memory; that
// needs native entitlements/config, so it is deliberately out of scope here.
final class DotEnvSecretsStore implements SecretsStore {
  /// Creates a store reading secrets from the `.env` file at [path].
  DotEnvSecretsStore(this._path);

  final String _path;
  final Map<String, String> _overlay = {};
  Map<String, String>? _fileSecrets;

  /// Adds or replaces a secret in the in-memory overlay (takes precedence
  /// over the file).
  void set(String name, String value) => _overlay[name] = value;

  @override
  Future<Map<String, String>> readAll() async {
    final fileSecrets = await _loadFileSecrets();
    return {...fileSecrets, ..._overlay};
  }

  Future<Map<String, String>> _loadFileSecrets() async {
    final cached = _fileSecrets;
    if (cached != null) return cached;
    final file = File(_path);
    if (!file.existsSync()) return _fileSecrets = const {};
    return _fileSecrets = parseDotEnv(await file.readAsString());
  }
}

/// Parses `.env` content: `NAME=value` lines, `#` comments and blank lines,
/// an optional `export ` prefix, and optional single/double quotes around
/// values.
Map<String, String> parseDotEnv(String content) {
  final secrets = <String, String>{};
  for (final rawLine in content.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final body = line.startsWith('export ') ? line.substring(7).trim() : line;
    final equals = body.indexOf('=');
    if (equals <= 0) continue;
    final name = body.substring(0, equals).trim();
    var value = body.substring(equals + 1).trim();
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        value = value.substring(1, value.length - 1);
      }
    }
    if (name.isNotEmpty) secrets[name] = value;
  }
  return secrets;
}
