/// Pure-Dart table-driven syntax highlighter for fenced code (issue #808,
/// omp-parity S5/7): the top languages — dart, ts/js, python, bash/sh,
/// json, yaml, rust, go (fixed by owner decision D3) — tokenized into the
/// omp `syntax*` token grammar and styled through `FaThemeController`.
///
/// No dependencies; `re_highlight` stays flutter_app-only. Unknown fence
/// languages never reach this module (the formatter keeps today's
/// dim-border shape for them).
///
/// Color source (S1 seam): the `syntax*` roles are pinned by umbrella
/// #802 to the VS Code Dark+ set. S1 owns extending `TuiTheme` with the
/// full role table (tui_theme_palette.dart — NOT this lane's file); until
/// that merge lands, each role resolves to its pinned value through the
/// session profile via `tuiSgr`, so NO_COLOR / 16-color profiles degrade
/// exactly like every other theme role. When S1 lands, swap
/// [codeTokenSgr] to the theme roles — the token table and lexer stay.
///
/// Streaming contract (issue #808 AC5.4): lexing is a pure left-to-right
/// scan — a line's tokens depend only on state accumulated BEFORE it,
/// never on future lines. Per-completed-line pushes are therefore final;
/// no close-time re-highlight exists. Cross-line state (C block comments,
/// Python triple quotes) rides [CodeLexState], which the formatter
/// snapshots at commit boundaries so incremental resumes re-lex exactly.
library;

import 'package:dart_tui/src/bubbles/style.dart' show RgbColor, Style;

import 'tui_theme.dart'
    show FaThemeController, tuiSgr, tuiThemeIsLight;

/// Token kinds of the omp `syntax*` grammar (issue #802).
enum CodeTokenKind {
  plain,
  comment,
  keyword,
  function,
  variable,
  string,
  number,
  type,
  operator,
}

/// One lexical token: [text] is the exact source slice (concatenating all
/// tokens of a line reproduces the line byte-for-byte).
final class CodeToken {
  const CodeToken(this.kind, this.text);

  final CodeTokenKind kind;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is CodeToken && other.kind == kind && other.text == text;

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'CodeToken(${switch (kind) {
        CodeTokenKind.plain => 'plain',
        CodeTokenKind.comment => 'comment',
        CodeTokenKind.keyword => 'keyword',
        CodeTokenKind.function => 'function',
        CodeTokenKind.variable => 'variable',
        CodeTokenKind.string => 'string',
        CodeTokenKind.number => 'number',
        CodeTokenKind.type => 'type',
        CodeTokenKind.operator => 'operator',
      }}, $text)';
}

/// Supported fence languages.
enum CodeLang { dart, js, ts, python, bash, json, yaml, rust, go }

/// Maps a fence info-string tag to a supported language; null for unknown
/// (the caller renders those with the legacy shape).
CodeLang? codeLanguageOfTag(String? tag) => switch (tag) {
      'dart' || 'dartlang' => CodeLang.dart,
      'js' || 'javascript' || 'jsx' || 'node' => CodeLang.js,
      'ts' || 'tsx' || 'typescript' => CodeLang.ts,
      'python' || 'py' || 'python3' => CodeLang.python,
      'bash' || 'sh' || 'shell' || 'zsh' || 'shell-session' => CodeLang.bash,
      'json' || 'jsonc' => CodeLang.json,
      'yaml' || 'yml' => CodeLang.yaml,
      'rust' || 'rs' => CodeLang.rust,
      'go' || 'golang' => CodeLang.go,
      _ => null,
    };

/// Cross-line lexer state (block comment / triple-quoted string). Value
/// type: copied by snapshot/restore at transcript commit boundaries.
final class CodeLexState {
  const CodeLexState({this.inBlockComment = false, this.tripleQuote});

  /// Inside a `/* … */` span that has not closed yet (C-family only).
  final bool inBlockComment;

  /// Open Python triple-quote delimiter (`"""` or `'''`); null otherwise.
  final String? tripleQuote;

  static const clean = CodeLexState();

  @override
  bool operator ==(Object other) =>
      other is CodeLexState &&
      other.inBlockComment == inBlockComment &&
      other.tripleQuote == tripleQuote;

  @override
  int get hashCode => Object.hash(inBlockComment, tripleQuote);
}

/// One line's lex: the tokens plus the state AFTER the line (the input is
/// never mutated — snapshot/restore stays trivial).
final class CodeLexResult {
  const CodeLexResult(this.tokens, this.state);

