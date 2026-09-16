// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The sed commands this subset supports.
enum SedKind { substitute, print }

/// One sed address: a 1-based line number, `$` (last line), or `/regex/`.
typedef SedAddress = ({int? line, bool last, RegExp? regex});

/// A parsed sed command: an optional address range plus `s/pat/repl/[g]` or
/// `p`. Addresses are 1-based line numbers, `$` (last line), or `/regex/`.
final class SedCommand {
  const SedCommand._({
    required this.kind,
    this.startLine,
    this.endLine,
    this.startLast = false,
    this.endLast = false,
    this.startRegex,
    this.endRegex,
    this.pattern,
    this.replacement,
    this.global = false,
  });

  final SedKind kind;
  final int? startLine;
  final int? endLine;
  final bool startLast;
  final bool endLast;
  final RegExp? startRegex;
  final RegExp? endRegex;
  final RegExp? pattern;
  final String? replacement;
  final bool global;

  /// Parses `[addr[,addr]]cmd`; returns `null` for unsupported scripts.
  static SedCommand? tryParse(String script) {
    final start = _readAddress(script, 0);
    var i = start.next;
    SedAddress? startAddress = start.address;
    SedAddress? end;
    if (i < script.length && script[i] == ',') {
      final parsed = _readAddress(script, i + 1);
      if (parsed.address == null) return null;
      end = parsed.address;
      i = parsed.next;
    }
    if (i >= script.length) return null;

    final command = script[i];
    if (command == 'p') {
      if (i + 1 != script.length) return null;
      return SedCommand._(
        kind: SedKind.print,
        startLine: startAddress?.line,
        endLine: end?.line,
        startLast: startAddress?.last ?? false,
        endLast: end?.last ?? false,
        startRegex: startAddress?.regex,
        endRegex: end?.regex,
      );
    }
    if (command != 's') return null;
    return _parseSubstitute(script, i, startAddress, end);
  }

  /// Reads one address at [i]; `(address: null, next: i)` when there is no
  /// address at [i] (an unterminated `/regex/` reads as "none", exactly as
  /// the original scanner did).
  static ({SedAddress? address, int next}) _readAddress(String script, int i) {
    if (i >= script.length) return (address: null, next: i);
    final ch = script[i];
    if (ch == r'$') {
      return (address: (line: null, last: true, regex: null), next: i + 1);
    }
    if (ch == '/') {
      final end = script.indexOf('/', i + 1);
      if (end < 0) return (address: null, next: i);
      final RegExp regex;
      try {
        regex = RegExp(script.substring(i + 1, end));
      } on Object {
        return (address: null, next: i);
      }
      return (address: (line: null, last: false, regex: regex), next: end + 1);
    }
    if (ch.codeUnitAt(0) >= 48 && ch.codeUnitAt(0) <= 57) {
      var end = i;
      while (end < script.length &&
          script[end].codeUnitAt(0) >= 48 &&
          script[end].codeUnitAt(0) <= 57) {
        end++;
      }
      final line = int.parse(script.substring(i, end));
      return (address: (line: line, last: false, regex: null), next: end);
    }
    return (address: null, next: i);
  }

  /// Parses the body of an `s` command whose `s` sits at [i].
  static SedCommand? _parseSubstitute(
    String script,
    int i,
    SedAddress? start,
    SedAddress? end,
  ) {
    if (i + 1 >= script.length) return null;
    final delimiter = script[i + 1];
    final pattern = _scanDelimited(script, i + 2, delimiter);
    if (pattern == null) return null;
    final replacement = _scanDelimited(script, pattern.end, delimiter);
    if (replacement == null) return null;
    final flags = script.substring(replacement.end);
    if (flags.isNotEmpty && flags != 'g') return null;

    final RegExp regex;
    try {
      regex = RegExp(pattern.text);
    } on Object {
      return null;
    }
    return SedCommand._(
      kind: SedKind.substitute,
      startLine: start?.line,
      endLine: end?.line,
      startLast: start?.last ?? false,
      endLast: end?.last ?? false,
      startRegex: start?.regex,
      endRegex: end?.regex,
      pattern: regex,
      replacement: replacement.text,
      global: flags == 'g',
    );
  }

  /// Reads up to an unescaped [delimiter], keeping backslash pairs verbatim.
  /// Returns the text and the index just past the closing delimiter, or
  /// `null` when the delimiter never comes.
  static ({String text, int end})? _scanDelimited(
    String script,
    int from,
    String delimiter,
  ) {
    final buffer = StringBuffer();
    var j = from;
    while (j < script.length) {
      if (script[j] == '\\' && j + 1 < script.length) {
        buffer
          ..write(script[j])
          ..write(script[j + 1]);
        j += 2;
        continue;
      }
      if (script[j] == delimiter) {
        return (text: buffer.toString(), end: j + 1);
      }
      buffer.write(script[j]);
      j++;
    }
    return null;
  }

  bool _addressMatches(
    int? line,
    bool last,
    RegExp? regex,
    int lineNo,
    bool isLast,
    String text,
  ) {
    if (last) return isLast;
    if (regex != null) return regex.hasMatch(text);
    if (line != null) return lineNo == line;
    return true;
  }

