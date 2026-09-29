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

export 'cli_args.dart' show JsrCliCommand, jsrVerbs, jsrUsage;

/// The pub package whose agent CLI this delegate fronts.
const jsrPackageName = 'js_widget_runtime';

/// The package-relative entrypoint of the jsr agent CLI (0.4.128+).
const jsrCliEntrypoint = 'bin/jsr_widget.dart';

/// The jsr release that shipped `bin/jsr_widget.dart` — named in the
/// upgrade hint when the resolved package predates it.
const jsrCliSinceVersion = '0.4.128';

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
  final lookup = _findJsrRootUri(read.valueOrNull!, configPath);
  if (lookup.problem != null) {
    return JsrPackageMissing(detail: lookup.problem!);
  }
  return _resolveJsrRoot(env, lookup.rootUri!, projectDir: projectDir);
}

/// The jsr entry's `rootUri`, or [problem] naming why the config has none.
typedef _JsrRootUriLookup = ({String? rootUri, String? problem});

/// Decodes the package_config text and finds the `js_widget_runtime`
/// entry's `rootUri`.
_JsrRootUriLookup _findJsrRootUri(String text, String configPath) {
  final Object? doc;
  try {
    doc = jsonDecode(text);
  } on FormatException catch (error) {
    return (rootUri: null, problem: '$configPath: invalid JSON ($error)');
  }
  if (doc is! Map<String, Object?>) {
    return (rootUri: null, problem: '$configPath: not a package_config');
  }
  final packages = doc['packages'];
  if (packages is! List<Object?>) {
    return (rootUri: null, problem: '$configPath: no packages list');
  }
  for (final entry in packages) {
    if (entry is Map<String, Object?> && entry['name'] == jsrPackageName) {
      final uri = entry['rootUri'];
      if (uri is String) return (rootUri: uri, problem: null);
    }
  }
  return (rootUri: null, problem: '$configPath: no $jsrPackageName entry');
}

/// Resolves the entry's `rootUri` to the package root and verifies the
/// CLI entrypoint exists.
Future<JsrPackageResolution> _resolveJsrRoot(
  ExecutionEnv env,
  String rootUriRaw, {
  required String projectDir,
}) async {
  final configPath = '$projectDir/.dart_tool/package_config.json';
  // A hand-edited or corrupt config can carry a rootUri that is not a
  // resolvable URI (`:::`) or not a file URI (`https://…`): both throw.
  // The clean-error contract says malformed package_config input is a
  // JsrPackageMissing, never a stack trace.
  final String resolvedPath;
  try {
    // Relative rootUris resolve against the config file's directory; an
    // absolute file:// URI ignores the base.
    final resolved = Uri.directory(
      '$projectDir/.dart_tool/',
    ).resolve(rootUriRaw);
    resolvedPath = _stripPathSeparators(resolved.toFilePath());
  } on FormatException catch (error) {
    return JsrPackageMissing(
      detail: '$configPath: invalid rootUri "$rootUriRaw" ($error)',
    );
  } on UnsupportedError {
    return JsrPackageMissing(
      detail: '$configPath: rootUri "$rootUriRaw" is not a file URI',
    );
  } on ArgumentError {
    return JsrPackageMissing(
      detail: '$configPath: rootUri "$rootUriRaw" is not a file URI',
    );
  }
  final root = resolvedPath;
  // A resolved package older than the agent CLI has no entrypoint; name
  // the upgrade instead of letting `dart` die with a generic file error.
  if ((await env.exists('$root/$jsrCliEntrypoint')).valueOrNull != true) {
    return JsrCliEntrypointMissing(packageRoot: root);
  }
  return JsrPackageReady(packageRoot: root);
}

