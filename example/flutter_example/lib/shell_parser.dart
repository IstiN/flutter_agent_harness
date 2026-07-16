// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Minimal POSIX-like shell parser for the WASM sandbox.
///
/// Supports enough syntax for typical agent commands:
///   - pipelines: `cat a | sort | head`
///   - logical operators: `a && b`, `a || b`
///   - statement separators: `a ; b`
///   - redirects: `> file`, `>> file`, `< file`, `2> file`, `2>> file`, `&> file`
///   - single and double quoting and backslash escapes.
///
/// No variable expansion, no subshells, no globbing, no `cd`. Commands run
/// inside the WASM sandbox always see `/` as the root and should use absolute
/// paths.
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
  });

  /// Command name (first word).
  final String command;

  /// Arguments following the command name.
  final List<String> args;

  /// File redirects attached to this stage.
  final List<Redirect> redirects;

  /// All tokens including command and arguments, convenient for callers.
  List<String> get argv => [command, ...args];
}

/// A file redirect attached to a stage.
final class Redirect {
  /// Creates a redirect.
  const Redirect({required this.kind, required this.fd, required this.target});

  /// Redirect kind.
  final RedirectKind kind;

  /// File descriptor: `0` stdin, `1` stdout, `2` stderr, `-1` stdout+stderr.
  final int fd;

  /// Target file path inside the sandbox.
  final String target;
}

/// Kinds of redirect.
enum RedirectKind { read, write, append }

/// Parses [input] into a [ShellCommand].
///
/// Throws [ShellParseException] on malformed input.
ShellCommand parseCommandLine(String input) {
  final tokens = _tokenize(input);
  final parser = _Parser(tokens);
  return parser.parse();
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
  _Word(this.value);
  final String value;
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

  void flushWord() {
    if (buffer.isEmpty) return;
    tokens.add(_Word(buffer.toString()));
    buffer.clear();
  }

  String peek() => i + 1 < input.length ? input[i + 1] : '';

  while (i < input.length) {
    final ch = input[i];

    if (ch == '\\' && i + 1 < input.length) {
      buffer.write(input[i + 1]);
      i += 2;
      continue;
    }

    if (ch == "'") {
      flushWord();
      i++;
      while (i < input.length && input[i] != "'") {
        buffer.write(input[i]);
        i++;
      }
      if (i >= input.length) throw const ShellParseException("unmatched '");
      i++; // skip closing quote
      flushWord();
      continue;
    }

    if (ch == '"') {
      flushWord();
      i++;
      while (i < input.length && input[i] != '"') {
        if (input[i] == '\\' && i + 1 < input.length) {
          buffer.write(input[i + 1]);
          i += 2;
        } else {
          buffer.write(input[i]);
          i++;
        }
      }
      if (i >= input.length) throw const ShellParseException('unmatched "');
      i++; // skip closing quote
      flushWord();
      continue;
    }

    if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') {
      flushWord();
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

final class _Parser {
  _Parser(this.tokens);
  final List<_Token> tokens;
  int _pos = 0;

  ShellCommand parse() {
    final statements = <Statement>[];
    while (!_atEnd) {
      final pipeline = _pipeline();
      StatementOperator op = StatementOperator.none;
      if (_match<_Operator>((t) => t.value == '&&')) {
        op = StatementOperator.and;
      } else if (_match<_Operator>((t) => t.value == '||')) {
        op = StatementOperator.or;
      } else if (_match<_Operator>((t) => t.value == ';')) {
        op = StatementOperator.none;
      }
      statements.add(Statement(pipeline, operator: op));
    }
    if (statements.isEmpty) {
      throw const ShellParseException('empty command');
    }
    return ShellCommand(statements);
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
    final redirects = <Redirect>[];

    while (!_atEnd && !_isStatementSeparator && !_peekIsPipe) {
      final token = _advance();
      if (token is _Word) {
        args.add(token.value);
      } else if (token is _Redirect) {
        if (_atEnd) throw const ShellParseException('missing redirect target');
        final next = _advance();
        if (next is! _Word) {
          throw const ShellParseException('redirect target must be a word');
        }
        redirects.add(
          Redirect(kind: token.kind, fd: token.fd, target: next.value),
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