  final List<CodeToken> tokens;
  final CodeLexState state;
}

// ── Per-language tables ────────────────────────────────────────────────────

const _cLike = {CodeLang.dart, CodeLang.js, CodeLang.ts, CodeLang.rust, CodeLang.go};

bool _hashLineComment(CodeLang lang) =>
    lang == CodeLang.python || lang == CodeLang.bash || lang == CodeLang.yaml;

bool _hasBlockComment(CodeLang lang) => _cLike.contains(lang);

bool _hasTripleQuote(CodeLang lang) => lang == CodeLang.python;

/// Capitalized identifiers render as types (Dart/TS/Python/Rust/Go class
/// convention). Bash has no case convention; yaml/json have no identifiers.
bool _capitalizedTypes(CodeLang lang) =>
    lang != CodeLang.bash && lang != CodeLang.json && lang != CodeLang.yaml;

const _keywords = <CodeLang, Set<String>>{
  CodeLang.dart: {
    'abstract', 'as', 'assert', 'async', 'await', 'base', 'break', 'case',
    'catch', 'class', 'const', 'continue', 'covariant', 'default', 'deferred',
    'do', 'dynamic', 'else', 'enum', 'export', 'extends', 'extension',
    'external', 'factory', 'false', 'final', 'finally', 'for', 'Function',
    'get', 'hide', 'if', 'implements', 'import', 'in', 'interface', 'is',
    'late', 'library', 'mixin', 'new', 'null', 'on', 'operator', 'part',
    'required', 'rethrow', 'return', 'sealed', 'set', 'show', 'static',
    'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef',
    'var', 'void', 'while', 'with', 'yield', 'when',
  },
  CodeLang.js: {
    'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue',
    'debugger', 'default', 'delete', 'do', 'else', 'export', 'extends',
    'false', 'finally', 'for', 'function', 'if', 'import', 'in',
    'instanceof', 'let', 'new', 'null', 'of', 'return', 'static', 'super',
    'switch', 'this', 'throw', 'true', 'try', 'typeof', 'undefined', 'var',
    'void', 'while', 'with', 'yield',
  },
  CodeLang.ts: {
    'any', 'as', 'async', 'await', 'boolean', 'break', 'case', 'catch',
    'class', 'const', 'continue', 'declare', 'default', 'delete', 'do',
    'else', 'enum', 'export', 'extends', 'false', 'finally', 'for',
    'function', 'if', 'implements', 'import', 'in', 'instanceof', 'interface',
    'is', 'keyof', 'let', 'namespace', 'never', 'new', 'null', 'number',
    'object', 'of', 'private', 'protected', 'public', 'readonly', 'return',
    'static', 'string', 'super', 'switch', 'symbol', 'this', 'throw', 'true',
    'try', 'type', 'typeof', 'undefined', 'unknown', 'var', 'void', 'while',
    'with', 'yield',
  },
  CodeLang.python: {
    'and', 'as', 'assert', 'async', 'await', 'break', 'case', 'class',
    'continue', 'def', 'del', 'elif', 'else', 'except', 'False', 'finally',
    'for', 'from', 'global', 'if', 'import', 'in', 'is', 'lambda', 'match',
    'None', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return', 'True',
    'try', 'while', 'with', 'yield',
  },
  CodeLang.bash: {
    'break', 'case', 'continue', 'coproc', 'declare', 'do', 'done', 'elif',
    'else', 'esac', 'eval', 'exec', 'exit', 'export', 'fi', 'for',
    'function', 'if', 'in', 'local', 'return', 'select', 'set', 'shift',
    'source', 'then', 'time', 'trap', 'until', 'unset', 'while',
  },
  CodeLang.json: {'true', 'false', 'null'},
  CodeLang.yaml: {'true', 'false', 'null'},
  CodeLang.rust: {
    'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
    'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in',
    'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
    'Self', 'self', 'static', 'struct', 'super', 'trait', 'true', 'type',
    'unsafe', 'use', 'where', 'while',
  },
  CodeLang.go: {
    'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else',
    'fallthrough', 'false', 'for', 'func', 'go', 'goto', 'if', 'import',
    'interface', 'map', 'nil', 'package', 'range', 'return', 'select',
    'struct', 'switch', 'true', 'type', 'var',
  },
};

// ── Lexer ──────────────────────────────────────────────────────────────────

