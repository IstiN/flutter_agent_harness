// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Interpreter for the shell scripting subset parsed by [parseShellScript],
/// shared by `WasiSandboxShell` (mobile WASM sandbox) and `MemoryShell`
/// (web/in-memory sandbox) so both stay in lockstep.
///
/// The subset is deliberately small — enough for agent-style commands, not
/// POSIX:
///   - `if <cond>; then <body>; [elif ...;] [else ...;] fi` — the condition is
///     any statement list, truth = last exit code 0 (covers `[ ... ]`,
///     `test`, and plain commands such as `if ls /apps; then ...; fi`).
///   - `for NAME in word1 word2 ...; do <body>; done` — words get `$VAR`
///     expansion and command substitution, no globbing.
///   - `NAME=value` assignment statements (also `A=1 B=2`): the value is
///     expanded and stored like `export` does, so later expansions and child
///     processes see it (a subset simplification of POSIX scoping).
///   - command substitution `$(cmd)` and backquotes in expandable words,
///     including inside double quotes: the inner script runs recursively in
///     the same shell, its stdout is captured, trailing newlines trimmed, and
///     substituted. A failing inner command substitutes the empty string and
///     the script continues.
///
/// Word-splitting rule (documented subset choice): a substitution result is
/// NOT split when the word came from double quotes; when the word is
/// unquoted and contains a substitution, the expanded text is split on
/// whitespace and empty fields are dropped. Words without a substitution are
/// never split, even when a `$VAR` expands to text with spaces.
///
/// Exit-code semantics: a script's exit code is the last executed node's
/// code; an `if` with a false condition and no `else` yields 0, as does a
/// `for` over an empty word list.
///
/// Guards: command substitution nests at most [maxSubstitutionDepth] levels,
/// a `for` loop iterates at most [maxForIterations] times — both fail with a
/// clean error instead of hanging.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'package:fa/sandbox/shell_parser.dart';

/// Maximum nesting depth for command substitution (`$(echo $(echo ...))`).
const maxSubstitutionDepth = 8;

/// Maximum number of `for` loop iterations.
const maxForIterations = 10000;

/// Runs the command substitution [source], returning captured stdout with
/// trailing newlines trimmed.
typedef SubstitutionRunner =
    Future<Result<String, ExecutionError>> Function(String source);

/// Host callbacks the interpreter needs from a concrete shell. Closure-based
/// so `WasiSandboxShell` and `MemoryShell` wire their private machinery
/// without a bespoke adapter class.
final class ShellScriptRunner {
  /// Creates a runner from shell callbacks.
  const ShellScriptRunner({
    required this.runPipeline,
    required this.environment,
    required this.setVariable,
    required this.capture,
    required this.saveOutputs,
    required this.restoreOutputs,
  });

  /// Runs one pipeline; stdout/stderr flow through the shell's normal
  /// capture. [depth] is the current substitution nesting depth.
  final Future<Result<int, ExecutionError>> Function(
    Pipeline pipeline,
    ShellExecOptions? options,
    int depth,
  )
  runPipeline;

  /// Effective environment for `$VAR` expansion.
  final Map<String, String> Function(ShellExecOptions? options) environment;

  /// Sets a shell variable (loop variables, assignments).
  final void Function(String name, String value) setVariable;

  /// Stack of substitution capture buffers fed by the pipeline runner.
  final ShellOutputCapture capture;

  /// Snapshots the shell's last-output state before a substitution.
  final ShellOutputSnapshot Function() saveOutputs;

  /// Restores the shell's last-output state after a substitution.
  final void Function(ShellOutputSnapshot snapshot) restoreOutputs;

  /// Runs a nested command substitution (public surface for shells).
  Future<Result<String, ExecutionError>> substitute(
    String source,
    ShellExecOptions? options,
    int depth,
  ) => runSubstitutionScript(source, this, options, depth);
}

/// Snapshot of a shell's last-stdout/last-stderr state.
final class ShellOutputSnapshot {
  /// Creates a snapshot.
  const ShellOutputSnapshot({this.stdout, this.stderr});

  /// Last stdout text.
  final String? stdout;

  /// Last stderr text.
  final String? stderr;
}

