/// Session repository: creates, lists, opens, deletes, and forks JSONL
/// sessions on top of a [FileSystem], managing session ids and paths per
/// pi's on-disk scheme.
///
/// Ported from pi-mono `packages/agent/src/harness/session/jsonl-repo.ts`
/// (`JsonlSessionRepo`) and `repo-utils.ts`. Layout:
/// `<sessionsRoot>/<--encoded-cwd-->/<timestamp>_<sessionId>.jsonl`.
library;

import '../env/execution_env.dart';
import '../env/session_parse_executor.dart';
import '../exceptions.dart';
import 'session_chunk_reader.dart';
import 'session_record.dart';
import 'session_storage.dart';
import 'windowed_session_storage.dart';
import 'session_tree.dart';
import 'uuid.dart';

/// Where a fork cut point sits relative to [JsonlSessionRepo.fork]'s
/// `entryId`.
enum ForkPosition {
  /// The fork contains everything *before* the entry (which must be a user
  /// message) — i.e. the conversation is rewound to re-ask it.
  before,

  /// The fork contains the entry itself and everything before it.
  at,
}

/// Options for [JsonlSessionRepo.create].
///
/// Ported from pi's `JsonlSessionCreateOptions`.
final class JsonlSessionCreateOptions {
  /// Creates [JsonlSessionCreateOptions].
  const JsonlSessionCreateOptions({
    required this.cwd,
    this.id,
    this.parentSessionPath,
    this.metadata,
  });

  /// Working directory the session belongs to (determines its directory).
  final String cwd;

  /// Explicit session id; a fresh uuidv7 is generated when omitted.
  final String? id;

  /// Path of the parent session (set automatically by [JsonlSessionRepo.fork]).
  final String? parentSessionPath;

  /// Free-form application metadata written to the header.
  final Map<String, dynamic>? metadata;
}

/// The repository contract for sessions.
///
/// Ported from pi's `SessionRepo` (specialized to JSONL metadata/options).
abstract interface class SessionRepo {
  /// Creates a new session.
  Future<Session> create(JsonlSessionCreateOptions options);

  /// Opens an existing session from its metadata.
  Future<Session> open(SessionMetadata metadata, {bool windowed = false});

  /// Lists stored sessions, newest first; [cwd] filters to one directory.
  Future<List<SessionMetadata>> list({String? cwd});

  /// Deletes a session file.
  Future<void> delete(SessionMetadata metadata);

  /// Forks [source] into a new session containing a prefix of its tree.
  ///
  /// When [entryId] is given, the fork contains the branch ending at that
  /// entry ([ForkPosition.at]) or everything before it, which requires the
  /// entry to be a user message ([ForkPosition.before], the default).
  Future<Session> fork(
    SessionMetadata source, {
    required String cwd,
    String? entryId,
    ForkPosition position,
    String? id,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
  });
}

String _encodeCwd(String cwd) {
  final normalized = cwd.replaceAll(RegExp(r'[/\\]+$'), '');
  return '--${normalized.replaceFirst(RegExp(r'^[/\\]'), '').replaceAll(RegExp(r'[/\\:]'), '-')}--';
}

/// The per-project directory slug used under the sessions root
/// (`/work` → `--work--`). Public so sibling stores (e.g. the messaging
/// fabric root) colocate with the project's sessions.
String encodeSessionCwd(String cwd) => _encodeCwd(cwd);

/// Reverses [encodeSessionCwd]: `--Users-Uladzimir_Klyshevich-git-dm.ai--`
/// → `/Users/Uladzimir_Klyshevich/git/dm.ai`.
///
/// Returns `null` if [slug] is not wrapped in `--` or decodes to an empty path.
String? decodeSessionCwd(String slug) {
  if (slug.length < 4 || !slug.startsWith('--') || !slug.endsWith('--')) {
    return null;
  }
  final inner = slug.substring(2, slug.length - 2);
  if (inner.isEmpty) return null;
  final parts = inner.split('-');
  if (parts.isEmpty || parts.any((p) => p.isEmpty)) return null;
  return '/${parts.join('/')}';
}

/// Creates a new session id (time-ordered uuidv7).
String createSessionId() => uuidv7();

/// Sorts by latest activity (file mtime), falling back to creation time so
/// stable ordering is guaranteed even when mtimes are equal.
int compareSessionActivity(SessionMetadata a, SessionMetadata b) {
  final aTime = a.lastUpdatedAt ?? a.createdAt;
  final bTime = b.lastUpdatedAt ?? b.createdAt;
  final result = bTime.compareTo(aTime);
  if (result != 0) return result;
  return b.createdAt.compareTo(a.createdAt);
}