final _numberRe = RegExp(r'\d[\w.]*');
final _identifierRe = RegExp(r'[A-Za-z_$][\w$]*');
final _wsRe = RegExp(r'\s+');
final _operatorRe = RegExp(r'''[^\sA-Za-z0-9_$"'`/#]+''');

/// Tokenizes one line of [lang] code. Concatenating the tokens' texts
/// reproduces [line] exactly; [CodeLexResult.state] is the state AFTER the
/// line (feed it back on the next line of the same fence).
CodeLexResult lexCodeLine(String line, CodeLang lang, CodeLexState state) {
  var inBlockComment = state.inBlockComment;
  var triple = state.tripleQuote;
  final tokens = <CodeToken>[];
  var i = 0;

  void emit(CodeTokenKind kind, int end) {
    if (end > i) {
      tokens.add(CodeToken(kind, line.substring(i, end)));
      i = end;
    }
  }

  // Carried-over spans first: the prefix belongs to the open construct.
  if (inBlockComment) {
    final close = line.indexOf('*/');
    if (close < 0) {
      return CodeLexResult(
        [CodeToken(CodeTokenKind.comment, line)],
        state,
      ); // still open at EOL
    }
    emit(CodeTokenKind.comment, close + 2);
    inBlockComment = false;
  } else if (triple != null) {
    final close = line.indexOf(triple);
    if (close < 0) {
      return CodeLexResult(
        [CodeToken(CodeTokenKind.string, line)],
        state,
      ); // still open at EOL
    }
    emit(CodeTokenKind.string, close + 3);
    triple = null;
  }

  while (i < line.length) {
    final c = line[i];
    // Line comments run to end of line.
    if ((c == '/' && i + 1 < line.length && line[i + 1] == '/' && _cLike.contains(lang)) ||
        (c == '#' && _hashLineComment(lang))) {
      emit(CodeTokenKind.comment, line.length);
      break;
    }
    // Block comments (C-family): same-line close or carried state.
    if (c == '/' && i + 1 < line.length && line[i + 1] == '*' && _hasBlockComment(lang)) {
      final close = line.indexOf('*/', i + 2);
      if (close < 0) {
        emit(CodeTokenKind.comment, line.length);
        inBlockComment = true;
        break;
      }
      emit(CodeTokenKind.comment, close + 2);
      continue;
    }
    // Strings: closing quote on the same line, backslash escapes skipped.
    if (c == '"' || c == "'" || c == '`') {
      if (_hasTripleQuote(lang) && line.startsWith(c * 3, i)) {
        final close = line.indexOf(c * 3, i + 3);
        if (close < 0) {
          emit(CodeTokenKind.string, line.length);
          triple = c * 3;
          break;
        }
        emit(CodeTokenKind.string, close + 3);
        continue;
      }
      var j = i + 1;
      while (j < line.length && line[j] != c) {
        j += line[j] == '\\' ? 2 : 1;
      }
      emit(CodeTokenKind.string, (j + 1).clamp(i, line.length));
      continue;
    }
    // Numbers.
    if (c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39) {
      final m = _numberRe.matchAsPrefix(line, i)!;
      emit(CodeTokenKind.number, m.end);
      continue;
    }
    // Identifiers: keyword / type / function-call / variable.
    if (_isIdentStart(c)) {
      final m = _identifierRe.matchAsPrefix(line, i)!;
      final word = m.group(0)!;
      final next = m.end < line.length ? line[m.end] : '';
      final kind = switch (word) {
        _ when _keywords[lang]!.contains(word) => CodeTokenKind.keyword,
        _ when _capitalizedTypes(lang) && _isUpper(word.codeUnitAt(0)) =>
          CodeTokenKind.type,
        _ when next == '(' => CodeTokenKind.function,
        _ => CodeTokenKind.variable,
      };
      emit(kind, m.end);
      continue;
    }
    // Whitespace runs.
    if (c == ' ' || c == '\t') {
      final m = _wsRe.matchAsPrefix(line, i)!;
      emit(CodeTokenKind.plain, m.end);
      continue;
    }
    // Punctuation/operator runs (VS Code Dark+ leaves operators at the
    // default fg — the style table emits no SGR for them).
    final m = _operatorRe.matchAsPrefix(line, i);
    if (m != null && m.end > i) {
      emit(CodeTokenKind.operator, m.end);
      continue;
    }
    // Lone `/` or `#` (comment openers the language does not carry).
    emit(CodeTokenKind.operator, i + 1);
  }

  return CodeLexResult(
    tokens,
    CodeLexState(inBlockComment: inBlockComment, tripleQuote: triple),
  );
}

