// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.


/// Secret PRESENCE signaling for sandbox `env` listings (gh-1444 AC4).
///
/// A secret's existence must be verifiable without its value ever
/// rendering: `$FA_TOKEN` in a command still expands to the real value
/// (bash needs it), but the `env` builtin prints `NAME: PRESENT` or
/// `NAME: ABSENT` instead of `NAME=<value>` — an authenticated call
/// failing on an absent secret becomes distinguishable from a swallowed
/// request, and the presence signal itself leaks nothing.
///
/// The roster travels in the exec env under [secretPresenceEnvVar] (names
/// only — the same channel the values already ride, one less wire).
library;

import 'secrets_execution_env.dart';

/// The env var carrying the secret-name roster (sorted, space-joined).
/// Injected by [SecretsExecutionEnv] into every exec; the shells' `env`
/// builtins render it as PRESENT/ABSENT lines and never list it itself.
const String secretPresenceEnvVar = 'FA_SECRET_VARS';

/// The secret names announced by [secretPresenceEnvVar] in [env].
Set<String> secretNamesFromEnv(Map<String, String> env) => (env[secretPresenceEnvVar] ?? '')
    .split(RegExp(r'\s+'))
    .where((name) => name.isNotEmpty)
    .toSet();

/// The `env` listing line for the secret [name]: `NAME: PRESENT` when a
/// non-empty value is live in [env], else `NAME: ABSENT`. The VALUE never
/// renders — presence only.
String secretPresenceLine(String name, Map<String, String> env) =>
    '$name: ${(env[name]?.isNotEmpty ?? false) ? 'PRESENT' : 'ABSENT'}';

/// Renders the full `env` listing over the merged exec [env]: plain vars
/// as `NAME=value`, rostered secret names as PRESENT/ABSENT lines (a
/// rostered name with no value in the env renders ABSENT — the revoked
/// secret must stay visible), and the roster var itself hidden. Sorted by
/// name, newline-terminated when non-empty.
String renderEnvListingWithSecretPresence(Map<String, String> env) {
  final names = secretNamesFromEnv(env);
  final lines = <String, String>{
    for (final entry in env.entries)
      if (entry.key != '?' && entry.key != secretPresenceEnvVar)
        entry.key: names.contains(entry.key)
            ? secretPresenceLine(entry.key, env)
            : '${entry.key}=${entry.value}',
    for (final name in names)
      if (!env.containsKey(name)) name: secretPresenceLine(name, env),
  };
  final sorted = lines.keys.toList()..sort();
  if (sorted.isEmpty) return '';
  return '${sorted.map((name) => lines[name]!).join('\n')}\n';
}
