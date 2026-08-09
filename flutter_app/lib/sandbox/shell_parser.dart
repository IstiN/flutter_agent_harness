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
  });

  /// Redirect kind.
  final RedirectKind kind;

  /// File descriptor: `0` stdin, `1` stdout, `2` stderr, `-1` stdout+stderr.
  final int fd;

  /// Target file path inside the sandbox.
  final String target;

  /// Whether [target] allows `$VAR` expansion.
  final bool expandable;
}

/// Kinds of redirect.
enum RedirectKind { read, write, append }

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
/// Throws [ShellParseException] on malformed input: unterminated blocks
/// (the message names the missing keyword), stray `then`/`else`/`fi`/`do`/
/// `done` keywords, or invalid `for` syntax.
ShellScript parseShellScript(String input) {
  final tokens = _tokenize(input);
  return _ScriptParser(tokens).parseScript();
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

List<_Token> _tokenize(String input) {
  final tokens = <_Token>[];
  final buffer = StringBuffer();
  var i = 0;
  var wordExpandable = true;
  var wordQuoted = false;

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
      final end = substitutionSpanEnd(input, i);
      if (end == -1) {
        throw ShellParseException(ch == '`' ? 'unmatched `' : 'unmatched \$(');
      }
      buffer.write(input.substring(i, end));
      i = end;
      continue;
    }

    if (ch == "'") {
      // No flush at the quote boundary: POSIX glues adjacent fragments into
      // one word (`X="a b"` is ONE word, `a'b'` is `ab`). The word ends at
      // the next unquoted separator.
      wordExpandable = false;
      i++;
      while (i < input.length && input[i] != "'") {
        buffer.write(input[i]);
        i++;
      }
      if (i >= input.length) throw const ShellParseException("unmatched '");
      i++; // skip closing quote
      continue;
    }

    if (ch == '"') {
      wordQuoted = true;
      i++;
      while (i < input.length && input[i] != '"') {
        if (input[i] == '\\' && i + 1 < input.length) {
          final next = input[i + 1];
          if (next == '"' ||
              next == '\\' ||
              next == '\$' ||
              next == '`' ||
              next == '\n') {
            // POSIX double-quote escapes: \" \\ \$ \` \<newline>
            if (next == '\$') wordExpandable = false;
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
          // Command substitution inside double quotes: keep the raw span so
          // inner quotes do not terminate this quoted section.
          final end = substitutionSpanEnd(input, i);
          if (end == -1) {
            throw ShellParseException(
              input[i] == '`' ? 'unmatched `' : 'unmatched \$(',
            );
          }
          buffer.write(input.substring(i, end));
          i = end;
        } else {
          buffer.write(input[i]);
          i++;
        }
      }
      if (i >= input.length) throw const ShellParseException('unmatched "');
      i++; // skip closing quote — the word continues until a separator.
      continue;
    }

    if (ch == ' ' || ch == '\t' || ch == '\r') {
      flushWord();
      i++;
      continue;
    }

    // A newline separates statements exactly like `;`.
    if (ch == '\n') {
      flushWord();
      tokens.add(_Operator(';'));
      i++;
      continue;
    }

    // Shell metacharacters always start a new token, even when they touch a
    // previous word (e.g. `a; b`, `echo>file`).
    if (ch == '|' || ch == '&' || ch == ';' || ch == '>' || ch == '<') {
      flushWord();
      if (ch == '|' && peek() == '|') {
        tokens.add(_Operator('||'));
        i += 2;
        continue;
      }
      if (ch == '&' && peek() == '&') {
        tokens.add(_Operator('&&'));
        i += 2;
        continue;
      }
      if (ch == '|') {
        tokens.add(_Operator('|'));
        i++;
        continue;
      }
      if (ch == ';') {
        tokens.add(_Operator(';'));
        i++;
        continue;
      }
      if (ch == '&' && i + 1 < input.length && input[i + 1] == '>') {
        if (i + 2 < input.length && input[i + 2] == '>') {
          tokens.add(_Redirect(-1, RedirectKind.append));
          i += 3;
        } else {
          tokens.add(_Redirect(-1, RedirectKind.write));
          i += 2;
        }
        continue;
      }
      if (ch == '>' && peek() == '>') {
        tokens.add(_Redirect(1, RedirectKind.append));
        i += 2;
        continue;
      }
      if (ch == '<' && peek() == '<') {
        throw const ShellParseException('here-documents are not supported');
      }
      if (ch == '>') {
        tokens.add(_Redirect(1, RedirectKind.write));
        i++;
        continue;
      }
      if (ch == '<') {
        tokens.add(_Redirect(0, RedirectKind.read));
        i++;
        continue;
      }
    }

    // File-descriptor redirects: N> N>> N>&1 (basic forms).
    if (_isDigit(ch)) {
      final start = i;
      while (i < input.length && _isDigit(input[i])) {
        i++;
      }
      final number = input.substring(start, i);
      if (i < input.length && (input[i] == '>' || input[i] == '<')) {
        final fd = int.parse(number);
        if (input[i] == '>' && i + 1 < input.length && input[i + 1] == '>') {
          tokens.add(_Redirect(fd, RedirectKind.append));
          i += 2;
        } else if (input[i] == '>') {
          tokens.add(_Redirect(fd, RedirectKind.write));
          i++;
        } else {
          tokens.add(_Redirect(fd, RedirectKind.read));
          i++;
        }
        continue;
      }
      // Not a redirect: treat the digits as part of the next word.
      buffer.write(number);
      continue;
    }

    buffer.write(ch);
    i++;
  }
  flushWord();
  return tokens;
}

bool _isDigit(String ch) =>
    ch.length == 1 && ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57;

bool _isIdentifier(String value) {
  if (value.isEmpty) return false;
  final first = value.codeUnitAt(0);
  final firstOk =
      (first >= 65 && first <= 90) ||
      (first >= 97 && first <= 122) ||
      first == 95;
  if (!firstOk) return false;
  for (var i = 1; i < value.length; i++) {
    final c = value.codeUnitAt(i);
    final ok =
        (c >= 65 && c <= 90) ||
        (c >= 97 && c <= 122) ||
        (c >= 48 && c <= 57) ||
        c == 95;
    if (!ok) return false;
  }
  return true;
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
  _ScriptParser(this.tokens);
  final List<_Token> tokens;
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
    if (name is! _Word || !_isIdentifier(name.value)) {
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
        if (_atEnd) throw const ShellParseException('missing redirect target');
        final next = _advance();
        if (next is! _Word) {
          throw const ShellParseException('redirect target must be a word');
        }
        redirects.add(
          Redirect(
            kind: token.kind,
            fd: token.fd,
            target: next.value,
            expandable: next.expandable,
          ),
        );
      } else {
        throw ShellParseException('unexpected operator: ${_opValue(token)}');
      }
    }

    if (args.isEmpty) {
      throw const ShellParseException('missing command');
    }

    return Stage(
      command: args.first,
      args: args.sublist(1),
      redirects: redirects,
      argExpandable: expandable,
      argQuoted: quoted,
    );
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
