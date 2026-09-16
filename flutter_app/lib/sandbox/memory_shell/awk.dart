// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// One awk record: the current line, its fields, and its 1-based number.
final class AwkRecord {
  const AwkRecord({required this.line, required this.fields, required this.nr});

  final String line;
  final List<String> fields;
  final int nr;
}

/// The parsed `awk` command line: `-F` separator plus positionals.
typedef AwkInvocation = ({
  String? fieldSeparator,
  List<String> positionals,
  ({String message, int exitCode})? error,
});

/// Parses the `awk` argument list (pure).
AwkInvocation parseAwkArgs(List<String> args) {
  String? fieldSeparator;
  final positionals = <String>[];
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-F') {
      if (i + 1 >= args.length) {
        return (
          fieldSeparator: null,
          positionals: positionals,
          error: (
            message: 'awk: option requires an argument -- F\n',
            exitCode: 2,
          ),
        );
      }
      fieldSeparator = args[++i];
    } else if (arg.startsWith('-F')) {
      fieldSeparator = arg.substring(2);
    } else if (arg.startsWith('-') && arg != '-') {
      return (
        fieldSeparator: fieldSeparator,
        positionals: positionals,
        error: (message: 'awk: unsupported option $arg\n', exitCode: 2),
      );
    } else {
      positionals.add(arg);
    }
  }
  if (fieldSeparator == r'\t') fieldSeparator = '\t';

  if (positionals.isEmpty) {
    return (
      fieldSeparator: fieldSeparator,
      positionals: positionals,
      error: (message: 'usage: awk [-F sep] program [file...]\n', exitCode: 2),
    );
  }
  return (
    fieldSeparator: fieldSeparator,
    positionals: positionals,
    error: null,
  );
}

/// The parsed awk program: an optional `/pattern/` plus the print list.
typedef AwkProgram = ({
  RegExp? pattern,
  String printExpr,
  ({String message, int exitCode})? error,
});

/// Parses the awk program (pure): `[/pattern/][{print ...}]`. A pattern
/// without an action prints the whole record.
AwkProgram parseAwkProgram(String program) {
  var body = program.trim();
  RegExp? pattern;
  if (body.startsWith('/')) {
    final end = body.indexOf('/', 1);
    if (end <= 1) {
      return (
        pattern: null,
        printExpr: r'$0',
        error: (message: 'awk: bad pattern in program\n', exitCode: 2),
      );
    }
    try {
      pattern = RegExp(body.substring(1, end));
    } on Object catch (e) {
      return (
        pattern: null,
        printExpr: r'$0',
        error: (message: 'awk: bad pattern: $e\n', exitCode: 2),
      );
    }
    body = body.substring(end + 1).trim();
  }
  // A pattern without an action prints the whole record.
  var printExpr = r'$0';
  if (body.isNotEmpty) {
    if (!body.startsWith('{') || !body.endsWith('}')) {
      return (
        pattern: pattern,
        printExpr: printExpr,
        error: (message: 'awk: unsupported program: $program\n', exitCode: 2),
      );
    }
    final action = body.substring(1, body.length - 1).trim();
    if (action != 'print' && !action.startsWith('print ')) {
      return (
        pattern: pattern,
        printExpr: printExpr,
        error: (message: 'awk: unsupported action: $action\n', exitCode: 2),
      );
    }
    printExpr = action == 'print' ? r'$0' : action.substring(6).trim();
  }
  return (pattern: pattern, printExpr: printExpr, error: null);
}

/// Runs the awk program over [input], returning the output text (pure).
String runAwk(
  String input,
  RegExp? pattern,
  String printExpr,
  String? fieldSeparator,
) {
  final lines = input.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final out = StringBuffer();
  for (var n = 0; n < lines.length; n++) {
    final line = lines[n];
    if (pattern != null && !pattern.hasMatch(line)) continue;
    final trimmed = line.trim();
    final fields = fieldSeparator != null
        ? line.split(fieldSeparator)
        : (trimmed.isEmpty ? <String>[] : trimmed.split(RegExp(r'\s+')));
    final record = AwkRecord(line: line, fields: fields, nr: n + 1);
    final values = [
      for (final expr in splitAwkTopLevel(printExpr)) evalAwkExpr(expr, record),
    ];
    out.writeln(values.join(' '));
  }
  return out.toString();
}

/// Splits a print list on top-level commas (commas join fields with OFS,
/// a single space here).
List<String> splitAwkTopLevel(String expr) {
  final parts = <String>[];
  var depth = 0;
  var inString = false;
  var start = 0;
  for (var i = 0; i < expr.length; i++) {
    final ch = expr[i];
    if (ch == '"') inString = !inString;
    if (inString) continue;
    if (ch == '(') depth++;
    if (ch == ')') depth--;
    if (ch == ',' && depth == 0) {
      parts.add(expr.substring(start, i));
      start = i + 1;
    }
  }
  parts.add(expr.substring(start));
  return parts;
}

/// Evaluates a tiny awk expression: an additive chain of terms (`$N`,
/// `$0`, `NR`, `NF`, numbers, "strings") or their concatenation.
String evalAwkExpr(String expr, AwkRecord record) {
  final tokens = awkTokens(expr);
  if (tokens.isEmpty) return '';
  if (tokens.any((t) => t == '+' || t == '-')) {
    var total = 0.0;
    var op = '+';
    for (final token in tokens) {
      if (token == '+' || token == '-') {
        op = token;
        continue;
      }
      final value = awkTermValue(token, record);
      final number = value is num ? value : num.tryParse('$value') ?? 0;
      total = op == '+' ? total + number : total - number;
    }
    return total == total.roundToDouble()
        ? total.toInt().toString()
        : total.toString();
  }
  return tokens.map((t) => '${awkTermValue(t, record)}').join();
}

List<String> awkTokens(String expr) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inString = false;
  void flush() {
    if (buffer.isEmpty) return;
    tokens.add(buffer.toString());
    buffer.clear();
  }

  for (var i = 0; i < expr.length; i++) {
    final ch = expr[i];
    if (ch == '"') {
      buffer.write(ch);
      inString = !inString;
      continue;
    }
    if (!inString && (ch == '+' || ch == '-' || ch == ' ' || ch == '\t')) {
      flush();
      if (ch == '+' || ch == '-') tokens.add(ch);
      continue;
    }
    buffer.write(ch);
  }
  flush();
  return tokens;
}

Object awkTermValue(String token, AwkRecord record) {
  final term = token.trim();
  if (term.length >= 2 && term.startsWith('"') && term.endsWith('"')) {
    return term.substring(1, term.length - 1);
  }
  if (term == 'NR') return record.nr;
  if (term == 'NF') return record.fields.length;
  if (term.startsWith(r'$')) {
    final index = int.tryParse(term.substring(1));
    if (index == null) return '';
    if (index == 0) return record.line;
    return index <= record.fields.length ? record.fields[index - 1] : '';
  }
  final number = num.tryParse(term);
  if (number != null) return number;
  return term;
}