bool _isIdentStart(String c) {
  final u = c.codeUnitAt(0);
  return (u >= 0x41 && u <= 0x5a) || (u >= 0x61 && u <= 0x7a) || u == 0x5f || u == 0x24;
}

bool _isUpper(int u) => u >= 0x41 && u <= 0x5a;

// ── Styling ────────────────────────────────────────────────────────────────

/// Issue-#802-pinned VS Code Dark+ values per token kind (the S1 palette
/// merge replaces this table with the theme's `syntax*` roles — see the
/// library comment). Operators and plain runs stay at the default fg.
const _pinnedHex = <CodeTokenKind, int>{
  CodeTokenKind.comment: 0x6A9955,
  CodeTokenKind.keyword: 0x569CD6,
  CodeTokenKind.function: 0xDCDCAA,
  CodeTokenKind.variable: 0x9CDCFE,
  CodeTokenKind.string: 0xCE9178,
  CodeTokenKind.number: 0xB5CEA8,
  CodeTokenKind.type: 0x4EC9B0,
};

/// VS Code Light+ equivalents for light themes (issue #808): the Dark+
/// pins wash out on ohmypi-light's background. Same seam as above — S1
/// folds both tables into the theme roles.
const _pinnedHexLight = <CodeTokenKind, int>{
  CodeTokenKind.comment: 0x008000,
  CodeTokenKind.keyword: 0x0000FF,
  CodeTokenKind.function: 0x795E26,
  CodeTokenKind.variable: 0x001080,
  CodeTokenKind.string: 0xA31515,
  CodeTokenKind.number: 0x098658,
  CodeTokenKind.type: 0x267F99,
};

final _sgrCache = <(bool, CodeTokenKind), String>{};

/// The SGR prefix for [kind] under the session profile ('' when styling is
/// off or the kind rides the default fg). Keyed by the light/dark palette
/// choice so a mid-session `/theme` flip re-resolves; styling-off always
/// short-circuits (the cache never resurrects escapes for NO_COLOR).
String codeTokenSgr(CodeTokenKind kind) {
  if (FaThemeController.instance.profile == null) return '';
  final light = tuiThemeIsLight;
  final hex = (light ? _pinnedHexLight : _pinnedHex)[kind];
  if (hex == null) return '';
  return _sgrCache[(light, kind)] ??= tuiSgr(
    Style(
      foregroundRgb: RgbColor(
        (hex >> 16) & 0xff,
        (hex >> 8) & 0xff,
        hex & 0xff,
      ),
    ),
  );
}

/// Highlights one line: SGR-styled text with adjacent same-kind tokens
/// merged into one escape run. Styling-off degrades to the plain line.
String highlightCodeLine(String line, CodeLang lang, CodeLexState state) =>
    _styleTokens(lexCodeLine(line, lang, state).tokens);

String _styleTokens(List<CodeToken> tokens) {
  if (tokens.isEmpty) return '';
  final out = StringBuffer();
  CodeTokenKind? openKind;
  for (final token in tokens) {
    final sgr = codeTokenSgr(token.kind);
    if (sgr.isEmpty) {
      if (openKind != null) out.write('\x1b[0m');
      out.write(token.text);
      openKind = null;
      continue;
    }
    if (openKind != token.kind) {
      if (openKind != null) out.write('\x1b[0m');
      out.write(sgr);
    }
    out.write(token.text);
    openKind = token.kind;
  }
  if (openKind != null) out.write('\x1b[0m');
  return out.toString();
}

/// Per-fence streaming highlighter: [push] each completed fence line in
/// order; the cross-line lexer state advances internally.
final class CodeHighlighter {
  CodeHighlighter(this.lang);

  final CodeLang lang;
  CodeLexState _state = CodeLexState.clean;

  String push(String line) {
    final lexed = lexCodeLine(line, lang, _state);
    _state = lexed.state;
    final styled = _styleTokens(lexed.tokens);
    return styled.isEmpty ? line : styled;
  }

  /// Freezes the cross-line state for a commit-boundary snapshot.
  CodeLexState snapshot() => _state;

  /// Restores a snapshot (incremental resume must re-lex exactly).
  void restore(CodeLexState state) => _state = state;
}
