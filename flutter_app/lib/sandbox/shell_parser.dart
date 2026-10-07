// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Minimal POSIX-like shell parser for the WASM sandbox.
///
/// Supports enough syntax for typical agent commands:
///   - pipelines: `cat a | sort | head`
///   - logical operators: `a && b`, `a || b`
///   - statement separators: `a ; b` (a newline acts like `;`)
///   - redirects: `> file`, `>> file`, `< file`, `2> file`, `2>> file`, `&> file`
///   - single and double quoting and backslash escapes.
///   - control flow via [parseShellScript]: `if ...; then ...; fi` (with
///     `elif`/`else`) and `for NAME in ...; do ...; done`, on one line or
///     spread over multiple lines.
///   - command substitution: `$(...)` and backquotes are kept RAW inside the
///     word text (the tokenizer only validates that they are balanced); the
///     shell executes them at expansion time.
///
/// Words carry an [expandable] flag: it is false when any part of the word
/// came from single quotes or a `\$` escape, in which case the shell must not
/// apply `$VAR` expansion to it. Words also carry a `quoted` flag that is
/// true when the word came from a double-quoted section; the shell uses it to
/// suppress word-splitting of command substitution results. Expansion is
/// applied by the shell at execution time (so `export A=1 && echo $A` works),
/// not by this parser.
library;

/// Parsed shell command line, split into statements.
final class ShellCommand {
  /// Creates a parsed command line.
  const ShellCommand(this.statements);

  /// Top-level statements separated by `;`, `&&`, or `||`.
  final List<Statement> statements;
}

/// One statement that evaluates to an exit code.
final class Statement {
  /// Creates a statement with the operator that links it to the previous one.
  const Statement(this.pipeline, {this.operator = StatementOperator.none});

  /// Pipeline to run.
  final Pipeline pipeline;

  /// How this statement relates to the previous statement.
  final StatementOperator operator;
}

/// Statement-level operators.
enum StatementOperator {
  /// First statement or after `;`.
  none,

  /// Short-circuit on success (`&&`).
  and,

  /// Short-circuit on failure (`||`).
  or,
}

/// A pipeline of stages connected by `|`.
final class Pipeline {
  /// Creates a pipeline.
  const Pipeline(this.stages);

  /// Stages evaluated left-to-right.
  final List<Stage> stages;
}

/// A single command stage with arguments and redirects.
final class Stage {
  /// Creates a stage.
  const Stage({
    required this.command,
    required this.args,
    this.redirects = const [],
    this.argExpandable = const [],
    this.argQuoted = const [],
  });

  /// Command name (first word).
  final String command;

  /// Arguments following the command name.
  final List<String> args;

  /// File redirects attached to this stage.
  final List<Redirect> redirects;

  /// Whether each element of [argv] allows `$VAR` expansion. False for words
  /// that came from single quotes or `\$` escapes. Empty means every word is
  /// expandable.
  final List<bool> argExpandable;

  /// Whether each element of [argv] came from a double-quoted section; the
  /// shell uses it to suppress word-splitting of command substitution
  /// results. Empty means no word is quoted.
  final List<bool> argQuoted;

  /// All tokens including command and arguments, convenient for callers.
  List<String> get argv => [command, ...args];

  /// Whether argv element [index] allows `$VAR` expansion.
  bool isExpandable(int index) {
    if (index < 0 || index >= argv.length) return true;
    if (index >= argExpandable.length) return true;
    return argExpandable[index];
  }

  /// Whether argv element [index] came from a double-quoted section.
  bool isQuoted(int index) {
    if (index < 0 || index >= argv.length) return false;
    if (index >= argQuoted.length) return false;
    return argQuoted[index];
  }
}

/// A file redirect attached to a stage.
final class Redirect {
  /// Creates a redirect.
  const Redirect({
    required this.kind,
    required this.fd,
    required this.target,
    this.expandable = true,
    this.body,
  });

  /// Redirect kind.
  final RedirectKind kind;

  /// File descriptor: `0` stdin, `1` stdout, `2` stderr, `-1` stdout+stderr.
  final int fd;

  /// Target file path inside the sandbox; for [RedirectKind.heredoc] and
  /// [RedirectKind.hereString] this is the delimiter / source word instead.
  final String target;

  /// Whether [target] allows `$VAR` expansion. For a heredoc it also
  /// decides whether [body] undergoes `$VAR`/`$(...)` expansion (false when
  /// the delimiter was quoted, POSIX).
  final bool expandable;

  /// The captured here-document body (raw at parse time; expanded by the
  /// shell's expansion pass when [expandable]). Null for file redirects and
  /// here-strings (whose text lives in [target]).
  final String? body;
}

