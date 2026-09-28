/// The `fa jsr widget:test|widget:screenshot` delegate (gh-1033): resolve
/// the `js_widget_runtime` package root from the CURRENT project's
/// `.dart_tool/package_config.json`, then exec the package's own agent CLI
/// (`bin/jsr_widget.dart`) via `dart`, streaming the child's stdout/stderr
/// verbatim and propagating its exit code.
///
/// Delegate, don't reimplement (invariant I1): this library contains zero
/// widget/event/assert/render logic — the jsr version used is whatever the
/// current project resolves, never pinned here. Failure transparency
/// (invariant I2): the child's output and exit code pass through unmangled,
/// so a `--json` machine consumer gets the jsr report byte-identical.
///
/// Pure Dart over [ExecutionEnv]: the platform bits the delegate needs
/// (the PATH string and its list separator) are parameters supplied by the
/// host, which keeps both entrypoints (headless `fa jsr` and the REPL
/// `/jsr` alias) testable with [MemoryExecutionEnv] + a scripted shell.
library;

import 'dart:convert';

import '../env/execution_env.dart';
import 'cli_args.dart';

/// The pub package whose agent CLI this delegate fronts.
const jsrPackageName = 'js_widget_runtime';

/// The package-relative entrypoint of the jsr agent CLI (0.4.126+).
const jsrCliEntrypoint = 'bin/jsr_widget.dart';

/// The jsr release that shipped `bin/jsr_widget.dart` — named in the
/// upgrade hint when the resolved package predates it.
const jsrCliSinceVersion = '0.4.126';

/// IO channels of the jsr delegate. The child's stdout/stderr chunks ride
/// the write channels verbatim (no newline fixups, no re-wrapping);
/// harness diagnostics (usage, the clean-error hints) ride [note] as
/// single lines.
abstract interface class JsrCliIo {
  /// A chunk of the child process's stdout.
  void writeStdout(String chunk);

  /// A chunk of the child process's stderr.
  void writeStderr(String chunk);

  /// A one-line harness diagnostic.
  void note(String line);
}

/// An adapter over raw sinks: the headless CLI binds the process's real
/// stdout/stderr, the REPL routes everything through [CliIO].
final class SinkJsrCliIo implements JsrCliIo {
  /// Creates a [SinkJsrCliIo].
  const SinkJsrCliIo({
    required this.onStdout,
    required this.onStderr,
    required this.onNote,
  });

  /// Sink for the child's stdout chunks.
  final void Function(String chunk) onStdout;

  /// Sink for the child's stderr chunks.
  final void Function(String chunk) onStderr;

  /// Sink for harness diagnostics.
  final void Function(String line) onNote;

  @override
  void writeStdout(String chunk) => onStdout(chunk);

  @override
  void writeStderr(String chunk) => onStderr(chunk);

  @override
  void note(String line) => onNote(line);
}

/// The outcome of resolving the jsr package from the project's
/// package_config.
sealed class JsrPackageResolution {
  const JsrPackageResolution();
}

/// The package resolved and its CLI entrypoint exists.
final class JsrPackageReady extends JsrPackageResolution {
  /// Creates a [JsrPackageReady].
  const JsrPackageReady({required this.packageRoot});

  /// The package's root directory (no trailing separator).
  final String packageRoot;
}

/// The project has no usable `js_widget_runtime` dependency: no
/// package_config, an unreadable/malformed one, or no entry for the
/// package. [detail] names what was checked.
final class JsrPackageMissing extends JsrPackageResolution {
  /// Creates a [JsrPackageMissing].
  const JsrPackageMissing({required this.detail});

  /// Human-readable reason (names the package_config path).
  final String detail;
}

/// The package resolved but `bin/jsr_widget.dart` is absent — the resolved
/// jsr predates the agent CLI.
final class JsrCliEntrypointMissing extends JsrPackageResolution {
  /// Creates a [JsrCliEntrypointMissing].
  const JsrCliEntrypointMissing({required this.packageRoot});

  /// The package's root directory.
  final String packageRoot;
}