  /// Whether this command applies to [lineNo]; [ranges] tracks open address
  /// ranges across lines.
  bool select(
    int lineNo,
    bool isLast,
    String text,
    Map<SedCommand, bool> ranges,
  ) {
    final hasStart = startLine != null || startLast || startRegex != null;
    final hasEnd = endLine != null || endLast || endRegex != null;
    if (!hasStart) return true;
    if (!hasEnd) {
      return _addressMatches(
        startLine,
        startLast,
        startRegex,
        lineNo,
        isLast,
        text,
      );
    }
    var active = ranges[this] ?? false;
    if (!active &&
        _addressMatches(
          startLine,
          startLast,
          startRegex,
          lineNo,
          isLast,
          text,
        )) {
      active = true;
      ranges[this] = true;
      // A same-line end (e.g. `2,2`) closes the range immediately.
      if (_addressMatches(endLine, endLast, endRegex, lineNo, isLast, text)) {
        ranges[this] = false;
      }
      return true;
    }
    if (active) {
      if (_addressMatches(endLine, endLast, endRegex, lineNo, isLast, text)) {
        ranges[this] = false;
      }
      return true;
    }
    return false;
  }

  /// Applies the substitution to [line]; `&` and `\N` in the replacement
  /// reference the whole match and capture groups like POSIX sed.
  String applySubstitute(String line) {
    final regex = pattern!;
    final replacement = this.replacement!;

    String expand(Match match) {
      final buffer = StringBuffer();
      for (var i = 0; i < replacement.length; i++) {
        final ch = replacement[i];
        if (ch == '&') {
          buffer.write(match[0]);
          continue;
        }
        if (ch == '\\' && i + 1 < replacement.length) {
          final next = replacement[i + 1];
          final code = next.codeUnitAt(0);
          if (code >= 49 && code <= 57) {
            buffer.write(match[int.parse(next)] ?? '');
          } else if (next == 'n') {
            buffer.write('\n');
          } else if (next == 't') {
            buffer.write('\t');
          } else {
            buffer.write(next);
          }
          i++;
          continue;
        }
        buffer.write(ch);
      }
      return buffer.toString();
    }

    if (global) return line.replaceAllMapped(regex, expand);
    final match = regex.firstMatch(line);
    if (match == null) return line;
    return line.replaceRange(match.start, match.end, expand(match));
  }
}

/// The parsed `sed` command line: options, scripts, and input files.
typedef SedInvocation = ({
  bool quiet,
  bool inPlace,
  List<String> scripts,
  List<String> files,
  ({String message, int exitCode})? error,
});

/// Parses the `sed` argument list (pure): flags, scripts, and files, with
/// the usage errors the driver reports verbatim.
SedInvocation parseSedArgs(List<String> args) {
  var quiet = false;
  var inPlace = false;
  final scripts = <String>[];
  final files = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-n' || arg == '--quiet' || arg == '--silent') {
      quiet = true;
    } else if (arg.startsWith('-i')) {
      inPlace = true;
    } else if (arg == '-e') {
      if (i + 1 >= args.length) {
        return (
          quiet: quiet,
          inPlace: inPlace,
          scripts: scripts,
          files: files,
          error: (
            message: 'sed: option requires an argument -- e\n',
            exitCode: 1,
          ),
        );
      }
      scripts.add(args[++i]);
    } else if (arg.startsWith('-e')) {
      scripts.add(arg.substring(2));
    } else if (arg == '-E' || arg == '-r') {
      // Extended regex is the only syntax this subset supports anyway.
    } else if (arg == '--') {
      // End of options.
    } else if (arg.startsWith('-') && arg != '-') {
      return (
        quiet: quiet,
        inPlace: inPlace,
        scripts: scripts,
        files: files,
        error: (message: 'sed: unsupported option $arg\n', exitCode: 1),
      );
    } else if (scripts.isEmpty && files.isEmpty) {
      scripts.add(arg);
    } else {
      files.add(arg);
    }
  }

  if (scripts.isEmpty) {
    return (
      quiet: quiet,
      inPlace: inPlace,
      scripts: scripts,
      files: files,
      error: (
        message: 'usage: sed [-n] [-i] [-e script] [script] [file...]\n',
        exitCode: 1,
      ),
    );
  }
  if (inPlace && files.isEmpty) {
    return (
      quiet: quiet,
      inPlace: inPlace,
      scripts: scripts,
      files: files,
      error: (message: 'sed: -i requires file arguments\n', exitCode: 1),
    );
  }
  return (
    quiet: quiet,
    inPlace: inPlace,
    scripts: scripts,
    files: files,
    error: null,
  );
}

/// Applies [commands] to [input] line by line; auto-prints each line
/// unless [quiet] (`-n`) is set. Always ends the output with a newline
/// when the input was non-empty, mirroring GNU sed.
String runSed(String input, List<SedCommand> commands, {bool quiet = false}) {
  final lines = input.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  final out = StringBuffer();
  final ranges = <SedCommand, bool>{};
  for (var n = 0; n < lines.length; n++) {
    var line = lines[n];
    final lineNo = n + 1;
    final isLast = n == lines.length - 1;
    for (final command in commands) {
      final selected = command.select(lineNo, isLast, line, ranges);
      if (!selected) continue;
      switch (command.kind) {
        case SedKind.substitute:
          line = command.applySubstitute(line);
        case SedKind.print:
          out.writeln(line);
      }
    }
    if (!quiet) out.writeln(line);
  }
  return out.toString();
}
