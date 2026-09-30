import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

// TEMP repro for PR review: rotation seed-write failure restores the
// primary from the part but LEAVES THE PART IN PLACE — a reopen then
// loads every record of that segment TWICE.
class FlakySeedFs implements FileSystem, RenamableFileSystem {
  FlakySeedFs(this._inner, this.failWritePathOnce);
  final FileSystem _inner;
  final String failWritePathOnce;
  bool _failed = false;

  /// Arm the injected failure (after session create).
  set armed(bool value) => _armed = value;
  bool _armed = false;

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
  }) =>
      _inner.readTextLines(path, maxLines: maxLines);

  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) =>
      _inner.writeBinaryFile(path, content);

  @override
  Future<Result<void, FileError>> writeFile(String path, String content) async {
    if (_armed && !_failed && path == failWritePathOnce) {
      _failed = true;
      return Err(
        const FileError(FileErrorCode.unknown, 'injected seed failure'),
      );
    }
    return _inner.writeFile(path, content);
  }

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
  }) =>
      _inner.createDir(path, recursive: recursive);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) =>
      _inner.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<void, FileError>> renamePath(String from, String to) =>
      _inner is RenamableFileSystem
          ? (_inner as RenamableFileSystem).renamePath(from, to)
          : Future.value(
              const Err(FileError(FileErrorCode.unknown, 'no rename')),
            );
}

void main() {
  test('seed-failure restore must not duplicate records on reopen', () async {
    final fs = FlakySeedFs(MemoryFileSystem(), '/sessions/seed.jsonl');
    const path = '/sessions/seed.jsonl';
    final created = await JsonlSessionStorage.create(
      fs,
      path,
      cwd: '/work',
      sessionId: 's1',
    );
    fs.armed = true;
    final storage = created.withRotationLimits(
      rotateBytes: 200,
      hardCapBytes: 1 << 30,
    );
    await storage.appendEntry(
      MessageRecord(
        id: 'e1',
        parentId: null,
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('x' * 180),
      ),
    );
    // This append triggers rotation; the seed write fails (injected) and
    // the code restores the primary from the part.
    await storage.appendEntry(
      MessageRecord(
        id: 'e2',
        parentId: 'e1',
        timestamp: DateTime.utc(2026),
        message: UserMessage.text('e2'),
      ),
    );
    final part = await fs.exists('$path.part-0001');
    // ignore: avoid_print
    print('part-0001 exists after failed rotation: ${part.getOrThrow()}');
    final reopened = await JsonlSessionStorage.open(fs, path);
    final ids = (await reopened.getEntries()).map((e) => e.id).toList();
    // ignore: avoid_print
    print('reopened entries: $ids');
    expect(
      ids,
      ['e1', 'e2'],
      reason: 'restore must not leave the part behind (duplicates)',
    );
  });
}
