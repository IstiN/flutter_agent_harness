import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/headless_prompt.dart';
import 'package:test/test.dart';

void main() {
  // Registry-free factory: paths listed in the map exist with the mapped
  // content (null = exists but binary/undecodable); anything else does
  // not exist on disk.
  InputPromptFileFactory factory(Map<String, String?> files) =>
      (path) => _StubFile(
        path,
        doesExist: files.containsKey(path),
        content: files[path],
      );

  group('resolveInteractiveFileReference', () {
    test('absolute .txt path becomes an attachment reference with stats', () {
      const path = '/tmp/pasted/clip_123.txt';
      final result = resolveInteractiveFileReference(
        '$path sum this up',
        fileOf: factory({'/tmp/pasted/clip_123.txt': 'alpha\nbeta'}),
      );
      expect(
        result,
        '[attached file: $path (10 B · 2 lines · ~3 tokens est.)'
        ' — read it with your tools]\n\nsum this up',
      );
    });

    test('a multi-line paste gets an accurate line count', () {
      const path = '/tmp/pasted/code.dart';
      final result = resolveInteractiveFileReference(
        path,
        fileOf: factory({path: 'void a() {}\nvoid b() {}\nvoid c() {}'}),
      );
      expect(
        result,
        '[attached file: $path (35 B · 3 lines · ~9 tokens est.)'
        ' — read it with your tools]',
      );
    });

    test('large text shows k-scale token estimate, never content', () {
      final path = '/tmp/huge.log';
      final result = resolveInteractiveFileReference(
        path,
        fileOf: factory({path: 'x' * 100000}),
      );
      expect(
        result,
        '[attached file: $path (97.7 KB · 1 line · ~25k tokens est.)'
        ' — read it with your tools]',
      );
      expect(result.length, lessThan(200));
    });

    test('path-only paste yields just the reference', () {
      const path = '/tmp/pasted/notes.md';
      final result = resolveInteractiveFileReference(
        path,
        fileOf: factory({path: '# Notes'}),
      );
      expect(
        result,
        '[attached file: $path (7 B · 1 line · ~2 tokens est.)'
        ' — read it with your tools]',
      );
    });

    test('binary file reports only its size', () {
      const path = '/tmp/pasted/data.bin';
      final result = resolveInteractiveFileReference(
        '$path what is inside?',
        fileOf: factory({path: null}),
      );
      expect(result.contains('lines'), isFalse);
      expect(result.contains('tokens'), isFalse);
      expect(result.startsWith('[attached file: $path ('), isTrue);
      expect(
        result.endsWith(
          'B) — read it with your tools]\n\nwhat is '
          'inside?',
        ),
        isTrue,
      );
    });

    test('a text-extension file with undecodable content still attaches', () {
      const path = '/Users/x/reports.md';
      final result = resolveInteractiveFileReference(
        path,
        fileOf: factory({path: null}),
      );
      expect(result.startsWith('[attached file: $path ('), isTrue);
      expect(result.endsWith('— read it with your tools]'), isTrue);
    });

    test('oversized files are not read just for stats', () {
      var readCount = 0;
      final result = resolveInteractiveFileReference(
        '/tmp/giant.log',
        fileOf: (path) => _StubFile(
          path,
          doesExist: true,
          content: 'x' * 100,
          lengthOverride: 16 * 1024 * 1024,
          onRead: () => readCount++,
        ),
      );
      expect(readCount, 0);
      expect(
        result.startsWith('[attached file: /tmp/giant.log (16.0 MB)'),
        isTrue,
      );
      expect(result.contains('tokens'), isFalse);
    });

    test('nonexistent path stays literal text', () {
      const text = '/no/such/file.txt hello';
      expect(
        resolveInteractiveFileReference(text, fileOf: factory(const {})),
        text,
      );
    });

    test('plain sentences stay untouched', () {
      const text = 'please review lib/src/cli/agent_cli.dart';
      expect(
        resolveInteractiveFileReference(text, fileOf: factory(const {})),
        text,
      );
    });

    test('relative ./ and ~/ references resolve like absolute ones', () {
      expect(
        resolveInteractiveFileReference(
          './README.md explain',
          fileOf: factory({'./README.md': '# readme'}),
        ),
        startsWith('[attached file: ./README.md ('),
      );
      expect(
        resolveInteractiveFileReference(
          '~/notes.txt',
          fileOf: factory({'~/notes.txt': 'hi'}),
        ),
        '[attached file: ~/notes.txt (2 B · 1 line · ~1 tokens est.)'
        ' — read it with your tools]',
      );
    });

    test('a bare word never resolves even when it looks like one token', () {
      // No path-like prefix -> never treated as a file.
      const text = 'README.md explain';
      expect(
        resolveInteractiveFileReference(text, fileOf: factory(const {})),
        text,
      );
    });

    test('leading whitespace is tolerated', () {
      const path = '/tmp/a.txt';
      expect(
        resolveInteractiveFileReference(
          '\n $path',
          fileOf: factory({path: 'body'}),
        ),
        '[attached file: $path (4 B · 1 line · ~1 tokens est.)'
        ' — read it with your tools]',
      );
    });
  });
}

/// Minimal [File] stand-in used through the [InputPromptFileFactory]
/// injection point.
final class _StubFile implements File {
  _StubFile(
    this.path, {
    required this.doesExist,
    this.content,
    this.lengthOverride,
    this.onRead,
  });

  @override
  final String path;

  final bool doesExist;

  /// null models an undecodable (binary) file.
  final String? content;

  /// Overrides [lengthSync] independent of [content] (simulates files
  /// bigger than the stats-read cap).
  final int? lengthOverride;

  /// Invoked whenever the resolver reads content (oversize-cap assertion).
  final void Function()? onRead;

  @override
  late final File absolute = this;

  @override
  bool existsSync() => doesExist;

  @override
  int lengthSync() => lengthOverride ?? content?.length ?? 0;

  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    onRead?.call();
    final value = content;
    if (value == null) {
      throw FileSystemException('undecodable', path);
    }
    return value;
  }

  @override
  Object noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