/// Orders sessions for display (issue #83): sessions from the [currentCwd]
/// folder first, then sessions from every other folder; each group
/// newest-activity first. [JsonlSessionRepo.list] stays plain activity
/// order so `/resume` keeps its most-recent-anywhere semantics.
List<SessionMetadata> sortSessionsCurrentFolderFirst(
  List<SessionMetadata> sessions,
  String? currentCwd,
) {
  final sorted = [...sessions]..sort(compareSessionActivity);
  if (currentCwd == null || currentCwd.isEmpty) return sorted;
  return [
    ...sorted.where((m) => m.cwd == currentCwd),
    ...sorted.where((m) => m.cwd != currentCwd),
  ];
}

/// JSONL session repository on top of a [FileSystem].
///
/// Ported from pi's `JsonlSessionRepo`. Layout: sessions are stored under
/// [sessionsRoot] grouped by working directory:
/// `<sessionsRoot>/<--encoded-cwd-->/<timestamp>_<sessionId>.jsonl`.
/// The session's original working directory is kept in the file header
/// ([SessionMetadata.cwd]) so a session can be resumed from any launch folder
/// while preserving its project scope.
final class JsonlSessionRepo implements SessionRepo {
  /// Creates a [JsonlSessionRepo] storing sessions under [sessionsRoot].
  /// [parseExecutor] moves record parsing off the calling isolate for
  /// [open] (issue #199); `null` keeps the inline batched path (web).
  JsonlSessionRepo({
    required this._fs,
    required String sessionsRoot,
    this._parseExecutor,
  }) : _sessionsRootInput = sessionsRoot;

  final FileSystem _fs;
  final String _sessionsRootInput;
  String? _sessionsRoot;
  final SessionParseExecutor? _parseExecutor;

  /// Header-read concurrency for [list] (issue #199): bounded so 500+
  /// sessions never exhaust fds; ≥ 2 so latency overlaps (E4 pins the VM
  /// floor at 2 cores).
  static const int _listConcurrency = 16;

  Future<String> _getSessionsRoot() async {
    final cached = _sessionsRoot;
    if (cached != null) return cached;
    final resolved = _fsOrThrow(
      await _fs.absolutePath(_sessionsRootInput),
      'Failed to resolve sessions root $_sessionsRootInput',
    );
    _sessionsRoot = resolved;
    return resolved;
  }

  Future<String> _createSessionFilePath(
    String sessionId,
    DateTime timestamp,
    String cwd,
  ) async {
    final safeTimestamp = timestamp.toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    return _fsOrThrow(
      await _fs.joinPath([
        await _getSessionsRoot(),
        encodeSessionCwd(cwd),
        '${safeTimestamp}_$sessionId.jsonl',
      ]),
      'Failed to resolve session file path for $sessionId',
    );
  }

  T _fsOrThrow<T>(Result<T, FileError> result, String message) {
    if (result.isErr) {
      final error = result.errorOrNull!;
      throw SessionException(
        '$message: ${error.message}',
        code: error.code == FileErrorCode.notFound
            ? SessionErrorCode.notFound
            : SessionErrorCode.storage,
        cause: error,
      );
    }
    return result.valueOrNull as T;
  }

  @override
  Future<Session> create(JsonlSessionCreateOptions options) async {
    final id = options.id ?? createSessionId();
    final createdAt = DateTime.now();
    final sessionsRoot = await _getSessionsRoot();
    final cwdDir = _fsOrThrow(
      await _fs.joinPath([sessionsRoot, encodeSessionCwd(options.cwd)]),
      'Failed to resolve session directory for ${options.cwd}',
    );
    _fsOrThrow(
      await _fs.createDir(cwdDir, recursive: true),
      'Failed to create session directory for ${options.cwd}',
    );
    final filePath = await _createSessionFilePath(id, createdAt, options.cwd);
    final storage = await JsonlSessionStorage.create(
      _fs,
      filePath,
      cwd: options.cwd,
      sessionId: id,
      parentSessionPath: options.parentSessionPath,
      metadata: options.metadata,
    );
    return Session(storage);
  }

  @override
  /// Opens a session. With [windowed] (the app's chat path, issue #135)
  /// only the header plus the newest chunk are materialized — older
  /// records page in on demand through the returned [Session]'s
  /// [WindowedSessionStorage]; small sessions load completely either way.
  /// The default full open reads the whole file (CLI, tools, migrations).
  Future<Session> open(
    SessionMetadata metadata, {
    bool windowed = false,
  }) async {
    final exists = _fsOrThrow(
      await _fs.exists(metadata.path),
      'Failed to check session ${metadata.path}',
    );
    if (!exists) {
      throw SessionException(
        'Session not found: ${metadata.path}',
        code: SessionErrorCode.notFound,
      );
    }
    return Session(
      windowed
          ? await WindowedSessionStorage.open(
              _fs,
              metadata.path,
              parseExecutor: _parseExecutor,
            )
          : await JsonlSessionStorage.open(
              _fs,
              metadata.path,
              parseExecutor: _parseExecutor,
            ),
    );
  }

