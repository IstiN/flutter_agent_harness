@TestOn('vm')
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/chats/local_chat_list_adapter.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

/// P3 regression: ONE unreadable session file (or one directory that
/// fails to list — the transient-ENOENT host family) must not blank the
/// sidebar. The listing pipeline used to fail the whole store listing on
/// such an entry, and `listPersistedSessions` swallowed the failure into
/// `const []` — "локальных сессий не видно" while the store on disk was
/// perfectly readable. The pipeline now skips the bad entry; these tests
/// pin the degrade-not-vanish contract at the manager and adapter level.

/// A [FileSystem] wrapper whose chosen paths fail persistently with a
/// storage-shaped error — the state a session file or directory can be
/// in mid-walk (deleted between listDir and read, permission revoked).
class _BrokenIoFs implements FileSystem {
  _BrokenIoFs(this._delegate);

  final FileSystem _delegate;

  /// Session file paths whose header read fails.
  final Set<String> unreadableFiles = {};

  /// Directory paths whose listDir fails.
  final Set<String> unlistableDirs = {};

  @override
  Future<Result<List<String>, FileError>> readTextLines(
    String path, {
    int? maxLines,
  }) async {
    if (unreadableFiles.contains(path)) {
      return Err(FileError(FileErrorCode.unknown, 'simulated unreadable'));
    }
    return _delegate.readTextLines(path, maxLines: maxLines);
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) async {
    if (unlistableDirs.contains(path)) {
      return Err(FileError(FileErrorCode.unknown, 'simulated unlistable'));
    }
    return _delegate.listDir(path);
  }

  @override
  String get cwd => _delegate.cwd;
  @override
  Future<Result<String, FileError>> absolutePath(String path) =>
      _delegate.absolutePath(path);
  @override
  Future<Result<String, FileError>> joinPath(List<String> parts) =>
      _delegate.joinPath(parts);
  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);
  @override
  Future<Result<Uint8List, FileError>> readBinaryFile(String path) =>
      _delegate.readBinaryFile(path);
  @override
  Future<Result<void, FileError>> writeBinaryFile(
    String path,
    Uint8List content,
  ) => _delegate.writeBinaryFile(path, content);
  @override
  Future<Result<void, FileError>> writeFile(String path, String content) =>
      _delegate.writeFile(path, content);
  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);
  @override
  Future<Result<FileInfo, FileError>> fileInfo(String path) =>
      _delegate.fileInfo(path);
  @override
  Future<Result<bool, FileError>> exists(String path) =>
      _delegate.exists(path);
  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);
  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);
}

void main() {
  late Directory tmp;
  late LocalExecutionEnv env;
  late String sessionsRoot;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fah_listing_resilience');
    env = LocalExecutionEnv(cwd: tmp.path);
    sessionsRoot = '${tmp.path}/sessions';
    Directory(sessionsRoot).createSync(recursive: true);
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  test('an unreadable session file degrades the listing, not vanishes it',
      () async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
    final healthy = await repo.create(
      const JsonlSessionCreateOptions(id: 'healthy', cwd: '/work'),
    );
    await healthy.appendMessage(UserMessage.text('still visible'));
    final broken = await repo.create(
      const JsonlSessionCreateOptions(id: 'broken', cwd: '/work'),
    );
    final brokenPath = (await broken.getMetadata()).path;

    final brokenFs = _BrokenIoFs(env)..unreadableFiles.add(brokenPath);
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      includeSharedSessionRoots: false,
      repo: JsonlSessionRepo(fs: brokenFs, sessionsRoot: sessionsRoot),
    );

    // The failure mode that emptied the sidebar: one bad header read
    // used to throw out of the whole listing (swallowed into const []).
    final listed = await manager.listPersistedSessions();
    expect(listed.map((m) => m.id), ['healthy']);
  });

  test('an unlistable session directory degrades the listing, not vanishes '
      'it', () async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
    await repo.create(const JsonlSessionCreateOptions(id: 'gone', cwd: '/a'));
    await repo.create(const JsonlSessionCreateOptions(id: 'kept', cwd: '/b'));
    final goneDir = (await repo
        .list())
        .singleWhere((m) => m.id == 'gone')
        .path
        .split('/')
        .reversed
        .skip(1)
        .first;

    final brokenFs = _BrokenIoFs(env)..unlistableDirs.add('$sessionsRoot/$goneDir');
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      includeSharedSessionRoots: false,
      repo: JsonlSessionRepo(fs: brokenFs, sessionsRoot: sessionsRoot),
    );

    final listed = await manager.listPersistedSessions();
    expect(listed.map((m) => m.id), ['kept']);
  });

  test('the chat-list adapter still projects the surviving local rows',
      () async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: sessionsRoot);
    final healthy = await repo.create(
      const JsonlSessionCreateOptions(id: 'healthy', cwd: '/work'),
    );
    await healthy.appendMessage(UserMessage.text('row preview'));
    final broken = await repo.create(
      const JsonlSessionCreateOptions(id: 'broken', cwd: '/work'),
    );
    final brokenPath = (await broken.getMetadata()).path;

    final brokenFs = _BrokenIoFs(env)..unreadableFiles.add(brokenPath);
    final manager = FlutterSessionManager(
      env: env,
      sessionsRoot: sessionsRoot,
      includeSharedSessionRoots: false,
      repo: JsonlSessionRepo(fs: brokenFs, sessionsRoot: sessionsRoot),
    );
    final entries = await LocalChatListAdapter(
      manager: manager,
      titleBuilder: (id, createdAt, isSubagent) => id,
    ).load();

    expect(entries.map((entry) => entry.id.value), contains('healthy'));
    expect(entries.map((entry) => entry.id.value), isNot(contains('broken')));
    expect(
      entries.singleWhere((entry) => entry.id.value == 'healthy').preview,
      'row preview',
    );
  });
}