/// Kinds of redirect.
enum RedirectKind {
  read,
  write,
  append,
  heredoc,
  hereString,
  background,

  /// `2>&1` / `>&2` fd duplication ([fd] is the source fd, [Redirect.target]
  /// the destination fd as '1' or '2'). Only honored by shells that opt in
  /// via `allowFdDuplication` — the sandbox shells historically reject it.
  dup,
}

/// A parsed shell script: statements plus control-flow nodes.
final class ShellScript {
  /// Creates a parsed script.
  const ShellScript(this.nodes);

  /// Top-level nodes in source order.
  final List<ScriptNode> nodes;
}

/// One executable node of a [ShellScript].
sealed class ScriptNode {
  /// Creates a node with the operator linking it to the previous node.
  const ScriptNode({this.operator = StatementOperator.none});

  /// How this node relates to the previous node (`&&` / `||` / none).
  final StatementOperator operator;
}

/// A plain pipeline node.
final class ScriptPipeline extends ScriptNode {
  /// Creates a pipeline node.
  const ScriptPipeline(this.pipeline, {super.operator});

  /// The pipeline to run.
  final Pipeline pipeline;
}

/// An `if ...; then ...; fi` node, truth = condition exit code 0.
final class ScriptIf extends ScriptNode {
  /// Creates an if node; [elseBody] is null when there is no `else`.
  const ScriptIf(this.branches, this.elseBody, {super.operator});

  /// `if`/`elif` branches in source order.
  final List<ScriptBranch> branches;

  /// Statements of the `else` branch, or null.
  final List<ScriptNode>? elseBody;
}

/// One `if`/`elif` branch: [condition] statements (truth = last exit code 0)
/// and the [body] to run when the condition holds.
final class ScriptBranch {
  /// Creates a branch.
  const ScriptBranch(this.condition, this.body);

  /// Condition statements.
  final List<ScriptNode> condition;

  /// Body statements.
  final List<ScriptNode> body;
}

/// A `for NAME in ...; do ...; done` node.
final class ScriptFor extends ScriptNode {
  /// Creates a for node.
  const ScriptFor(this.variable, this.words, this.body, {super.operator});

  /// Loop variable name.
  final String variable;

  /// Words to iterate over (expanded at execution time).
  final List<ScriptWord> words;

  /// Body statements.
  final List<ScriptNode> body;
}

/// A raw `for`-list word with its expansion flags.
final class ScriptWord {
  /// Creates a word.
  const ScriptWord(this.value, {this.expandable = true, this.quoted = false});

  /// Raw word text (may contain `$VAR` / `$(...)`).
  final String value;

  /// Whether `$VAR`/`$(...)` expansion applies.
  final bool expandable;

  /// Whether the word came from a double-quoted section (no splitting).
  final bool quoted;
}

/// Parses [input] into a [ShellCommand].
///
/// Throws [ShellParseException] on malformed input, and on control-flow
/// keywords — use [parseShellScript] for `if`/`for` support.
ShellCommand parseCommandLine(String input) {
  final script = parseShellScript(input);
  return ShellCommand([
    for (final node in script.nodes)
      if (node is ScriptPipeline)
        Statement(node.pipeline, operator: node.operator)
      else
        throw const ShellParseException(
          'if/for control flow requires parseShellScript',
        ),
  ]);
}

/// Parses [input] into a [ShellScript] supporting `if`/`elif`/`else`/`fi`
/// and `for ... in ...; do ...; done` control flow, on one line or spread
/// over multiple lines.
///
/// [allowFdDuplication] opts the caller into `2>&1`/`>&2` support (the WASI
/// sandbox shell); the default keeps the historical rejection so shells
/// that never supported fd duplication are byte-identical.
///
/// Throws [ShellParseException] on malformed input: unterminated blocks
/// (the message names the missing keyword), stray `then`/`else`/`fi`/`do`/
/// `done` keywords, or invalid `for` syntax.
ShellScript parseShellScript(String input, {bool allowFdDuplication = false}) {
  final tokens = _tokenize(input);
  return _ScriptParser(tokens, allowFdDuplication: allowFdDuplication)
      .parseScript();
}

/// Exception thrown by [parseCommandLine] for invalid syntax.
final class ShellParseException implements Exception {
  /// Creates a parse exception.
  const ShellParseException(this.message);

  /// Human readable error.
  final String message;

  @override
  String toString() => 'ShellParseException: $message';
}

/// Internal token representation.
sealed class _Token {}

final class _Word extends _Token {
  _Word(this.value, {this.expandable = true, this.quoted = false});
  final String value;

  /// False when any part of the word came from single quotes or a `\$`
  /// escape: the shell must not apply `$VAR` expansion to it.
  final bool expandable;

