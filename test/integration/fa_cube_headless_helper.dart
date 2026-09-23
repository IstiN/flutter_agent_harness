/// Headless `fah` CLI runner for integration tests.
///
/// Spawns `dart run bin/fah.dart` as a real subprocess (repo root as the
/// working directory, the same convention as `pty_harness.dart`, which runs
/// everything against `Directory.current`) and drives ONE headless prompt
/// with `--cwd <workspace>` so the cube resolution, fs guard and cache all
/// key off the temp workspace instead of the repo.
library;

import 'dart:convert';
import 'dart:io';

/// Captured result of one headless CLI run.
final class FaResult {
  const FaResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;

  /// Both streams combined for output-text assertions.
  String get output => '$stdout\n$stderr';
}

/// The ambient environment minus every boot input a test must control:
/// `FA_*` (the preconfig/queue/log-file family) and credential-shaped vars
/// (`*_API_KEY`/`*_TOKEN`/`*_SECRET`/`*_KEY`/`*_CREDENTIALS`). A developer
/// or CI shell exports REAL provider keys, and an inherited key would
/// silently point a catalog provider at its real paid endpoint instead of
/// the mock (gh-760 review). Tests inject exactly the credentials they
/// mean by layering them over the scrubbed map.
Map<String, String> scrubbedChildEnv() {
  bool ambient(String key) {
    final upper = key.toUpperCase();
    return key.startsWith('FA_') ||
        upper.endsWith('_API_KEY') ||
        upper.endsWith('_TOKEN') ||
        upper.endsWith('_SECRET') ||
        upper.endsWith('_KEY') ||
        upper.endsWith('_CREDENTIALS');
  }

  return Map<String, String>.of(Platform.environment)
    ..removeWhere((key, _) => ambient(key));
}

/// The one spawn site both IT families share (`runFaHeadless` here,
/// `runFaHeadlessRaw` in poisoned_provider_boot_test.dart): the scrubbed
/// environment, the credential blank-pins and the `dart run bin/fah.dart`
/// invocation live HERE so the two families cannot diverge on what
/// "scrubbed" means (gh-760 review). [fahArgs] carries everything after
/// the script path; [env] and [extraEnv] layer over the scrub in that
/// order.
Future<FaResult> spawnFa({
  required List<String> fahArgs,
  Map<String, String> env = const {},
  Map<String, String> extraEnv = const {},
  Duration timeout = const Duration(minutes: 2),
}) async {
  // Scrub the ambient FA_* environment (a developer/CI shell may export
  // FA_PROVIDER_*/FA_PROVIDERS_QUEUE/FA_LOG_FILE/...): those are
  // boot-resolution inputs. Blank values read as unset at every consumer,
  // so the explicit blanks keep the override minimal where the injection
  // re-adds missing vars.
  final result = await Process.run(
    'dart',
    ['run', 'bin/fah.dart', ...fahArgs],
    workingDirectory: Directory.current.path,
    environment: {
      ...scrubbedChildEnv(),
      'OPENAI_API_KEY': 'mock',
      'FA_PROVIDER_TYPE': '',
      'FA_PROVIDER_NAME': '',
      'FA_PROVIDER_CONFIG': '',
      'FA_PROVIDER_CONFIG_BASE64': '',
      'FA_PROVIDERS_QUEUE': '',
      'FA_LOG_FILE': '',
      ...env,
      ...extraEnv,
    },
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(timeout);
  return FaResult(
    stdout: result.stdout as String,
    stderr: result.stderr as String,
    exitCode: result.exitCode,
  );
}

/// Runs one headless prompt against the CLI.
///
/// [workspace] is passed as `--cwd` (cube manifests, cache and session cwd
/// resolve there); [env] entries are layered over the inherited environment
/// (pass `HOME` pointing at a temp home so the CLI never reads the
/// developer's real `~/.fah`). `OPENAI_API_KEY` is pinned to `mock` unless
/// overridden. Throws [TimeoutException] past [timeout].
Future<FaResult> runFaHeadless({
  required Directory workspace,
  required String baseUrl,
  required String prompt,
  String? cube,
  String? cubeConfig,
  Map<String, String> env = const {},
  Duration timeout = const Duration(minutes: 2),
}) {
  return spawnFa(
    fahArgs: [
      '--provider',
      'openai-completions',
      '--base-url',
      baseUrl,
      '--model',
      'mock-model',
      '--cwd',
      workspace.path,
      if (cube != null) ...['--cube', cube],
      if (cubeConfig != null) ...['--cube-config', cubeConfig],
      '-p',
      prompt,
    ],
    env: env,
    timeout: timeout,
  );
}