/// Drops trailing `/` and `\` separators from a resolved directory path.
String _stripPathSeparators(String path) {
  var root = path;
  while (root.endsWith('/') || root.endsWith(r'\')) {
    root = root.substring(0, root.length - 1);
  }
  return root;
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

/// Quotes one child-command argument for the shell.
///
/// POSIX (`windowsQuoting: false`, the default): sh rules — bare when the
/// argument is made of shell-safe characters, double-quoted otherwise
/// (with `"`/`\`/`$`/backtick escaped).
///
/// Windows (`windowsQuoting: true`): cmd rules. `cmd /c` toggles its quote
/// state at EVERY `"` — it does not honor `\"` — so an embedded quote
/// would flip cmd's scan outside the quotes and let the remainder of the
/// argument's cmd metacharacters (`&`, `|`, `<>`, `^`, `()`) scan as ACTIVE
/// command separators. The quoted form therefore combines the MSVCRT
/// backslash rules the child's argv parser applies (backslash runs before
/// a quote — and trailing runs — double; `"` becomes `\"`) with
/// `^`-escaping of the cmd metacharacters exactly while cmd's scan is
/// outside quotes (after each emitted `\"`). Both parsers then agree with
/// the original argument.
///
/// Returns null when the argument cannot be carried faithfully: cmd
/// expands `%VAR%` in a separate phase BEFORE quote/caret parsing and
/// quotes do not protect it, so an argument containing `%` would arrive
/// mutated no matter how it is quoted. The caller reports that as a clean
/// note instead of exec'ing a mutated command line.
String? quoteJsrArg(String arg, {bool windowsQuoting = false}) =>
    _quoteJsr(arg, always: false, windowsQuoting: windowsQuoting);

/// Always-quoted form for the resolved entrypoint path — never bare, so a
/// pub-cache path with spaces stays one shell word. Same shell rules and
/// the same null-means-uncarriable contract as [quoteJsrArg].
String? quoteJsrScript(String path, {bool windowsQuoting = false}) =>
    _quoteJsr(path, always: true, windowsQuoting: windowsQuoting);

/// cmd metacharacters that are ACTIVE when its quote scan is outside
/// quotes (and therefore need `^`); inside quotes cmd treats them as
/// literal.
const _cmdMetacharacters = '&|<>^()';

String? _quoteJsr(
  String arg, {
  required bool always,
  required bool windowsQuoting,
}) {
  if (!windowsQuoting) {
    const safePattern = r'^[a-zA-Z0-9_@%+=:,./-]+$';
    if (!always && RegExp(safePattern).hasMatch(arg)) return arg;
    final escaped = arg
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll(r'$', r'\$')
        .replaceAll('`', r'\`');
    return '"$escaped"';
  }
  // cmd: `%` is uncarryable everywhere (see the doc comment), and the
  // safe pattern drops `%` so a bare `%VAR%` can never ride through the
  // expansion phase either.
  if (arg.contains('%')) return null;
  const safePattern = r'^[a-zA-Z0-9_@+=:,./-]+$';
  if (!always && RegExp(safePattern).hasMatch(arg)) return arg;
  return _quoteForCmd(arg);
}

/// MSVCRT + cmd-caret quoting: the child's argv parser honors `\"` with
/// doubled backslash runs, cmd toggles quote state at every bare `"` —
/// [cmdOutside] tracks which side cmd is on so the active metacharacters
/// it would see get carets.
String _quoteForCmd(String arg) {
  final out = StringBuffer('"');
  var cmdOutside = false;
  var i = 0;
  while (i < arg.length) {
    if (arg[i] == r'\') {
      i += _emitBackslashRun(out, arg, i);
      continue;
    }
    if (arg[i] == '"') {
      out.write(r'\"');
      cmdOutside = !cmdOutside;
    } else {
      if (cmdOutside && _cmdMetacharacters.contains(arg[i])) out.write('^');
      out.write(arg[i]);
    }
    i++;
  }
  out.write('"');
  return out.toString();
}

/// Emits the backslash run of [arg] starting at [i] into [out] under the
/// MSVCRT doubling rules the child's argv parser applies (a run directly
/// before a `"` — and a trailing run — doubles; otherwise it is literal),
/// and returns the number of characters consumed (the run length). A quote
/// the run ends on is left in place for the caller's `"` branch, which
/// emits `\"` and flips cmd's quote state.
int _emitBackslashRun(StringBuffer out, String arg, int i) {
  final runStart = i;
  while (i < arg.length && arg[i] == r'\') {
    i++;
  }
  final runLength = i - runStart;
  final beforeQuote = i < arg.length && arg[i] == '"';
  final atEnd = i == arg.length;
  out.write(r'\' * runLength * (beforeQuote || atEnd ? 2 : 1));
  return runLength;
}

/// Runs one `fa jsr <verb>` command and returns the child's exit code (or
/// 1 for the harness's own clean errors).
///
/// [pathEnv] and [pathListSeparator] come from the host (IO layer): the
/// headless CLI passes `Platform.environment['PATH']` and the platform
/// separator; the REPL passes the config's env-value accessor. Empty
/// [pathEnv] = nothing reachable = the flutter hint. A NULL [pathEnv] =
/// the host has no env accessor at all and cannot see PATH — the flutter
/// preflight is skipped (the child owns its own "no flutter" failure per
/// I2) because claiming flutter is missing would be a lie.
///
/// [windowsQuoting] selects the shell dialect of the quoting: hosts whose
/// `env.exec` routes through `cmd /c` pass true (see [quoteJsrArg]).
Future<int> runJsrCliCommand(
  JsrCliCommand cmd, {
  required JsrCliIo io,
  required ExecutionEnv env,
  required String projectDir,
  required String? pathEnv,
  required String pathListSeparator,
  String dartExecutable = 'dart',
  bool windowsQuoting = false,
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
  if (pathEnv != null &&
      !await flutterOnPath(
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
  final quotedScript = quoteJsrScript(script, windowsQuoting: windowsQuoting);
  if (quotedScript == null) {
    return _noteUncarriable(
      io,
      arg: script,
      what: 'the resolved jsr package path',
    );
  }
  final forwarded = <String>[];
  for (final arg in [cmd.verb, ...cmd.args]) {
    final quoted = quoteJsrArg(arg, windowsQuoting: windowsQuoting);
    if (quoted == null) return _noteUncarriable(io, arg: arg);
    forwarded.add(quoted);
  }
  final command = '$dartExecutable $quotedScript ${forwarded.join(' ')}';
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

/// The clean note for a `%`-bearing argument on the cmd dialect: cmd
/// expands it before any escaping applies, so the harness refuses to exec
/// a mutated command line.
int _noteUncarriable(
  JsrCliIo io, {
  required String arg,
  String what = 'this argument',
}) {
  io.note(
    'jsr: $what contains % ("$arg") — cmd expands %VAR% before its quote '
    'and caret parsing and quotes do not protect it, so it cannot be '
    'passed faithfully through cmd. Run `fa jsr` from a POSIX shell (bash '
    '/ git-bash) for this invocation, or restructure the value without %.',
  );
  return 1;
}