  /// True when the word came from a double-quoted section: the shell must
  /// not word-split command substitution results in it.
  final bool quoted;
}

final class _Operator extends _Token {
  _Operator(this.value);
  final String value;
}

final class _Redirect extends _Token {
  _Redirect(this.fd, this.kind);
  final int fd;
  final RedirectKind kind;
}

/// A here-document operator (`<<DELIM` / `<<-DELIM`). The delimiter word
/// follows as a normal word token; [body] is filled in when the tokenizer
/// crosses the newline ending the command line (POSIX: bodies start on the
/// next line, captured in operator order).
final class _Heredoc extends _Token {
  _Heredoc(this.fd, {required this.stripTabs});

  final int fd;

  /// `<<-` form: strip leading TABs from body and delimiter lines.
  final bool stripTabs;

  /// Captured body (set by [_captureHeredocs]).
  String? body;
}

List<_Token> _tokenize(String input) {
  final tokens = <_Token>[];
  final buffer = StringBuffer();
  var i = 0;
  var wordExpandable = true;
  var wordQuoted = false;
  final pendingHeredocs = <_Heredoc>[];

  void flushWord() {
    if (buffer.isEmpty) return;
    tokens.add(
      _Word(buffer.toString(), expandable: wordExpandable, quoted: wordQuoted),
    );
    buffer.clear();
    wordExpandable = true;
    wordQuoted = false;
  }

  String peek() => i + 1 < input.length ? input[i + 1] : '';

  while (i < input.length) {
    final ch = input[i];

    if (ch == '\\' && i + 1 < input.length) {
      // `\$` produces a literal dollar sign: the word must not be expanded
      // later by the shell.
      if (input[i + 1] == '\$') wordExpandable = false;
      buffer.write(input[i + 1]);
      i += 2;
      continue;
    }

    // Command substitution: `$(...)` and backquotes are kept RAW in the word
    // text (balanced/quoted regions honored); the shell executes them at
    // expansion time. Single quotes below never reach this branch.
    if ((ch == '\$' && peek() == '(') || ch == '`') {
      _rejectArithmeticExpansion(input, i);
      i = _scanSubstitution(input, i, buffer);
      continue;
    }

    if (ch == "'") {
      // No flush at the quote boundary: POSIX glues adjacent fragments into
      // one word (`X="a b"` is ONE word, `a'b'` is `ab`). The word ends at
      // the next unquoted separator.
      wordExpandable = false;
      wordQuoted = true;
      i = _scanSingleQuote(input, i, buffer);
      continue;
    }

    if (ch == '"') {
      wordQuoted = true;
      final (end, expandable) = _scanDoubleQuote(input, i + 1, buffer);
      if (!expandable) wordExpandable = false;
      i = end + 1; // skip closing quote — the word continues until a separator
      continue;
    }

    if (ch == ' ' || ch == '\t' || ch == '\r') {
      flushWord();
      i++;
      continue;
    }

    // A newline separates statements exactly like `;`. Pending here-docs
    // capture their bodies from the FOLLOWING lines first (POSIX): the
    // body text is never tokenized as shell syntax.
    if (ch == '\n') {
      flushWord();
      var next = i + 1;
      if (pendingHeredocs.isNotEmpty) {
        next = _captureHeredocs(input, i + 1, pendingHeredocs, tokens);
        pendingHeredocs.clear();
      }
      tokens.add(_Operator(';'));
      i = next;
      continue;
    }

    // Process substitution `<(cmd)` / `>(cmd)` is not supported (gh-1086).
    _rejectProcessSubstitution(input, i);

    // Here-documents / here-strings: `<<DELIM`, `<<-DELIM`, `<<<word`.
    final heredocOp = _scanHeredocOperator(input, i);
    if (heredocOp != null) {
      flushWord();
      tokens.addAll(heredocOp.$1);
      pendingHeredocs.addAll(heredocOp.$1.whereType<_Heredoc>());
      i = heredocOp.$2;
      continue;
    }

    // Shell metacharacters always start a new token, even when they touch a
    // previous word (e.g. `a; b`, `echo>file`).
    final meta = _metaToken(input, i);
    if (meta != null) {
      flushWord();
      tokens.addAll(meta.$1);
      i = meta.$2;
      continue;
    }

    // File-descriptor redirects: N> N>> N>&1 (basic forms); a digit run
    // that is not a redirect joins the word buffer.
    if (_isDigit(ch)) {
      final (added, next) = _scanDigits(input, i);
      if (added.isNotEmpty) {
        tokens.addAll(added);
        pendingHeredocs.addAll(added.whereType<_Heredoc>());
      } else {
        buffer.write(input.substring(i, next));
      }
      i = next;
      continue;
    }

    buffer.write(ch);
    i++;
  }
  flushWord();
  if (pendingHeredocs.isNotEmpty) {
    // The input ended on the command line itself: no body line exists.
    final delim = _heredocDelimiter(pendingHeredocs.first, tokens);
    throw ShellParseException(
      "unterminated here-document (delimiter '$delim')",
    );
  }
  return tokens;
}

