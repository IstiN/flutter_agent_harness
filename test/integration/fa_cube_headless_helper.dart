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
}) async {
  final result = await Process.run(
    'dart',
    [
      'run',
      'bin/fah.dart',
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
    workingDirectory: Directory.current.path,
    environment: {'OPENAI_API_KEY': 'mock', ...env},
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  ).timeout(timeout);
  return FaResult(
    stdout: result.stdout as String,
    stderr: result.stderr as String,
    exitCode: result.exitCode,
  );
}