/// Stack of stdout capture buffers for nested command substitutions.
///
/// The pipeline runner calls [feed] with every stdout text that is NOT
/// redirected to a file; while a capture is active the text lands in the
/// innermost buffer instead of being shown to the user.
final class ShellOutputCapture {
  final List<StringBuffer> _stack = [];

  /// Whether a capture is currently active (substitution in progress).
  bool get isActive => _stack.isNotEmpty;

  /// Current nesting depth of captures.
  int get depth => _stack.length;

  /// Pushes a new capture buffer.
  void begin() => _stack.add(StringBuffer());

  /// Appends stdout text to the innermost buffer, if any.
  void feed(String text) {
    if (_stack.isNotEmpty) _stack.last.write(text);
  }

  /// Pops the innermost buffer and returns its content with trailing
  /// newlines trimmed (POSIX `$(...)` semantics).
  String end() {
    var text = _stack.removeLast().toString();
    while (text.endsWith('\n')) {
      text = text.substring(0, text.length - 1);
    }
    return text;
  }

  /// Pops buffers until the stack is back at [mark] (error cleanup).
  void abortTo(int mark) {
    while (_stack.length > mark) {
      _stack.removeLast();
    }
  }
}

/// Runs [script] to completion, returning the last executed node's exit code.
Future<Result<int, ExecutionError>> runShellScript(
  ShellScript script,
  ShellScriptRunner runner,
  ShellExecOptions? options,
) => runShellScriptNodes(script.nodes, runner, options, 0);

/// Runs a statement list, honoring `&&`/`||` short-circuiting and the cancel
/// token. [depth] is the command substitution nesting depth.
Future<Result<int, ExecutionError>> runShellScriptNodes(
  List<ScriptNode> nodes,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  var exitCode = 0;
  for (final node in nodes) {
    if (node.operator == StatementOperator.and && exitCode != 0) continue;
    if (node.operator == StatementOperator.or && exitCode == 0) continue;
    final result = await _runNode(node, runner, options, depth);
    if (result.isErr) return Err(result.errorOrNull!);
    exitCode = result.valueOrNull!;
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
  }
  return Ok(exitCode);
}

/// Runs [source] as a nested command substitution at [depth], capturing its
/// stdout (trailing newlines trimmed) and restoring the shell's last-output
/// state afterwards.
Future<Result<String, ExecutionError>> runSubstitutionScript(
  String source,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  if (depth >= maxSubstitutionDepth) {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.unknown,
        'command substitution nested too deeply (max $maxSubstitutionDepth)',
      ),
    );
  }
  late final ShellScript script;
  try {
    script = parseShellScript(source);
  } on ShellParseException catch (e) {
    return Err(
      ExecutionError(
        ExecutionErrorCode.unknown,
        'parse error in command substitution: $e',
      ),
    );
  }
  final saved = runner.saveOutputs();
  final mark = runner.capture.depth;
  runner.capture.begin();
  try {
    final result = await runShellScriptNodes(
      script.nodes,
      runner,
      options,
      depth + 1,
    );
    if (result.isErr) return Err(result.errorOrNull!);
    return Ok(runner.capture.end());
  } finally {
    runner.capture.abortTo(mark);
    runner.restoreOutputs(saved);
  }
}

Future<Result<int, ExecutionError>> _runNode(
  ScriptNode node,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) => switch (node) {
  ScriptPipeline() => _runPipelineNode(node, runner, options, depth),
  ScriptIf() => _runIf(node, runner, options, depth),
  ScriptFor() => _runFor(node, runner, options, depth),
};

Future<Result<int, ExecutionError>> _runPipelineNode(
  ScriptPipeline node,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) {
  if (_isAssignment(node.pipeline)) {
    return _runAssignment(node.pipeline, runner, options, depth);
  }
  return runner.runPipeline(node.pipeline, options, depth);
}

Future<Result<int, ExecutionError>> _runIf(
  ScriptIf node,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  for (final branch in node.branches) {
    final cond = await runShellScriptNodes(
      branch.condition,
      runner,
      options,
      depth,
    );
    if (cond.isErr) return Err(cond.errorOrNull!);
    if (cond.valueOrNull! == 0) {
      return runShellScriptNodes(branch.body, runner, options, depth);
    }
  }
  final elseBody = node.elseBody;
  if (elseBody == null) return const Ok(0);
  return runShellScriptNodes(elseBody, runner, options, depth);
}

