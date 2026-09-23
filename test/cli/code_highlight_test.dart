import 'package:flutter_agent_harness/src/cli/code_highlight.dart';
import 'package:flutter_agent_harness/src/cli/tui_theme.dart';
import 'package:test/test.dart';

/// Pure-Dart fence highlighter (issue #808): tokenizer round-trips,
/// per-language classification, cross-line state, and styling degradation.
void main() {
  group('tokenizer round-trips', () {
    const lines = <(CodeLang, String)>[
      (
        CodeLang.dart,
        "final x = foo(42, 'a\\'b'); // trailing",
      ),
      (
        CodeLang.js,
        'const re = /ab+c/g; let s = `tpl \${x}`;',
      ),
      (
        CodeLang.ts,
        'interface Foo { name: string; n?: number }',
      ),
      (
        CodeLang.python,
        'def f(x: int = 3) -> "Foo":  # note',
      ),
      (
        CodeLang.bash,
        'local p="\$HOME/bin" && export PATH="\$p:\$PATH" # go',
      ),
      (
        CodeLang.json,
        '{"k": [1, 1.5e3, true, null], "s": "a\\"b"}',
      ),
      (
        CodeLang.yaml,
        'key: value # comment\nother: "lit#eral"',
      ),
      (
        CodeLang.rust,
        "let s: &'static str = \"own\"; // 'a lifetime",
      ),
      (
        CodeLang.go,
        'x := <-ch; go func() { defer close(ch) }()',
      ),
      // Degenerate inputs: unterminated strings and lone openers.
      (
        CodeLang.dart,
        "final s = 'never closed",
      ),
      (
        CodeLang.bash,
        "echo 'unterminated \"double",
      ),
      (
        CodeLang.json,
        '{"a": "unterminated',
      ),
      (
        CodeLang.dart,
        'a / b / c',
      ),
      (
        CodeLang.python,
        'x = 1  #',
      ),
    ];

    test('tokens concatenate back to the exact line (all languages)', () {
      for (final (lang, line) in lines) {
        final r = lexCodeLine(line, lang, CodeLexState.clean);
        expect(r.tokens.map((t) => t.text).join(), line,
            reason: '$lang: ${r.tokens}');
      }
    });

    test('long mixed lines survive across every language', () {
      const line = 'a1 bb Ccc d4 e5f Ggg7 hhh i8 j9 k10 lll m12 n13 o14 p15';
      for (final lang in CodeLang.values) {
        final r = lexCodeLine(line, lang, CodeLexState.clean);
        expect(r.tokens.map((t) => t.text).join(), line, reason: '$lang');
      }
    });
  });

  group('classification (dart)', () {
    test('keyword / type / function / variable / string / number / comment', () {
      final r = lexCodeLine(
        'final Foo v = make(1); // end',
        CodeLang.dart,
        CodeLexState.clean,
      );
      expect(r.tokens, contains(CodeToken(CodeTokenKind.keyword, 'final')));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.type, 'Foo')));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.variable, 'v')));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.function, 'make')));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.number, '1')));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.comment, '// end')));
    });

    test('strings keep backslash escapes and unterminated tails', () {
      final closed = lexCodeLine(
        r"f('a\'b', '" '"x");',
        CodeLang.dart,
        CodeLexState.clean,
      );
      expect(closed.tokens, contains(CodeToken(CodeTokenKind.string, r"'a\'b'")));
      final open = lexCodeLine("'abc", CodeLang.dart, CodeLexState.clean);
      expect(open.tokens, contains(const CodeToken(CodeTokenKind.string, "'abc")));
      expect(open.state.inBlockComment, isFalse);
    });
  });

  group('classification (per language)', () {
    test('every language: keyword / string / number / comment (+ type)', () {
      const fixture = <CodeLang, (String, String)>{
        CodeLang.dart: ('final', 'final Foo v = "t" 42; // c'),
        CodeLang.js: ('const', 'const Foo v = "t" 42; // c'),
        CodeLang.ts: ('const', 'const Foo v = "t" 42; // c'),
        CodeLang.python: ('def', 'def Foo v = "t" 42  # c'),
        CodeLang.bash: ('local', 'local v="t" 42 # c'),
        CodeLang.json: ('true', '{"k": "t", "n": true, "v": 42}'),
        CodeLang.yaml: ('true', 'k: "t" true 42 # c'),
        CodeLang.rust: ('let', 'let Foo v = "t" 42; // c'),
        CodeLang.go: ('var', 'var Foo v = "t" 42 // c'),
      };
      for (final entry in fixture.entries) {
        final lang = entry.key;
        final (keyword, line) = entry.value;
        final r = lexCodeLine(line, lang, CodeLexState.clean);
        expect(
          r.tokens.map((t) => t.text).join(),
          line,
          reason: '$lang round-trip',
        );
        expect(r.tokens, contains(CodeToken(CodeTokenKind.keyword, keyword)),
            reason: '$lang keyword');
        expect(r.tokens.any((t) => t.kind == CodeTokenKind.string),
            isTrue, reason: '$lang string');
        expect(r.tokens, contains(const CodeToken(CodeTokenKind.number, '42')),
            reason: '$lang number');
        if (lang != CodeLang.json) {
          expect(r.tokens.any((t) => t.kind == CodeTokenKind.comment),
              isTrue, reason: '$lang comment');
        }
        if (lang != CodeLang.bash && lang != CodeLang.json && lang != CodeLang.yaml) {
          expect(r.tokens, contains(const CodeToken(CodeTokenKind.type, 'Foo')),
              reason: '$lang type');
        }
        expect(r.state, CodeLexState.clean, reason: '$lang leaves no state');
      }
    });
  });

  group('cross-line state', () {
    test('C block comment carries across lines (c-like)', () {
      var r = lexCodeLine('int x; /* start', CodeLang.dart, CodeLexState.clean);
      expect(r.state.inBlockComment, isTrue);
      expect(r.tokens.last,
          CodeToken(CodeTokenKind.comment, '/* start'));
      r = lexCodeLine('still inside */ int y;', CodeLang.dart, r.state);
      expect(r.state.inBlockComment, isFalse);
      expect(r.tokens.first,
          CodeToken(CodeTokenKind.comment, 'still inside */'));
      expect(r.tokens, contains(CodeToken(CodeTokenKind.variable, 'y')));
    });

    test('non-c-like languages never open block comments', () {
      final r = lexCodeLine('a /* b', CodeLang.python, CodeLexState.clean);
      expect(r.state.inBlockComment, isFalse);
    });

    test('python triple quotes carry and close', () {
      var r = lexCodeLine('s = """first', CodeLang.python, CodeLexState.clean);
      expect(r.state.tripleQuote, '"""');
      r = lexCodeLine('second', CodeLang.python, r.state);
      expect(r.tokens.single, CodeToken(CodeTokenKind.string, 'second'));
      r = lexCodeLine('last"""', CodeLang.python, r.state);
      expect(r.state.tripleQuote, isNull);
    });

    test('snapshot/restore reproduces the continuous lex exactly', () {
      const a = 'Map<String, List<int>> m = {}; /* open';
      const b = 'close */ final x = 2;';
      final continuous = lexCodeLine(b, CodeLang.dart,
          lexCodeLine(a, CodeLang.dart, CodeLexState.clean).state);
      final h = CodeHighlighter(CodeLang.dart);
      h.push(a);
      final restored = lexCodeLine(b, CodeLang.dart, h.snapshot());
      expect(restored.tokens, continuous.tokens);
      expect(restored.state, continuous.state);
    });
  });

  group('styling', () {
    test('profile on: kinds get their pinned SGR and runs merge', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      addTearDown(() => FaThemeController.instance.profile = null);
      final out = highlightCodeLine(
        'final x = 1; // c',
        CodeLang.dart,
        CodeLexState.clean,
      );
      expect(out, contains(codeTokenSgr(CodeTokenKind.keyword)));
      expect(out, contains(codeTokenSgr(CodeTokenKind.comment)));
      // Adjacent same-kind tokens merge into one escape run.
      final twoVars = highlightCodeLine(
        'ab cd',
        CodeLang.dart,
        CodeLexState.clean,
      );
      expect('ab cd'.split(' ').every(twoVars.contains), isTrue);
      expect(twoVars, startsWith(codeTokenSgr(CodeTokenKind.variable)));
      expect(twoVars, endsWith('\x1b[0m'));
    });

    test('profile off: byte-identical plain line', () {
      FaThemeController.instance.profile = null;
      const line = 'final x = 1;';
      expect(
        highlightCodeLine(line, CodeLang.dart, CodeLexState.clean),
        line,
      );
    });

    test('operators and plain runs stay at the default fg', () {
      FaThemeController.instance.profile = ColorProfile.trueColor;
      addTearDown(() => FaThemeController.instance.profile = null);
      expect(codeTokenSgr(CodeTokenKind.operator), '');
      expect(codeTokenSgr(CodeTokenKind.plain), '');
      final out = highlightCodeLine('a + b', CodeLang.dart, CodeLexState.clean);
      // The operator segment sits between two resets, unstyled: a styled
      // `+` would carry its own SGR prefix instead.
      expect(out, contains('\x1b[0m + '));
    });

    test('light themes resolve the Light+ equivalents (not the Dark+ pins)',
        () {
      final controller = FaThemeController.instance;
      controller
        ..reset()
        ..profile = ColorProfile.trueColor;
      addTearDown(controller.reset);
      final darkKeyword = codeTokenSgr(CodeTokenKind.keyword);
      expect(darkKeyword, '\x1b[38;2;86;156;214m');
      controller.switchTo('ohmypi-light');
      expect(codeTokenSgr(CodeTokenKind.keyword), '\x1b[38;2;0;0;255m');
      expect(codeTokenSgr(CodeTokenKind.comment), '\x1b[38;2;0;128;0m');
    });

    test('a mid-session theme flip re-resolves the cached SGR', () {
      final controller = FaThemeController.instance;
      controller
        ..reset()
        ..profile = ColorProfile.trueColor;
      addTearDown(controller.reset);
      final dark = codeTokenSgr(CodeTokenKind.string);
      controller.switchTo('ohmypi-light');
      expect(codeTokenSgr(CodeTokenKind.string), isNot(dark));
      controller.reset();
      expect(codeTokenSgr(CodeTokenKind.string), dark);
    });
  });

  group('fence tag mapping', () {
    test('decision-D3 aliases resolve; unknown tags fall back', () {
      expect(codeLanguageOfTag('dart'), CodeLang.dart);
      expect(codeLanguageOfTag('dartlang'), CodeLang.dart);
      expect(codeLanguageOfTag('ts'), CodeLang.ts);
      expect(codeLanguageOfTag('tsx'), CodeLang.ts);
      expect(codeLanguageOfTag('python3'), CodeLang.python);
      expect(codeLanguageOfTag('shell'), CodeLang.bash);
      expect(codeLanguageOfTag('jsonc'), CodeLang.json);
      expect(codeLanguageOfTag('yml'), CodeLang.yaml);
      expect(codeLanguageOfTag('rs'), CodeLang.rust);
      expect(codeLanguageOfTag('golang'), CodeLang.go);
      expect(codeLanguageOfTag('perl'), isNull);
      expect(codeLanguageOfTag(''), isNull);
      expect(codeLanguageOfTag(null), isNull);
    });
  });
}