/// `$((` (arithmetic expansion) is rejected at the tokenizer level
/// (gh-1086 AC5): it used to misparse into garbage output. Called at every
/// `$( `- or backquote-position so the message names the construct.
void _rejectArithmeticExpansion(String input, int i) {
  if (input[i] == '\$' && i + 2 < input.length && input[i + 2] == '(') {
    throw const ShellParseException(
      'arithmetic expansion \$((...)) is not supported in the sandbox shell',
    );
  }
}

/// `<(cmd)` / `>(cmd)` (process substitution) is rejected at the tokenizer
/// level (gh-1086 AC5): it used to fold into a `<`/`>` file redirect and
/// read/write a file literally named `(...`.
void _rejectProcessSubstitution(String input, int i) {
  final ch = input[i];
  if ((ch == '<' || ch == '>') && i + 1 < input.length && input[i + 1] == '(') {
    throw const ShellParseException(
      'process substitution <(...) / >(...) is not supported in the sandbox shell',
    );
  }
}

/// Scans a here-document / here-string operator (`<<DELIM`, `<<-DELIM`,
/// `<<<word`) at [i]; returns the emitted tokens and the index just past
/// the operator, or null when [i] does not hold one. The here-document
/// token registers as pending — its body is captured by [_captureHeredocs]
/// when the tokenizer crosses the newline ending the command line.
(List<_Token>, int)? _scanHeredocOperator(String input, int i) {
  if (input[i] != '<' || i + 1 >= input.length || input[i + 1] != '<') {
    return null;
  }
  if (i + 2 < input.length && input[i + 2] == '<') {
    return (<_Token>[_Redirect(0, RedirectKind.hereString)], i + 3);
  }
  final strip = i + 2 < input.length && input[i + 2] == '-';
  return (<_Token>[_Heredoc(0, stripTabs: strip)], i + (strip ? 3 : 2));
}

/// Captures the bodies of [pending] here-documents from [input] starting
/// at [start] (just past the newline ending their command line) and
/// returns the index just past the last delimiter line. Bodies are raw
/// text — never tokenized. The delimiter of each pending operator is the
/// word token immediately following it in [tokens].
int _captureHeredocs(
  String input,
  int start,
  List<_Heredoc> pending,
  List<_Token> tokens,
) {
  var i = start;
  for (final heredoc in pending) {
    final delim = _heredocDelimiter(heredoc, tokens);
    final body = StringBuffer();
    while (true) {
      if (i >= input.length) {
        throw ShellParseException(
          "unterminated here-document (delimiter '$delim')",
        );
      }
      var end = input.indexOf('\n', i);
      final hasNewline = end != -1;
      if (!hasNewline) end = input.length;
      var line = input.substring(i, end);
      // Pragmatic CRLF: a carriage return is never part of the payload.
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final compare = heredoc.stripTabs ? _stripLeadingTabs(line) : line;
      i = hasNewline ? end + 1 : end;
      if (compare == delim) break;
      body.write(compare);
      if (hasNewline) body.write('\n');
    }
    heredoc.body = body.toString();
  }
  return i;
}

/// The delimiter word of [heredoc]: the token right after it.
String _heredocDelimiter(_Heredoc heredoc, List<_Token> tokens) {
  final index = tokens.indexOf(heredoc);
  final next = index + 1 < tokens.length ? tokens[index + 1] : null;
  if (next is! _Word) {
    throw const ShellParseException('missing here-document delimiter');
  }
  return next.value;
}

String _stripLeadingTabs(String line) {
  var i = 0;
  while (i < line.length && line[i] == '\t') {
    i++;
  }
  return line.substring(i);
}

/// Consumes a raw command-substitution span (`$(...)` or a backquote pair)
/// into [buffer]; throws on an unbalanced span.
int _scanSubstitution(String input, int i, StringBuffer buffer) {
  final end = substitutionSpanEnd(input, i);
  if (end == -1) {
    throw ShellParseException(
      input[i] == '`' ? 'unmatched `' : 'unmatched \$(',
    );
  }
  buffer.write(input.substring(i, end));
  return end;
}

/// Consumes a single-quoted span starting at the opening quote at [i];
/// returns the index just past the closing quote. No escapes exist inside
/// single quotes.
int _scanSingleQuote(String input, int i, StringBuffer buffer) {
  i++;
  while (i < input.length && input[i] != "'") {
    buffer.write(input[i]);
    i++;
  }
  if (i >= input.length) throw const ShellParseException("unmatched '");
  return i + 1; // skip closing quote
}