Future<Result<int, ExecutionError>> _runFor(
  ScriptFor node,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  final words = <String>[];
  for (final word in node.words) {
    final expanded = await _expandForWord(word, runner, options, depth);
    if (expanded.isErr) return Err(expanded.errorOrNull!);
    words.addAll(expanded.valueOrNull!);
  }
  if (words.length > maxForIterations) {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.unknown,
        'for loop exceeds $maxForIterations iterations',
      ),
    );
  }
  var exitCode = 0;
  for (final word in words) {
    runner.setVariable(node.variable, word);
    final result = await runShellScriptNodes(node.body, runner, options, depth);
    if (result.isErr) return Err(result.errorOrNull!);
    exitCode = result.valueOrNull!;
    final token = options?.cancelToken;
    if (token != null && token.isCancelled) {
      return const Err(ExecutionError(ExecutionErrorCode.aborted, 'aborted'));
    }
  }
  return Ok(exitCode);
}

Future<Result<List<String>, ExecutionError>> _expandForWord(
  ScriptWord word,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  if (!word.expandable) return Ok([word.value]);
  final expanded = await expandShellWord(
    word.value,
    runner.environment(options),
    (source) => runner.substitute(source, options, depth),
  );
  if (expanded.isErr) return Err(expanded.errorOrNull!);
  final result = expanded.valueOrNull!;
  if (word.quoted || !result.hadSubstitution) return Ok([result.text]);
  return Ok(splitSubstitutionFields(result.text));
}

/// Whether [pipeline] is a plain `NAME=value` assignment statement (single
/// stage, no redirects, every word a `NAME=` prefix).
bool _isAssignment(Pipeline pipeline) {
  if (pipeline.stages.length != 1) return false;
  final stage = pipeline.stages.single;
  if (stage.redirects.isNotEmpty) return false;
  return stage.argv.every(_isAssignmentWord);
}

bool _isAssignmentWord(String word) {
  final eq = word.indexOf('=');
  if (eq <= 0) return false;
  return _isIdentifierName(word.substring(0, eq));
}

bool _isIdentifierName(String name) {
  if (name.isEmpty) return false;
  for (var i = 0; i < name.length; i++) {
    final c = name.codeUnitAt(i);
    final ok =
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 95;
    if (!ok || (i == 0 && c >= 48 && c <= 57)) return false;
  }
  return true;
}

/// Executes a `NAME=value` assignment statement: values are expanded
/// (including command substitution) but never word-split, and stored through
/// [ShellScriptRunner.setVariable]. Exit code 0.
Future<Result<int, ExecutionError>> _runAssignment(
  Pipeline pipeline,
  ShellScriptRunner runner,
  ShellExecOptions? options,
  int depth,
) async {
  final stage = pipeline.stages.single;
  final env = runner.environment(options);
  for (var k = 0; k < stage.argv.length; k++) {
    final word = stage.argv[k];
    final eq = word.indexOf('=');
    var value = word.substring(eq + 1);
    if (stage.isExpandable(k)) {
      final expanded = await expandShellWord(
        value,
        env,
        (source) => runner.substitute(source, options, depth),
      );
      if (expanded.isErr) return Err(expanded.errorOrNull!);
      value = expanded.valueOrNull!.text;
    }
    runner.setVariable(word.substring(0, eq), value);
  }
  return const Ok(0);
}

/// Splits an unquoted substitution result into fields on whitespace,
/// dropping empty fields.
List<String> splitSubstitutionFields(String text) =>
    text.split(RegExp(r'\s+')).where((field) => field.isNotEmpty).toList();

/// Result of expanding one word: the expanded [text] and whether it
/// contained a command substitution (drives the splitting rule).
final class ExpandedWord {
  /// Creates an expansion result.
  const ExpandedWord(this.text, {required this.hadSubstitution});

  /// Expanded text.
  final String text;

