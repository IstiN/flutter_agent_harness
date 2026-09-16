// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Filesystem predicates the `test`/`[ ]` evaluator needs. An interface, so
/// the evaluator is a pure recursive descent over the argument list and the
/// shell wires it to the in-memory filesystem.
abstract interface class TestFs {
  /// `-e path`: anything exists at the sandbox path.
  Future<bool> exists(String path);

  /// The file's info, or `null` when the path does not exist.
  Future<FileInfo?> fileInfo(String path);
}

/// Evaluates a `test`/`[` expression (pure recursive descent): an optional
/// chain of `!` negations over a unary (`-e`, `-f`, `-d`, `-s`, `-z`, `-n`)
/// or binary (`=`, `==`, `!=`, `-eq`, `-ne`, `-lt`, `-le`, `-gt`, `-ge`)
/// predicate, or a bare non-empty-string test. Throws [FormatException] on
/// malformed expressions, exactly as before.
Future<bool> evalTestExpr(List<String> args, TestFs fs) async {
  if (args.isEmpty) return false;
  if (args.first == '!') {
    return !(await evalTestExpr(args.sublist(1), fs));
  }
  if (args.length == 1) return args.first.isNotEmpty;
  if (args.length == 2) {
    return evalTestUnary(args[0], args[1], fs);
  }
  if (args.length == 3) {
    return evalTestBinary(args[0], args[1], args[2]);
  }
  throw const FormatException('too many arguments');
}

/// Evaluates a two-token unary test.
Future<bool> evalTestUnary(String op, String value, TestFs fs) async {
  switch (op) {
    case '-e':
      return fs.exists(value);
    case '-f':
      final info = await fs.fileInfo(value);
      return info != null && info.kind == FileKind.file;
    case '-d':
      final info = await fs.fileInfo(value);
      return info != null && info.kind == FileKind.directory;
    case '-s':
      final info = await fs.fileInfo(value);
      return info != null && info.kind == FileKind.file && info.size > 0;
    case '-z':
      return value.isEmpty;
    case '-n':
      return value.isNotEmpty;
    default:
      throw const FormatException('unary operator expected');
  }
}

/// Evaluates a three-token binary test.
bool evalTestBinary(String left, String op, String right) {
  switch (op) {
    case '=':
    case '==':
      return left == right;
    case '!=':
      return left != right;
    case '-eq':
      return int.parse(left) == int.parse(right);
    case '-ne':
      return int.parse(left) != int.parse(right);
    case '-lt':
      return int.parse(left) < int.parse(right);
    case '-le':
      return int.parse(left) <= int.parse(right);
    case '-gt':
      return int.parse(left) > int.parse(right);
    case '-ge':
      return int.parse(left) >= int.parse(right);
    default:
      throw FormatException('unknown operator: $op');
  }
}