  @override
  Future<List<SessionMetadata>> list({String? cwd}) async {
    final sessions = await _collectRootSessions();
    if (cwd != null) {
      sessions.retainWhere((m) => m.cwd == cwd);
    }
    sessions.sort(compareSessionActivity);
    return sessions;
  }

  @override
  Future<void> delete(SessionMetadata metadata) async {
    _fsOrThrow(
      await _fs.remove(metadata.path, force: true),
      'Failed to delete session ${metadata.path}',
    );
  }

  /// Removes every `.jsonl` session whose file contains **only the header
  /// record** and no further entries.
  ///
  /// Used after the migrate-from-eager-creation change to clean up the
  /// legacy empty files that the old `SubagentManager.register` /
  /// `AgentService.initialize` paths left on disk. Returns the number of
  /// files actually deleted (best-effort: a failed read or delete leaves the
  /// file in place).
  Future<int> cleanupEmptySessions() async {
    var removed = 0;
    final root = await _getSessionsRoot();
    final rootExists = _fsOrThrow(
      await _fs.exists(root),
      'Failed to check sessions root $root',
    );
    if (!rootExists) return 0;
    final files = await _collectJsonlFiles(root);
    for (final path in files) {
      // Emptiness is decidable from the first two lines: line 1 is the
      // header, and any transcript content means a second line. The read
      // streams and stops there — scanning every session whole would turn
      // the cleanup pass into O(bytes on disk) and defeat windowed
      // loading (issue #135) on big session files. (fa writers never emit
      // blank lines, so "second line empty" can only mean "no content".)
      final lines = _fsOrThrow(
        await _fs.readTextLines(path, maxLines: 2),
        'Failed to read $path',
      );
      final nonEmpty = lines.where((line) => line.trim().isNotEmpty).length;
      if (nonEmpty > 1) continue;
      _fsOrThrow(
        await _fs.remove(path, force: true),
        'Failed to delete empty session $path',
      );
      removed++;
    }
    return removed;
  }