  /// Whether the word contained a command substitution.
  final bool hadSubstitution;
}

/// Expands `$NAME`, `${NAME}`, `$(...)` and backquotes in [input] using
/// [env] and [substitute]. Unknown variables expand to the empty string;
/// other `$` forms are kept literal.
Future<Result<ExpandedWord, ExecutionError>> expandShellWord(
  String input,
  Map<String, String> env,
  SubstitutionRunner substitute,
) async {
  final buffer = StringBuffer();
  var hadSubstitution = false;
  var i = 0;
  while (i < input.length) {
    final ch = input[i];
    final isSubst =
        (ch == '\$' && i + 1 < input.length && input[i + 1] == '(') ||
        ch == '`';
    if (!isSubst) {
      i = _expandPlainAt(input, i, env, buffer);
      continue;
    }
    final end = substitutionSpanEnd(input, i);
    if (end == -1) {
      // Unbalanced (e.g. an escaped backquote): keep literal.
      buffer.write(ch);
      i++;
      continue;
    }
    final inner = ch == '`'
        ? input.substring(i + 1, end - 1)
        : input.substring(i + 2, end - 1);
    final result = await substitute(inner);
    if (result.isErr) return Err(result.errorOrNull!);
    buffer.write(result.valueOrNull!);
    hadSubstitution = true;
    i = end;
  }
  return Ok(ExpandedWord(buffer.toString(), hadSubstitution: hadSubstitution));
}

/// Expands a single plain (non-substitution) character or `$VAR` reference
/// at [i], returning the new index.
int _expandPlainAt(
  String input,
  int i,
  Map<String, String> env,
  StringBuffer buffer,
) {
  final ch = input[i];
  if (ch != '\$') {
    buffer.write(ch);
    return i + 1;
  }
  if (i + 1 >= input.length) {
    buffer.write('\$');
    return i + 1;
  }
  final next = input[i + 1];
  if (next == '{') {
    final end = input.indexOf('}', i + 2);
    if (end == -1) {
      buffer.write('\${');
      return i + 2;
    }
    buffer.write(env[input.substring(i + 2, end)] ?? '');
    return end + 1;
  }
  final code = next.codeUnitAt(0);
  final isVarStart =
      (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;
  if (!isVarStart) {
    buffer.write('\$');
    return i + 1;
  }
  var j = i + 1;
  while (j < input.length) {
    final c = input.codeUnitAt(j);
    final isVarChar =
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 95;
    if (!isVarChar) break;
    j++;
  }
  buffer.write(env[input.substring(i + 1, j)] ?? '');
  return j;
}

/// Applies `$VAR`/`$(...)` expansion to a parsed [stage] using [env],
/// honoring the per-word `expandable` and `quoted` flags set by the parser.
/// Unquoted words containing a substitution are word-split afterwards;
/// redirect targets are expanded but never split.
Future<Result<Stage, ExecutionError>> expandShellStage(
  Stage stage,
  Map<String, String> env,
  SubstitutionRunner substitute,
) async {
  final argv = <String>[];
  for (var k = 0; k < stage.argv.length; k++) {
    final word = stage.argv[k];
    if (!stage.isExpandable(k)) {
      argv.add(word);
      continue;
    }
    final expanded = await expandShellWord(word, env, substitute);
    if (expanded.isErr) return Err(expanded.errorOrNull!);
    final result = expanded.valueOrNull!;
    if (result.hadSubstitution && !stage.isQuoted(k)) {
      argv.addAll(splitSubstitutionFields(result.text));
    } else {
      argv.add(result.text);
    }
  }
  if (argv.isEmpty) argv.add(''); // degenerate: substitution ate every word
  final redirects = <Redirect>[];
  for (final redirect in stage.redirects) {
    var target = redirect.target;
    if (redirect.expandable) {
      final expanded = await expandShellWord(target, env, substitute);
      if (expanded.isErr) return Err(expanded.errorOrNull!);
      target = expanded.valueOrNull!.text;
    }
    redirects.add(
      Redirect(kind: redirect.kind, fd: redirect.fd, target: target),
    );
  }
  return Ok(
    Stage(command: argv.first, args: argv.sublist(1), redirects: redirects),
  );
}