/// Resolves the jsr package root for [projectDir]: reads
/// `<projectDir>/.dart_tool/package_config.json`, finds the
/// `js_widget_runtime` entry, and resolves its `rootUri` against the
/// config directory (the package_config v2 rule — the project's own
/// lockfile truth, no version pin here).
Future<JsrPackageResolution> resolveJsrPackageRoot(
  ExecutionEnv env, {
  required String projectDir,
}) async {
  final configPath = '$projectDir/.dart_tool/package_config.json';
  final read = await env.readTextFile(configPath);
  if (read.isErr) {
    return JsrPackageMissing(detail: '$configPath: not found');
  }
  final Object? doc;
  try {
    doc = jsonDecode(read.valueOrNull!);
  } on FormatException catch (error) {
    return JsrPackageMissing(detail: '$configPath: invalid JSON ($error)');
  }
  if (doc is! Map<String, Object?>) {
    return JsrPackageMissing(detail: '$configPath: not a package_config');
  }
  final packages = doc['packages'];
  if (packages is! List<Object?>) {
    return JsrPackageMissing(detail: '$configPath: no packages list');
  }
  String? rootUriRaw;
  for (final entry in packages) {
    if (entry is Map<String, Object?> &&
        entry['name'] == jsrPackageName &&
        entry['rootUri'] is String) {
      rootUriRaw = entry['rootUri'] as String;
      break;
    }
  }
  if (rootUriRaw == null) {
    return JsrPackageMissing(detail: '$configPath: no $jsrPackageName entry');
  }
  // Relative rootUris resolve against the config file's directory; an
  // absolute file:// URI ignores the base.
  final resolved = Uri.directory('$projectDir/.dart_tool/').resolve(rootUriRaw);
  var root = resolved.toFilePath();
  while (root.endsWith('/') || root.endsWith(r'\')) {
    root = root.substring(0, root.length - 1);
  }
  return JsrPackageReady(packageRoot: root);
}

/// Whether `flutter` is reachable through [pathEnv]: scans each entry for
/// the flutter launcher (`flutter`, `flutter.exe`, `flutter.bat` — all
/// three candidates probed on every platform, so the check never needs a
/// platform flag).
Future<bool> flutterOnPath(
  FileSystem fs, {
  required String pathEnv,
  required String pathListSeparator,
}) async {
  for (final rawEntry in pathEnv.split(pathListSeparator)) {
    final entry = rawEntry.trim();
    if (entry.isEmpty) continue;
    for (final name in const ['flutter', 'flutter.exe', 'flutter.bat']) {
      if ((await fs.exists('$entry/$name')).valueOrNull == true) {
        return true;
      }
    }
  }
  return false;
}

/// Quotes one child-command argument for the shell: bare when it is made
/// of shell-safe characters, double-quoted otherwise (with `"`/`\`/`$`/
/// backtick escaped — sh semantics, which cmd also parses correctly for
/// the paths and JSON payloads this surface forwards).
String quoteJsrArg(String arg) {
  const safePattern = r'^[a-zA-Z0-9_@%+=:,./-]+$';
  if (RegExp(safePattern).hasMatch(arg)) return arg;
  final escaped = arg
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll(r'$', r'\$')
      .replaceAll('`', r'\`');
  return '"$escaped"';
}

/// Runs one `fa jsr <verb>` command and returns the child's exit code (or
/// 1 for the harness's own clean errors).
///
/// [pathEnv] and [pathListSeparator] come from the host (IO layer): the
/// headless CLI passes `Platform.environment['PATH']` and the platform
/// separator; the REPL passes the config's env-value accessor. Empty
/// [pathEnv] = nothing reachable = the flutter hint.
Future<int> runJsrCliCommand(
  JsrCliCommand cmd, {
  required JsrCliIo io,
  required ExecutionEnv env,
  required String projectDir,
  required String pathEnv,
  required String pathListSeparator,
  String dartExecutable = 'dart',
}) async {
  final resolution = await resolveJsrPackageRoot(env, projectDir: projectDir);
  final String script;
  switch (resolution) {
    case JsrPackageMissing(:final detail):
      io.note(
        'jsr: js_widget_runtime is not a dependency of this project '
        '($detail) — add js_widget_runtime to pubspec.yaml and run the '
        'package manager.',
      );
      return 1;
    case JsrCliEntrypointMissing(:final packageRoot):
      io.note(
        'jsr: js_widget_runtime at $packageRoot has no '
        '$jsrCliEntrypoint — the agent CLI shipped in '
        '$jsrCliSinceVersion; upgrade the dependency.',
      );
      return 1;
    case JsrPackageReady(:final packageRoot):
      script = '$packageRoot/$jsrCliEntrypoint';
    }
  if (!await flutterOnPath(
    env,
    pathEnv: pathEnv,
    pathListSeparator: pathListSeparator,
  )) {
    io.note(
      'jsr: flutter was not found on PATH — the jsr widget CLI runs real '
      'Flutter rendering and needs flutter (install it or add it to PATH).',
    );
    return 1;
  }
  final command =
      '$dartExecutable ${quoteJsrArg(script)} '
      '${[cmd.verb, ...cmd.args].map(quoteJsrArg).join(' ')}';
  final result = await env.exec(
    command,
    options: ShellExecOptions(
      cwd: projectDir,
      onStdout: io.writeStdout,
      onStderr: io.writeStderr,
    ),
  );
  if (result case Err(:final error)) {
    io.note('jsr: failed to run the jsr CLI: ${error.message}');
    return 1;
  }
  return result.valueOrNull!.exitCode;
}