  Future<List<String>> _collectJsonlFiles(String dirPath) async {
    final entries = _fsOrThrow(
      await _fs.listDir(dirPath),
      'Failed to list session directory $dirPath',
    );
    final files = <String>[];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory) {
        files.addAll(await _collectJsonlFiles(entry.path));
        continue;
      }
      if (entry.name.endsWith('.jsonl')) files.add(entry.path);
    }
    return files;
  }

  @override
  Future<Session> fork(
    SessionMetadata source, {
    required String cwd,
    String? entryId,
    ForkPosition position = ForkPosition.before,
    String? id,
    String? parentSessionPath,
    Map<String, dynamic>? metadata,
  }) async {
    final sourceSession = await open(source);
    final forkedEntries = await _entriesToFork(
      sourceSession.getStorage(),
      entryId,
      position,
    );
    final sessionId = id ?? createSessionId();
    final createdAt = DateTime.now();
    final sessionsRoot = await _getSessionsRoot();
    final cwdDir = _fsOrThrow(
      await _fs.joinPath([sessionsRoot, encodeSessionCwd(cwd)]),
      'Failed to resolve session directory for $cwd',
    );
    _fsOrThrow(
      await _fs.createDir(cwdDir, recursive: true),
      'Failed to create session directory for $cwd',
    );
    final storage = await JsonlSessionStorage.create(
      _fs,
      await _createSessionFilePath(sessionId, createdAt, cwd),
      cwd: cwd,
      sessionId: sessionId,
      parentSessionPath: parentSessionPath ?? source.path,
      metadata: metadata ?? source.metadata,
    );
    for (final entry in forkedEntries) {
      await storage.appendEntry(entry);
    }
    return Session(storage);
  }

  /// The session's display name WITHOUT a full open (issue #199): scans
  /// the tail backward through the chunk reader until the newest
  /// `session_info` record surfaces — the same record `(await open(m))
  /// .getSessionName()` reports (last one in file order wins; an
  /// empty/whitespace name clears it). Read-only: unlike a full open it
  /// never rewrites torn lines. Throws [SessionException] like [open]
  /// when the file is missing/unreadable — callers already guard.
  Future<String?> sessionNameQuick(SessionMetadata metadata) async {
    final reader = SessionChunkReader(
      fs: _fs,
      path: metadata.path,
      parseExecutor: _parseExecutor,
    );
    SessionChunk chunk = await reader.readTail();
    while (true) {
      for (final entry in chunk.entries.reversed) {
        final record = entry.record;
        if (record is SessionInfoRecord) {
          final name = record.name?.trim();
          return name != null && name.isNotEmpty ? name : null;
        }
      }
      if (!chunk.hasOlder || chunk.isEmpty) return null;
      chunk = await reader.readBefore(chunk.firstOffset);
    }
  }

  /// Batch form of [sessionNameQuick]: bounded 16-way fan-out, results
  /// keyed by session id; a session that fails to scan contributes no
  /// name (the caller's row degrades to the id).
  Future<Map<String, String>> sessionNamesQuick(
    List<SessionMetadata> sessions,
  ) async {
    final names = <String, String>{};
    var next = 0;
    Future<void> worker() async {
      while (next < sessions.length) {
        final metadata = sessions[next++];
        try {
          final name = await sessionNameQuick(metadata);
          if (name != null) names[metadata.id] = name;
        } on Object {
          // Broken or foreign session file: skip, never break the caller.
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < _listConcurrency && i < sessions.length; i++) worker(),
    ]);
    return names;
  }

  Future<List<SessionMetadata>> _collectRootSessions() async {
    final root = await _getSessionsRoot();
    final exists = _fsOrThrow(
      await _fs.exists(root),
      'Failed to check sessions root $root',
    );
    if (!exists) return [];
    return _collectSessionsInDir(root);
  }

  /// Collects every session file under the root: the directory tree is
  /// walked breadth-first with bounded parallel [listDir] calls, then all
  /// header reads fan out through ONE bounded pool (issue #199 AC3 —
  /// sequential listing makes app boot O(sessions × header latency)).
  Future<List<SessionMetadata>> _collectSessionsInDir(String dirPath) async {
    final files = <FileInfo>[];
    final pending = <String>[dirPath];
    while (pending.isNotEmpty) {
      final level = List.of(pending);
      pending.clear();
      final discovered = await _mapBounded(level, _listDir);
      for (final entries in discovered) {
        for (final entry in entries) {
          if (entry.kind == FileKind.directory) {
            pending.add(entry.path);
          } else if (entry.name.endsWith('.jsonl')) {
            files.add(entry);
          }
        }
      }
    }
    final loaded = await _mapBounded<FileInfo, SessionMetadata?>(
      files,
      _tryLoadSessionMetadata,
    );
    return [for (final m in loaded) ?m];
  }

  /// Runs [task] over [items] with at most [_listConcurrency] in flight;
  /// results keep input order. A failing task fails the whole batch (the
  /// caller's error text names its item).
  Future<List<R>> _mapBounded<T, R>(
    List<T> items,
    Future<R> Function(T) task,
  ) async {
    final results = List<R?>.filled(items.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= items.length) return;
        results[i] = await task(items[i]);
      }
    }

    await Future.wait([
      for (var i = 0; i < _listConcurrency && i < items.length; i++) worker(),
    ]);
    return [for (final r in results) r as R];
  }

  Future<List<FileInfo>> _listDir(String dir) async => _fsOrThrow(
    await _fs.listDir(dir),
    'Failed to list session directory $dir',
  );

  Future<SessionMetadata?> _tryLoadSessionMetadata(FileInfo entry) async {
    try {
      return await loadJsonlSessionMetadata(
        _fs,
        entry.path,
        lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(entry.mtimeMs),
        sizeBytes: entry.size,
      );
    } on SessionException catch (error) {
      if (error.code != SessionErrorCode.invalidSession) rethrow;
      return null;
    }
  }

  Future<List<SessionRecord>> _entriesToFork(
    SessionStorage storage,
    String? entryId,
    ForkPosition position,
  ) async {
    if (entryId == null) return storage.getEntries();
    final target = await storage.getEntry(entryId);
    if (target == null) {
      throw SessionException(
        'Entry $entryId not found',
        code: SessionErrorCode.invalidForkTarget,
      );
    }
    String? effectiveLeafId;
    if (position == ForkPosition.at) {
      effectiveLeafId = target.id;
    } else {
      if (target is! MessageRecord || target.message.role != 'user') {
        throw SessionException(
          'Entry $entryId is not a user message',
          code: SessionErrorCode.invalidForkTarget,
        );
      }
      effectiveLeafId = target.parentId;
    }
    return storage.getPathToRoot(effectiveLeafId);
  }
}