/// Consumes a double-quoted span starting just after the opening quote;
/// returns the index of the closing quote and whether the word stays
/// expandable (a `\$` escape makes it literal).
/// POSIX double-quote escapes: `\"` `\\` `\$` `` \` `` `\<newline>`; any
/// other backslash pair is literal. Command substitution inside double
/// quotes is kept as a raw span so inner quotes do not terminate the
/// quoted section.
(int, bool) _scanDoubleQuote(String input, int i, StringBuffer buffer) {
  var expandable = true;
  while (i < input.length && input[i] != '"') {
    if (input[i] == '\\' && i + 1 < input.length) {
      final next = input[i + 1];
      if (next == '"' ||
          next == '\\' ||
          next == '\$' ||
          next == '`' ||
          next == '\n') {
        if (next == '\$') expandable = false;
        buffer.write(next);
        i += 2;
      } else {
        // Backslash is literal for any other following character.
        buffer.write('\\');
        buffer.write(next);
        i += 2;
      }
    } else if ((input[i] == '\$' &&
            i + 1 < input.length &&
            input[i + 1] == '(') ||
        input[i] == '`') {
      _rejectArithmeticExpansion(input, i);
      i = _scanSubstitution(input, i, buffer);
    } else {
      buffer.write(input[i]);
      i++;
    }
  }
  if (i >= input.length) throw const ShellParseException('unmatched "');
  return (i, expandable);
}

/// Tokenizes a metacharacter (`|` `&` `;` `>` `<` and their doubled /
/// appending forms) at [i]; returns the tokens and the new index, or null
/// when [i] does not hold a metacharacter.
(List<_Token>, int)? _metaToken(String input, int i) {
  final ch = input[i];
  if (ch != '|' && ch != '&' && ch != ';' && ch != '>' && ch != '<') {
    return null;
  }
  String peek() => i + 1 < input.length ? input[i + 1] : '';
  _Token token;
  if (ch == '|' && peek() == '|') {
    token = _Operator('||');
    i += 2;
  } else if (ch == '&' && peek() == '&') {
    token = _Operator('&&');
    i += 2;
  } else if (ch == '|') {
    token = _Operator('|');
    i += 1;
  } else if (ch == ';') {
    token = _Operator(';');
    i += 1;
  } else if (ch == '&' && peek() == '>') {
    if (i + 2 < input.length && input[i + 2] == '>') {
      token = _Redirect(-1, RedirectKind.append);
      i += 3;
    } else {
      token = _Redirect(-1, RedirectKind.write);
      i += 2;
    }
  } else if (ch == '>' && peek() == '>') {
    token = _Redirect(1, RedirectKind.append);
    i += 2;
  } else if (ch == '>') {
    token = _Redirect(1, RedirectKind.write);
    i += 1;
  } else if (ch == '&') {
    // Bare `&` — background execution, rejected with a precise message by
    // the stage parser (gh-1086 AC5).
    token = _Redirect(-1, RedirectKind.background);
    i += 1;
  } else {
    token = _Redirect(0, RedirectKind.read);
    i += 1;
  }
  return ([token], i);
}

/// Scans a digit run at [i]: a redirect (`N>`, `N>>`, `N<`) yields its
/// token and the index past it; a plain digit run yields no tokens and the
/// index past the run (the caller folds the digits into the word buffer).
(List<_Token>, int) _scanDigits(String input, int i) {
  var j = i;
  while (j < input.length && _isDigit(input[j])) {
    j++;
  }
  final number = input.substring(i, j);
  if (j < input.length && (input[j] == '>' || input[j] == '<')) {
    final fd = int.parse(number);
    // fd-prefixed process substitution `2>(cmd)` / `2<(cmd)` — the main
    // loop's `<(`/`>(` guard never sees these (gh-1086 review).
    if (j + 1 < input.length && input[j + 1] == '(') {
      throw const ShellParseException(
        'process substitution <(...) / >(...) is not supported in the sandbox shell',
      );
    }
    if (input[j] == '>' && j + 1 < input.length && input[j + 1] == '>') {
      return ([_Redirect(fd, RedirectKind.append)], j + 2);
    }
    if (input[j] == '>') return ([_Redirect(fd, RedirectKind.write)], j + 1);
    // fd-prefixed here-document: `3<<DELIM` / `3<<-DELIM` (gh-1086).
    if (input[j] == '<' && j + 1 < input.length && input[j + 1] == '<') {
      if (j + 2 < input.length && input[j + 2] == '<') {
        throw const ShellParseException(
          'fd-prefixed here-strings (3<<<word) are not supported; '
          'use plain <<<word',
        );
      }
      final strip = j + 2 < input.length && input[j + 2] == '-';
      return ([_Heredoc(fd, stripTabs: strip)], j + (strip ? 3 : 2));
    }
    return ([_Redirect(fd, RedirectKind.read)], j + 1);
  }
  return (const <_Token>[], j);
}

