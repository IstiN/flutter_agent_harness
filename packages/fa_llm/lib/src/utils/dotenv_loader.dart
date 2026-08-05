import 'dart:io';

/// Loads key/value pairs from a `.env` file.
///
/// Comment lines start with `#` and blank lines are ignored.
Map<String, String> loadDotEnv([String path = '.env']) {
  final file = File(path);
  if (!file.existsSync()) return {};

  final values = <String, String>{};
  for (final line in file.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final idx = trimmed.indexOf('=');
    if (idx == -1) continue;
    final key = trimmed.substring(0, idx).trim();
    final value = trimmed.substring(idx + 1).trim();
    if (key.isNotEmpty) values[key] = value;
  }
  return values;
}
