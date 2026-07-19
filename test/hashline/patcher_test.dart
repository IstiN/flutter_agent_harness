import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  late MemoryExecutionEnv env;
  late HashlineSnapshotStore store;
  late HashlinePatcher patcher;

  const content = 'alpha\nbeta\ngamma\ndelta\n';

  setUp(() async {
    env = MemoryExecutionEnv(cwd: '/w');
    store = HashlineSnapshotStore();
    patcher = HashlinePatcher(env: env, snapshots: store);
    await env.writeFile('a.txt', content);
  });

  /// Records a full read of [path] the way the hashline read tool does and
  /// returns the tag a model would cite.
  Future<String> recordFullRead(String path, [String? text]) async {
    final body = text ?? (await env.readTextFile(path)).valueOrNull!;
    final normalized = normalizeToLF(stripBom(body).text);
    final canonical = (await env.absolutePath(path)).valueOrNull ?? path;
    return store.record(canonical, normalized, [
      for (var i = 1; i <= normalized.split('\n').length; i++) i,
    ]);
  }

  group('HashlinePatcher: happy path', () {
    test('applies a SWAP against the tagged content', () async {
      final tag = await recordFullRead('a.txt');
      final result = await patcher.apply(
        HashlinePatch.parse('[a.txt#$tag]\nSWAP 2.=2:\n+BETA'),
      );
      final section = result.sections.single;
      expect(section.op, HashlineSectionOp.update);
      expect(section.after, 'alpha\nBETA\ngamma\ndelta\n');
      expect(section.firstChangedLine, 2);
      expect(section.header, startsWith('[a.txt#'));
      expect(section.fileHash, computeFileHash('alpha\nBETA\ngamma\ndelta\n'));
      expect(
        (await env.readTextFile('a.txt')).valueOrNull,
        'alpha\nBETA\ngamma\ndelta\n',
      );
    });

    test('commit records a fresh snapshot usable for a chained edit', () async {
      final tag = await recordFullRead('a.txt');
      final first = await patcher.apply(
        HashlinePatch.parse('[a.txt#$tag]\nDEL 1'),
      );
      final newTag = first.sections.single.fileHash;
      final second = await patcher.apply(
        HashlinePatch.parse('[a.txt#$newTag]\nDEL 1'),
      );
      expect(second.sections.single.after, 'gamma\ndelta\n');
    });

    test(
      'INS.HEAD/TAIL with a stale tag applies with a drift warning',
      () async {
        final staleTag = await recordFullRead('a.txt');
        await env.writeFile('a.txt', 'externally\n$content');
        final result = await patcher.apply(
          HashlinePatch.parse('[a.txt#$staleTag]\nINS.TAIL:\n+tail'),
        );
        final section = result.sections.single;
        expect(section.after, 'externally\n${content}tail\n');
        expect(section.warnings, contains(headTailDriftWarning));
      },
    );

    test('parse warnings flow into the section result', () async {
      final tag = await recordFullRead('a.txt');
      final result = await patcher.apply(
        HashlinePatch.parse('[a.txt#$tag]\nSWAP 2.=2:\nbare row'),
      );
      expect(
        result.sections.single.warnings,
        contains(bareBodyAutoPipedWarning),
      );
    });

    test('CRLF content round-trips as CRLF', () async {
      await env.writeFile('crlf.txt', 'one\r\ntwo\r\n');
      final tag = await recordFullRead('crlf.txt');
      await patcher.apply(
        HashlinePatch.parse('[crlf.txt#$tag]\nSWAP 1.=1:\n+ONE'),
      );
      expect(
        (await env.readTextFile('crlf.txt')).valueOrNull,
        'ONE\r\ntwo\r\n',
      );
    });

    test('a UTF-8 BOM survives the edit', () async {
      await env.writeFile('bom.txt', '\uFEFFone\ntwo\n');
      final tag = await recordFullRead('bom.txt');
      await patcher.apply(
        HashlinePatch.parse('[bom.txt#$tag]\nSWAP 1.=1:\n+ONE'),
      );
      // The env's utf8.decode hides a leading BOM on text reads (Dart
      // semantics), so assert on the raw bytes (omp #3867).
      final bytes = (await env.readBinaryFile('bom.txt')).valueOrNull!;
      expect(bytes.take(3).toList(), [0xEF, 0xBB, 0xBF]);
      expect(String.fromCharCodes(bytes.skip(3)), 'ONE\ntwo\n');
    });
  });

  group('HashlinePatcher: missing tag / file', () {
    test('a section without a tag is rejected', () async {
      await recordFullRead('a.txt');
      expect(
        () => patcher.apply(HashlinePatch.parse('[a.txt]\nDEL 1')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Missing hashline snapshot tag'),
          ),
        ),
      );
    });

    test('a missing file points at the write tool', () async {
      expect(
        () => patcher.apply(HashlinePatch.parse('[nope.txt#1A2B]\nDEL 1')),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('File not found: nope.txt'),
          ),
        ),
      );
    });

    test('a bare filename recovers onto the tagged in-session file', () async {
      await env.writeFile('src/deep/widget.txt', content);
      final tag = await recordFullRead('src/deep/widget.txt');
      final result = await patcher.apply(
        HashlinePatch.parse('[widget.txt#$tag]\nDEL 1'),
      );
      final section = result.sections.single;
      expect(section.path, '/w/src/deep/widget.txt');
      expect(section.warnings.single, contains('does not exist'));
      expect(
        (await env.readTextFile('src/deep/widget.txt')).valueOrNull,
        'beta\ngamma\ndelta\n',
      );
    });

    test('path recovery declines ambiguous matches', () async {
      await env.writeFile('x/dup.txt', content);
      await env.writeFile('y/dup.txt', content);
      // Record two DIFFERENT paths whose contents share one tag.
      await recordFullRead('x/dup.txt');
      await recordFullRead('y/dup.txt');
      expect(
        () => patcher.apply(
          HashlinePatch.parse('[dup.txt#${computeFileHash(content)}]\nDEL 1'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('File not found'),
          ),
        ),
      );
    });
  });

  group('HashlinePatcher: stale tag rejection (drift)', () {
    test('anchored edits on drifted content reject BEFORE any write', () async {
      final tag = await recordFullRead('a.txt');
      await env.writeFile('a.txt', 'changed\nbeta\ngamma\ndelta\n');
      expect(
        () => patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nSWAP 2.=2:\n+BETA'),
        ),
        throwsA(isA<HashlineMismatchError>()),
      );
      // Nothing was written.
      expect(
        (await env.readTextFile('a.txt')).valueOrNull,
        'changed\nbeta\ngamma\ndelta\n',
      );
    });

    test('the mismatch error names the drifted anchor lines', () async {
      final tag = await recordFullRead('a.txt');
      await env.writeFile('a.txt', 'changed\nbeta\ngamma\ndelta\n');
      try {
        await patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nSWAP 2.=2:\n+BETA'),
        );
        fail('expected HashlineMismatchError');
      } on HashlineMismatchError catch (error) {
        expect(error.hashRecognized, isTrue);
        expect(error.expectedFileHash, tag);
        expect(error.anchorLines, [2]);
        final message = error.toString();
        expect(message, contains('file changed between read and edit'));
        expect(message, contains('*2:beta'));
        expect(message, contains('1:changed'));
        expect(message, contains('3:gamma'));
      }
    });

    test('an unrecognized tag says it is not from this session', () async {
      try {
        await patcher.apply(HashlinePatch.parse('[a.txt#FFFF]\nDEL 1'));
        fail('expected HashlineMismatchError');
      } on HashlineMismatchError catch (error) {
        expect(error.hashRecognized, isFalse);
        expect(
          error.toString(),
          contains('hash #FFFF is not from this session'),
        );
      }
    });

    test('the fresh tag in a mismatch message is immediately usable', () async {
      final tag = await recordFullRead('a.txt');
      await env.writeFile('a.txt', 'changed\nbeta\ngamma\ndelta\n');
      String? freshTag;
      try {
        await patcher.apply(HashlinePatch.parse('[a.txt#$tag]\nDEL 1'));
      } on HashlineMismatchError catch (error) {
        freshTag = error.actualFileHash;
      }
      expect(freshTag, isNotNull);
      final result = await patcher.apply(
        HashlinePatch.parse('[a.txt#$freshTag]\nDEL 1'),
      );
      expect(result.sections.single.after, 'beta\ngamma\ndelta\n');
    });

    test(
      'a tag from a prior session version still validates by content',
      () async {
        // The tag is content-derived: recording is only provenance. A tag that
        // matches the live content applies even if the store never saw it.
        final tag = computeFileHash(content);
        final result = await patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nDEL 1'),
        );
        expect(result.sections.single.op, HashlineSectionOp.update);
      },
    );
  });

  group('HashlinePatcher: seen-line guard', () {
    test(
      'anchors on lines a partial read never displayed are rejected',
      () async {
        // Read only lines 1-2 (like a `read` with limit: 2).
        final canonical = (await env.absolutePath('a.txt')).valueOrNull!;
        final tag = store.record(canonical, content, [1, 2]);
        expect(
          () => patcher.apply(
            HashlinePatch.parse('[a.txt#$tag]\nSWAP 4.=4:\n+DELTA'),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('never displayed'),
                contains('4:delta'), // reveals the actual content inline
              ),
            ),
          ),
        );
      },
    );

    test(
      'a full reveal merges the lines so a straight retry succeeds',
      () async {
        final canonical = (await env.absolutePath('a.txt')).valueOrNull!;
        final tag = store.record(canonical, content, [1, 2]);
        // First attempt: rejected, but the reveal covers every unseen anchor
        // line in full width, so those lines merge into the seen set.
        await expectLater(
          patcher.apply(
            HashlinePatch.parse('[a.txt#$tag]\nSWAP 4.=4:\n+DELTA'),
          ),
          throwsA(isA<StateError>()),
        );
        final retry = await patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nSWAP 4.=4:\n+DELTA'),
        );
        expect(retry.sections.single.after, 'alpha\nbeta\ngamma\nDELTA\n');
      },
    );

    test('no provenance recorded → the guard is skipped', () async {
      final canonical = (await env.absolutePath('a.txt')).valueOrNull!;
      final tag = store.record(canonical, content); // no seenLines
      final result = await patcher.apply(
        HashlinePatch.parse('[a.txt#$tag]\nSWAP 4.=4:\n+DELTA'),
      );
      expect(result.sections.single.op, HashlineSectionOp.update);
    });

    test('enforceSeenLines: false disables the guard', () async {
      final lax = HashlinePatcher(
        env: env,
        snapshots: store,
        enforceSeenLines: false,
      );
      final canonical = (await env.absolutePath('a.txt')).valueOrNull!;
      final tag = store.record(canonical, content, [1]);
      final result = await lax.apply(
        HashlinePatch.parse('[a.txt#$tag]\nDEL 4'),
      );
      expect(result.sections.single.after, 'alpha\nbeta\ngamma\n');
    });
  });

  group('HashlinePatcher: no-op and multi-section', () {
    test(
      'single-section no-op returns a noop result and writes nothing',
      () async {
        final tag = await recordFullRead('a.txt');
        final result = await patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nSWAP 2.=2:\n+beta'),
        );
        final section = result.sections.single;
        expect(section.op, HashlineSectionOp.noop);
        expect(section.after, content);
        expect((await env.readTextFile('a.txt')).valueOrNull, content);
      },
    );

    test('multi-section applies all files in order', () async {
      await env.writeFile('b.txt', 'one\ntwo\n');
      final tagA = await recordFullRead('a.txt');
      final tagB = await recordFullRead('b.txt');
      final result = await patcher.apply(
        HashlinePatch.parse(
          '[a.txt#$tagA]\nDEL 1\n[b.txt#$tagB]\nSWAP 1.=1:\n+ONE',
        ),
      );
      expect(result.sections, hasLength(2));
      expect(
        (await env.readTextFile('a.txt')).valueOrNull,
        'beta\ngamma\ndelta\n',
      );
      expect((await env.readTextFile('b.txt')).valueOrNull, 'ONE\ntwo\n');
    });

    test(
      'multi-section is all-or-nothing: a stale section blocks every write',
      () async {
        await env.writeFile('b.txt', 'one\ntwo\n');
        final tagA = await recordFullRead('a.txt');
        await recordFullRead('b.txt');
        await env.writeFile('b.txt', 'drifted\ntwo\n'); // invalidate b's tag
        expect(
          () => patcher.apply(
            HashlinePatch.parse('[a.txt#$tagA]\nDEL 1\n[b.txt#FFFF]\nDEL 1'),
          ),
          throwsA(isA<HashlineMismatchError>()),
        );
        // a.txt was NOT written even though its section was valid.
        expect((await env.readTextFile('a.txt')).valueOrNull, content);
      },
    );

    test(
      'multi-section no-op section fails the batch before any write',
      () async {
        await env.writeFile('b.txt', 'one\ntwo\n');
        final tagA = await recordFullRead('a.txt');
        final tagB = await recordFullRead('b.txt');
        expect(
          () => patcher.apply(
            HashlinePatch.parse(
              '[a.txt#$tagA]\nDEL 1\n[b.txt#$tagB]\nSWAP 1.=1:\n+one',
            ),
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('produced no change'),
            ),
          ),
        );
        expect((await env.readTextFile('a.txt')).valueOrNull, content);
      },
    );

    test('sections merged for one path apply as one batch', () async {
      final tag = await recordFullRead('a.txt');
      final result = await patcher.apply(
        HashlinePatch.parse('[a.txt#$tag]\nDEL 1\n[a.txt#$tag]\nDEL 2'),
      );
      expect(result.sections, hasLength(1));
      // Both deletes index the ORIGINAL lines: 1 (alpha) and 2 (beta).
      expect(result.sections.single.after, 'gamma\ndelta\n');
    });
  });

  group('HashlinePatcher: edge cases', () {
    test('two sections resolving to one canonical path are rejected', () async {
      final tag = await recordFullRead('a.txt');
      expect(
        () => patcher.apply(
          HashlinePatch.parse('[a.txt#$tag]\nDEL 1\n[/w/a.txt#$tag]\nDEL 2'),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('resolve to the same file'),
          ),
        ),
      );
    });

    test('a non-notFound read error surfaces as a StateError', () async {
      await env.createDir('dir');
      expect(
        () => patcher.prepare(HashlinePatch.parseSingle('[dir#1A2B]\nDEL 1')),
        throwsA(isA<StateError>()),
      );
    });

    test(
      'a mid-batch write failure reports written and pending sections',
      () async {
        await env.writeFile('b.txt', 'one\ntwo\n');
        final tagA = await recordFullRead('a.txt');
        final tagB = await recordFullRead('b.txt');
        final failing = _FailWriteEnv(env, failOn: 'b.txt');
        final failingPatcher = HashlinePatcher(env: failing, snapshots: store);
        try {
          await failingPatcher.apply(
            HashlinePatch.parse('[a.txt#$tagA]\nDEL 1\n[b.txt#$tagB]\nDEL 1'),
          );
          fail('expected a write failure');
        } on StateError catch (error) {
          expect(error.message, contains('Failed to write b.txt'));
          expect(error.message, contains('Sections already written: a.txt'));
          expect(error.message, isNot(contains('Sections not written')));
        }
      },
    );

    test(
      'a >512-column unseen line truncates the reveal and blocks merging',
      () async {
        final wide = 'x' * 600;
        await env.writeFile('wide.txt', 'top\n$wide\n');
        final canonical = (await env.absolutePath('wide.txt')).valueOrNull!;
        final tag = store.record(canonical, 'top\n$wide\n', [1]);
        try {
          await patcher.apply(
            HashlinePatch.parse('[wide.txt#$tag]\nSWAP 2.=2:\n+narrow'),
          );
          fail('expected an unseen-lines rejection');
        } on StateError catch (error) {
          expect(error.message, contains('exceeds the inline preview cap'));
          expect(error.message, isNot(contains('straight retry')));
        }
        // The reveal was truncated, so the lines did NOT merge: a retry with
        // the same patch is rejected again rather than sailing through.
        expect(
          () => patcher.apply(
            HashlinePatch.parse('[wide.txt#$tag]\nSWAP 2.=2:\n+narrow'),
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test(
      'an out-of-range unseen anchor reveals nothing and tells to re-read',
      () async {
        final canonical = (await env.absolutePath('a.txt')).valueOrNull!;
        final tag = store.record(canonical, content, [1]);
        expect(
          () => patcher.apply(HashlinePatch.parse('[a.txt#$tag]\nDEL 99')),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('Re-read those lines first'),
            ),
          ),
        );
      },
    );

    test(
      'a trailing-slash authored path still basename-matches for recovery',
      () async {
        await env.writeFile('src/deep/widget.txt', content);
        final tag = await recordFullRead('src/deep/widget.txt');
        final result = await patcher.apply(
          HashlinePatch.parse('[deep/widget.txt/#$tag]\nDEL 1'),
        );
        expect(result.sections.single.path, '/w/src/deep/widget.txt');
      },
    );
  });
}

/// An [ExecutionEnv] delegating to a memory env whose [writeFile] fails for
/// one configured path — exercises the patcher's mid-batch write-failure
/// reporting.
final class _FailWriteEnv implements ExecutionEnv {
  _FailWriteEnv(this._inner, {required this.failOn});

  final ExecutionEnv _inner;
  final String failOn;

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) {
    if (path == failOn) {
      return Future.value(
        const Err(FileError(FileErrorCode.permissionDenied, 'denied')),
      );
    }
    return _inner.writeFile(path, content);
  }

  @override
  String get cwd => _inner.cwd;

  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _inner.absolutePath(path);

  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _inner.joinPath(parts);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _inner.readTextFile(path);

  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _inner.readBinaryFile(path);

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) => _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _inner.appendFile(path, content);

  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _inner.fileInfo(path);

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _inner.listDir(path);

  @override
  Future<Result<bool, FileError>> exists(String path) => _inner.exists(path);

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _inner.exec(command, options: options);
}