bool _isDigit(String ch) =>
    ch.length == 1 && ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

/// Fail-fast guards (gh-1086 AC5): constructs the sandbox shell cannot
/// honor must throw a NAMED parse error instead of silently producing
/// wrong output.
final _assignmentWord = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');
const _reservedWords = {'while', 'until', 'case', 'select', 'function'};

final _braceExpansion = RegExp(r'\{[^{}]*,[^{}]*\}');

/// ASCII identifier char class: `[A-Za-z_]` (pure, issue #568).
bool _isIdentifierStart(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;

/// ASCII identifier continuation: [isIdentifierStart] plus digits.
bool _isIdentifierPart(int code) =>
    _isIdentifierStart(code) || (code >= 48 && code <= 57);

/// `true` when [value] is a POSIX-ish shell identifier: `[A-Za-z_]
/// [A-Za-z0-9_]*`. Public for the shell_parser tables (same util tier as
/// [substitutionSpanEnd]).
bool isIdentifier(String value) {
  if (value.isEmpty || !_isIdentifierStart(value.codeUnitAt(0))) return false;
  return value.codeUnits.skip(1).every(_isIdentifierPart);
}

/// Returns the index just past the closing `)` or backquote of the command
/// substitution starting at [start] (the `$` of `$(` or a backquote), or -1
/// when unterminated. Nested `$(...)`, quotes, and backslash escapes are
/// honored. Shared by the tokenizer (which throws on -1) and the shells'
/// expansion pass (which then keeps the span literal).
int substitutionSpanEnd(String input, int start) {
  if (input[start] == '`') return _backquoteSpanEnd(input, start);
  var depth = 1;
  var i = start + 2;
  while (i < input.length) {
    final ch = input[i];
    if (ch == '\\') {
      i += 2;
      continue;
    }
    if (ch == "'" || ch == '"') {
      i = _quotedSpanEnd(input, i, ch);
      if (i == -1) return -1;
      continue;
    }
    if (ch == '`') {
      i = _backquoteSpanEnd(input, i);
      if (i == -1) return -1;
      continue;
    }
    if (ch == '\$' && i + 1 < input.length && input[i + 1] == '(') {
      depth++;
      i += 2;
      continue;
    }
    if (ch == ')') {
      depth--;
      i++;
      if (depth == 0) return i;
      continue;
    }
    i++;
  }
  return -1;
}

int _backquoteSpanEnd(String input, int start) {
  var i = start + 1;
  while (i < input.length) {
    if (input[i] == '\\') {
      i += 2;
      continue;
    }
    if (input[i] == '`') return i + 1;
    i++;
  }
  return -1;
}

int _quotedSpanEnd(String input, int start, String quote) {
  var i = start + 1;
  while (i < input.length) {
    if (input[i] == '\\' && quote == '"') {
      i += 2;
      continue;
    }
    if (input[i] == quote) return i + 1;
    i++;
  }
  return -1;
}

final class _ScriptParser {
  _ScriptParser(this.tokens, {this.allowFdDuplication = false});
  final List<_Token> tokens;

  /// Whether `2>&1`/`>&2` fd duplication parses (WASI shell opt-in).
  final bool allowFdDuplication;
  int _pos = 0;

  /// Keywords that close a block; in command position outside their block
  /// they are a parse error, never a command.
  static const _closers = {'then', 'elif', 'else', 'fi', 'do', 'done'};

  ShellScript parseScript() {
    final nodes = _parseList(const {}, closer: '');
    if (nodes.isEmpty) throw const ShellParseException('empty command');
    return ShellScript(nodes);
  }

  /// Parses nodes until a keyword from [terminators] appears in command
  /// position (top level: until end of input). [closer] names the keyword
  /// the caller expects, for the "missing" error on unexpected end of input.
  List<ScriptNode> _parseList(
    Set<String> terminators, {
    required String closer,
  }) {
    final nodes = <ScriptNode>[];
    var op = StatementOperator.none;
    while (true) {
      op = _skipSeparators(op);
      if (_atEnd) {
        if (terminators.isEmpty) return nodes;
        throw ShellParseException("missing '$closer'");
      }
      final next = tokens[_pos];
      if (next is _Word && terminators.contains(next.value)) return nodes;
      if (next is _Word && _closers.contains(next.value)) {
        throw ShellParseException("unexpected '${next.value}'");
      }
      nodes.add(_parseNode(op));
      op = StatementOperator.none;
    }
  }

  StatementOperator _skipSeparators(StatementOperator op) {
    while (!_atEnd) {
      final t = tokens[_pos];
      if (t is! _Operator) break;
      if (t.value == '&&') {
        op = StatementOperator.and;
      } else if (t.value == '||') {
        op = StatementOperator.or;
      } else if (t.value == ';') {
        op = StatementOperator.none;
      } else {
        break;
      }
      _pos++;
    }
    return op;
  }

  ScriptNode _parseNode(StatementOperator op) {
    final t = tokens[_pos];
    if (t is _Word && t.value == 'if') return _parseIf(op);
    if (t is _Word && t.value == 'for') return _parseFor(op);
    return ScriptPipeline(_pipeline(), operator: op);
  }

  ScriptIf _parseIf(StatementOperator op) {
    _pos++; // consume 'if'
    final branches = <ScriptBranch>[];
    List<ScriptNode>? elseBody;
    while (true) {
      final condition = _parseList(const {'then'}, closer: 'then');
      _pos++; // consume 'then' (the list stopped exactly on it)
      final body = _parseList(const {'elif', 'else', 'fi'}, closer: 'fi');
      branches.add(ScriptBranch(condition, body));
      final keyword = (tokens[_pos] as _Word).value;
      _pos++;
      if (keyword == 'elif') continue;
      if (keyword == 'else') {
        elseBody = _parseList(const {'fi'}, closer: 'fi');
        _pos++; // consume 'fi'
      }
      break;
    }
    return ScriptIf(branches, elseBody, operator: op);
  }

  ScriptFor _parseFor(StatementOperator op) {
    _pos++; // consume 'for'
    final name = _atEnd ? null : tokens[_pos];
    if (name is! _Word || !isIdentifier(name.value)) {
      throw const ShellParseException("for: expected a variable name");
    }
    _pos++;
    _expectKeyword('in', "for: missing 'in'");
    final words = _forWords();
    _skipSeparators(StatementOperator.none);
    _expectKeyword('do', "for: missing 'do'");
    final body = _parseList(const {'done'}, closer: 'done');
    _pos++; // consume 'done' (the list stopped exactly on it)
    return ScriptFor(name.value, words, body, operator: op);
  }

  List<ScriptWord> _forWords() {
    final words = <ScriptWord>[];
    while (!_atEnd) {
      final t = tokens[_pos];
      if (t is _Operator && t.value == ';') break;
      if (t is! _Word) {
        throw const ShellParseException("for: expected '; do' after the words");
      }
      words.add(
        ScriptWord(t.value, expandable: t.expandable, quoted: t.quoted),
      );
      _pos++;
    }
    return words;
  }

  void _expectKeyword(String keyword, String message) {
    final t = _atEnd ? null : tokens[_pos];
    if (t is! _Word || t.value != keyword) {
      throw ShellParseException(message);
    }
    _pos++;
  }

  Pipeline _pipeline() {
    final stages = <Stage>[_stage()];
    while (_match<_Operator>((t) => t.value == '|')) {
      stages.add(_stage());
    }
    return Pipeline(stages);
  }

  Stage _stage() {
    final args = <String>[];
    final expandable = <bool>[];
    final quoted = <bool>[];
    final redirects = <Redirect>[];

    while (!_atEnd && !_isStatementSeparator && !_peekIsPipe) {
      final token = _advance();
      if (token is _Word) {
        args.add(token.value);
        expandable.add(token.expandable);
        quoted.add(token.quoted);
      } else if (token is _Redirect) {
        if (token.kind == RedirectKind.background) {
          throw const ShellParseException(
            'background jobs (&) are not supported in the sandbox shell',
          );
        }
        if (_atEnd) throw const ShellParseException('missing redirect target');
        final next = _advance();
        if (next is _Redirect && next.kind == RedirectKind.background) {
          // `2>&1` tokenizes as redirect + background `&` + digit word.
          if (_atEnd) {
            throw const ShellParseException('missing redirect target');
          }
          final target = _advance();
          if (target is! _Word ||
              (target.value != '1' && target.value != '2')) {
            throw const ShellParseException(
              'fd duplication (2>&1) is not supported in the sandbox shell',
            );
          }
          if (!allowFdDuplication) {
            throw const ShellParseException(
              'fd duplication (2>&1) is not supported in the sandbox shell',
            );
          }
          redirects.add(
            Redirect(
              kind: RedirectKind.dup,
              fd: token.fd,
              target: target.value,
            ),
          );
          continue;
        }
        if (next is! _Word) {
          throw const ShellParseException('redirect target must be a word');
        }
        if (next.value.startsWith('&')) {
          throw const ShellParseException(
            'fd duplication (2>&1) is not supported in the sandbox shell',
          );
        }
        redirects.add(
          Redirect(
            kind: token.kind,
            fd: token.fd,
            target: next.value,
            expandable: next.expandable,
          ),
        );
      } else if (token is _Heredoc) {
        // The delimiter word follows the operator on the command line; the
        // body was captured by the tokenizer. Any quoting of the delimiter
        // (single or double) disables body expansion (POSIX).
        if (_atEnd) {
          throw const ShellParseException('missing here-document delimiter');
        }
        final next = _advance();
        if (next is! _Word) {
          throw const ShellParseException('missing here-document delimiter');
        }
        redirects.add(
          Redirect(
            kind: RedirectKind.heredoc,
            fd: token.fd,
            target: next.value,
            expandable: next.expandable && !next.quoted,
            body: token.body,
          ),
        );
      } else {
        throw ShellParseException('unexpected operator: ${_opValue(token)}');
      }
    }

    if (args.isEmpty) {
      throw const ShellParseException('missing command');
    }
    _validateStageWords(args, quoted);
    // `X=1 <<EOF` — a bare assignment carries no stdin consumer; the body
    // would be captured and silently dropped (gh-1086 review).
    if (redirects.any(
          (r) =>
              r.kind == RedirectKind.heredoc ||
              r.kind == RedirectKind.hereString,
        ) &&
        args.every(_assignmentWord.hasMatch)) {
      throw const ShellParseException(
        'a here-document/here-string on a bare assignment is not supported '
        'in the sandbox shell',
      );
    }

    return Stage(
      command: args.first,
      args: args.sublist(1),
      redirects: redirects,
      argExpandable: expandable,
      argQuoted: quoted,
    );
  }

  /// AC5 (gh-1086) fail-fast word checks. Only UNQUOTED words are checked
  /// — quoting passes the text through literally.
  void _validateStageWords(List<String> args, List<bool> quoted) {
    for (var i = 0; i < args.length; i++) {
      if (i < quoted.length && quoted[i]) continue;
      final word = args[i];
      if (i == 0) {
        // `X=1` / `A=1 B=2` (assignments only) are supported shell
        // assignments; the ENV-PREFIX form `X=1 cmd` is not (it used to
        // die as "X=1: command not found").
        if (_assignmentWord.hasMatch(word) &&
            args.skip(1).any((a) => !_assignmentWord.hasMatch(a))) {
          throw ShellParseException(
            "prefix assignments are not supported ('$word'): "
            "use 'export $word' instead",
          );
        }
        if (word.startsWith('(')) {
          throw const ShellParseException(
            'subshells (...) are not supported in the sandbox shell',
          );
        }
        if (_reservedWords.contains(word)) {
          throw ShellParseException(
            "'$word': this shell construct is not supported "
            'in the sandbox shell',
          );
        }
      }
      if (word.startsWith('~')) {
        throw const ShellParseException(
          'tilde expansion (~) is not supported; '
          'use an absolute sandbox path',
        );
      }
      // Glob patterns are EXPANDED at execution (gh-1393 WS-1, replacing
      // the gh-1086 parse-time rejection): `*.txt`, `apps/*/app.json` match
      // workspace paths; no match → the literal word passes through, so
      // quoting is only needed to keep glob metacharacters literal (the
      // parser's per-word `quoted` flag drives that). Bracket expressions
      // (`[a-z]`, `.[]`) are not glob syntax here and pass literally, as
      // they always have.
      if (_braceExpansion.hasMatch(word)) {
        throw ShellParseException(
          "brace expansion is not supported ('$word'): "
          'quote the argument to pass it literally',
        );
      }
    }
  }

  bool get _atEnd => _pos >= tokens.length;

  bool get _isStatementSeparator {
    if (_atEnd) return false;
    final t = tokens[_pos];
    return t is _Operator &&
        (t.value == ';' || t.value == '&&' || t.value == '||');
  }

  bool get _peekIsPipe {
    if (_atEnd) return false;
    final t = tokens[_pos];
    return t is _Operator && t.value == '|';
  }

  _Token _advance() => tokens[_pos++];

  bool _match<T extends _Token>(bool Function(T) test) {
    if (_atEnd) return false;
    final t = tokens[_pos];
    if (t is T && test(t)) {
      _pos++;
      return true;
    }
    return false;
  }

  String _opValue(_Token token) {
    if (token is _Operator) return token.value;
    if (token is _Redirect) {
      final name = token.fd == -1 ? '&' : '${token.fd}';
      return '$name${token.kind.name}';
    }
    return token.toString();
  }
}
