/// [ExecutionEnv] decorator that injects secrets into shell executions.
///
/// Wraps any [ExecutionEnv] and merges a secret map into
/// [ShellExecOptions.env] on every [exec], so `$NAME` expands inside the
/// sandbox shell (WASM, in-memory, or local) without the values ever
/// entering the agent context. Pair with `SecretRedactor` (which masks the
/// values in tool results) for the full secrets flow.
///
/// The map is live: [addSecrets] merges entries at runtime (e.g. a key the
/// user grants mid-session through the `request_secret` tool), and later
/// [exec] calls pick them up.
library;

import 'dart:async';

import 'delegating_execution_env.dart';
import 'execution_env.dart';
import 'secret_presence.dart';

/// An [ExecutionEnv] that injects secret env vars into every [exec].
final class SecretsExecutionEnv extends ForwardingFs
    with
        ForwardingBackgroundShell,
        ForwardingRangedReadFs,
        ForwardingRenamableFs {
  /// Creates a decorator over [delegate] injecting [secrets] (name → value).
  SecretsExecutionEnv(super.delegate, Map<String, String> secrets)
    : _secrets = Map.of(secrets);

  final Map<String, String> _secrets;

  /// Secret NAMES known to the host beyond the live values (gh-1444 AC4):
  /// the system-prompt name list — a name the user has NOT (yet) granted
  /// still renders `ABSENT` in the sandbox `env` listing instead of
  /// disappearing, so secret-absence is provable, not guessable. Names
  /// only, never values.
  final Set<String> _knownNames = {};

  /// Every secret name this env announces in exec envs: the live values'
  /// names plus the host-registered roster, sorted.
  List<String> get secretNames {
    final names = {..._knownNames, ..._secrets.keys}.toList()..sort();
    return names;
  }

  /// Extends the announced secret-name roster (names only). Hosts pass the
  /// system-prompt "Available secret env vars" list here so `env` can show
  /// `NAME: ABSENT` for a not-currently-granted name.
  void registerSecretNames(Iterable<String> names) => _knownNames.addAll(names);

  /// Merges [secrets] into the injected map at runtime; later [exec] calls
  /// see them. Per-call [ShellExecOptions.env] entries still win over the
  /// injected secrets.
  void addSecrets(Map<String, String> secrets) {
    _secrets.addAll(secrets);
  }

  /// Removes [name]'s value from the injected map (gh-1444 E3): later execs
  /// stop seeing the value while the name STAYS in the roster, so the
  /// sandbox `env` listing renders `NAME: ABSENT` instead of the variable
  /// silently disappearing. An exec already dispatched with the merged env
  /// keeps it (documented lifetime).
  void revokeSecret(String name) {
    _knownNames.add(name);
    _secrets.remove(name);
  }

  /// A snapshot copy of the live secret map currently injected into [exec]
  /// (name → value). Hosts read it for their own secret bridges (e.g. an
  /// app-facing keys API); mutating the returned map does not affect the
  /// env.
  Map<String, String> secretsSnapshot() => Map.of(_secrets);

  @override
  FutureOr<ShellExecOptions?> mergeExecOptions(ShellExecOptions? options) {
    if (_secrets.isEmpty && _knownNames.isEmpty) return options;
    return _optionsWithMergedEnv(options);
  }

  @override
  FutureOr<ShellExecOptions?> mergeJobOptions(ShellExecOptions? options) {
    if (_secrets.isEmpty && _knownNames.isEmpty) return options;
    return _optionsWithMergedEnv(options);
  }

  /// The exec env with the secret values AND the presence roster
  /// ([secretPresenceEnvVar] — names only) merged in. Per-call env entries
  /// win over the injected secret VALUES; the roster is harness-owned and
  /// cannot be shadowed by a per-call entry. Null when there is nothing to
  /// merge (no secrets, no roster, no per-call env).
  Map<String, String>? mergedExecEnv(ShellExecOptions? options) {
    final names = secretNames;
    if (names.isEmpty) return options?.env;
    return {
      ..._secrets,
      ...?options?.env,
      if (names.isNotEmpty) secretPresenceEnvVar: names.join(' '),
    };
  }

  /// The options for a delegated exec: identical to [options] with the env
  /// replaced by [mergedExecEnv] — every other field (stdin, live stdin,
  /// timeouts, callbacks) rides through untouched.
  ShellExecOptions _optionsWithMergedEnv(ShellExecOptions? options) {
    return ShellExecOptions(
      cwd: options?.cwd,
      env: mergedExecEnv(options),
      timeout: options?.timeout,
      cancelToken: options?.cancelToken,
      onStdout: options?.onStdout,
      onStderr: options?.onStderr,
      stdinData: options?.stdinData,
      liveStdin: options?.liveStdin,
      jobLogMaxBytes: options?.jobLogMaxBytes,
      onJobLogWarning: options?.onJobLogWarning,
      jobLogRedactor: options?.jobLogRedactor,
    );
  }
}
