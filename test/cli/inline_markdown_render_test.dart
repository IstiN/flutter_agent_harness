import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';
import 'package:test/test.dart';

void main() {
  group('renderInlineMarkdown', () {
    test('renders bold spans', () {
      expect(
        renderInlineMarkdown('hello **bold** world'),
        'hello \x1b[1mbold\x1b[22m world',
      );
    });

    test('renders italic spans', () {
      expect(
        renderInlineMarkdown('a *little* skew'),
        'a \x1b[3mlittle\x1b[23m skew',
      );
    });

    test('renders inline code with dim/light style', () {
      expect(
        renderInlineMarkdown('use `foo()` here'),
        'use \x1b[2m\x1b[37mfoo()\x1b[0m here',
      );
    });

    test('leaves a lone backtick as literal text', () {
      expect(renderInlineMarkdown('one ` stuck'), 'one ` stuck');
    });

    test('handles empty input', () {
      expect(renderInlineMarkdown(''), '');
    });

    test('strips bold before italic (greedy ** wins)', () {
      final rendered = renderInlineMarkdown('plain **only-bold** tail');
      expect(rendered, contains('\x1b[1monly-bold\x1b[22m'));
      expect(rendered, isNot(contains('\x1b[3m')));
    });

    test('bold wins over italic when both markers are present', () {
      final rendered = renderInlineMarkdown('**keep *italic* inside**');
      expect(rendered, contains('\x1b[1m'));
      expect(rendered, contains('\x1b[22m'));
    });

    test('leaves unmatched markers as literal text', () {
      final rendered = renderInlineMarkdown('plain text with trailing *');
      expect(rendered, 'plain text with trailing *');
    });

    test('returns the original text verbatim when there is no markup', () {
      expect(renderInlineMarkdown('plain text'), 'plain text');
    });
  });
}
