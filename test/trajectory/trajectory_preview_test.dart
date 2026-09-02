import 'package:flutter_agent_harness/src/trajectory/trajectory_preview.dart';
import 'package:test/test.dart';

void main() {
  group('trajectoryPreviewText', () {
    test('plain text passes through unchanged', () {
      expect(trajectoryPreviewText('just words'), 'just words');
    });

    test('strips headings, emphasis, links, and images', () {
      expect(
        trajectoryPreviewText('# Title\n**bold** and *em* text'),
        'Title bold and em text',
      );
      expect(
        trajectoryPreviewText('see [docs](https://example.com) now'),
        'see docs now',
      );
      expect(trajectoryPreviewText('![alt text](img.png)'), 'alt text');
    });

    test('keeps fenced code source but drops the fence markers', () {
      expect(
        trajectoryPreviewText('before\n```dart\nmain();\n```\nafter'),
        'before main(); after',
      );
    });

    test('strips list markers and blockquotes', () {
      expect(trajectoryPreviewText('- one\n- two\n> quoted'), 'one two quoted');
    });

    test('collapses all whitespace runs to single spaces', () {
      expect(trajectoryPreviewText('a\n\n  b\t\tc   d'), 'a b c d');
    });

    test('appends an ellipsis when the source is sliced at 2048', () {
      final text = 'x' * 3000;
      final preview = trajectoryPreviewText(text);
      expect(preview.length, 513);
      expect(preview.endsWith('…'), isTrue);
    });
    test('caps the collapsed preview at 512 with an ellipsis', () {
      final text = List.generate(200, (i) => 'word$i').join(' ');
      final preview = trajectoryPreviewText(text);
      expect(preview.length, 513);
      expect(preview.endsWith('…'), isTrue);
      expect(preview.startsWith('word0'), isTrue);
    });

    test('text within both bounds gets no ellipsis', () {
      expect(trajectoryPreviewText('x' * 512), 'x' * 512);
      expect(trajectoryPreviewText(''), '');
    });

    test('empty markdown scaffolding collapses to nothing', () {
      expect(trajectoryPreviewText('## \n> \n- '), '');
    });
  });
}
