import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('fah_headless_prompt_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  String filePath(String name) => '${tempDir.path}/$name';

  File writeFile(String name, String content) {
    final file = File(filePath(name))..writeAsStringSync(content);
    return file;
  }

  group('resolveHeadlessPrompt', () {
    test('no prompt and no positionals means interactive REPL (null)', () {
      expect(resolveHeadlessPrompt(), isNull);
      expect(resolveHeadlessPrompt(positionals: const []), isNull);
    });

    test('-p text is used verbatim, never resolved as a file', () {
      final file = writeFile('notes.md', 'file content');
      expect(
        resolveHeadlessPrompt(prompt: file.path),
        file.path, // the literal text, not the file content
      );
    });

    test('a markdown file is inlined as the prompt', () {
      final file = writeFile('CHANGELOG.md', '# Changelog\n\n- stuff\n');
      expect(
        resolveHeadlessPrompt(positionals: [file.path]),
        '# Changelog\n\n- stuff\n',
      );
    });

    test('.markdown and .txt files are inlined too', () {
      final markdown = writeFile('doc.markdown', 'markdown body');
      final txt = writeFile('notes.txt', 'txt body');
      expect(
        resolveHeadlessPrompt(positionals: [markdown.path]),
        'markdown body',
      );
      expect(resolveHeadlessPrompt(positionals: [txt.path]), 'txt body');
    });

    test('the extension match is case-insensitive', () {
      final file = writeFile('README.MD', 'upper');
      expect(resolveHeadlessPrompt(positionals: [file.path]), 'upper');
    });

    test('trailing text after a text file appends as the instruction', () {
      final file = writeFile('CHANGELOG.md', 'changelog body');
      expect(
        resolveHeadlessPrompt(positionals: [file.path, 'summarize', 'this']),
        'changelog body\n\nsummarize this',
      );
    });

    test('a binary file becomes a path reference', () {
      final file = File(filePath('image.png'))
        ..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47]);
      expect(
        resolveHeadlessPrompt(positionals: [file.path]),
        '[attached file: ${file.absolute.path} — read it with your tools]',
      );
    });

    test('trailing text after a binary file appends as the instruction', () {
      final file = File(filePath('image.png'))
        ..writeAsBytesSync(const [0x89, 0x50, 0x4E, 0x47]);
      expect(
        resolveHeadlessPrompt(positionals: [file.path, 'describe it']),
        '[attached file: ${file.absolute.path} — read it with your tools]'
        '\n\ndescribe it',
      );
    });

    test(
      'a text file that fails to decode falls back to the path reference',
      () {
        final file = File(filePath('broken.txt'))
          ..writeAsBytesSync(const [0xFF, 0xFE, 0x00, 0x80]);
        expect(
          resolveHeadlessPrompt(positionals: [file.path]),
          '[attached file: ${file.absolute.path} — read it with your tools]',
        );
      },
    );

    test('a missing file is plain prompt text, joined with the rest', () {
      final missing = filePath('does-not-exist.md');
      expect(
        resolveHeadlessPrompt(positionals: [missing, 'please']),
        '$missing please',
      );
    });

    test('a sentence containing slashes is not treated as a file', () {
      expect(
        resolveHeadlessPrompt(positionals: const ['what does lib/src do?']),
        'what does lib/src do?',
      );
    });

    test('plain positionals join with spaces', () {
      expect(
        resolveHeadlessPrompt(positionals: const ['fix', 'the', 'typos']),
        'fix the typos',
      );
    });

    test('relative paths resolve against the process working directory', () {
      writeFile('notes.md', 'relative body');
      final previous = Directory.current;
      Directory.current = tempDir;
      try {
        expect(
          resolveHeadlessPrompt(positionals: const ['notes.md']),
          'relative body',
        );
      } finally {
        Directory.current = previous;
      }
    });
  });
}
