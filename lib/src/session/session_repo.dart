/// Session repository: creates, lists, opens, deletes, and forks JSONL
/// sessions on top of a [FileSystem], managing session ids and paths per
/// pi's on-disk scheme.
///
/// Ported from pi-mono `packages/agent/src/harness/session/jsonl-repo.ts`
/// (`JsonlSessionRepo`) and `repo-utils.ts`. Layout:
/// `<sessionsRoot>/<--encoded-cwd-->/<timestamp>_<sessionId>.jsonl`.
library;

import '../env/execution_env.dart';
import '../exceptions.dart';
import 'session_record.dart';
import 'session_storage.dart';
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
  Future<Session> open(SessionMetadata metadata);

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
  JsonlSessionRepo({required this._fs, required String sessionsRoot})
    : _sessionsRootInput = sessionsRoot;

  final FileSystem _fs;
  final String _sessionsRootInput;
  String? _sessionsRoot;

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
  Future<Session> open(SessionMetadata metadata) async {
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
    return Session(await JsonlSessionStorage.open(_fs, metadata.path));
  }

  @override
  Future<List<SessionMetadata>> list({String? cwd}) async {
    final sessions = await _collectRootSessions();
    if (cwd != null) {
      sessions.retainWhere((m) => m.cwd == cwd);
    }
    sessions.sort(_compareSessionActivity);
    return sessions;
  }

  /// Sort sessions by latest activity (file mtime), falling back to creation
  /// time so stable ordering is guaranteed even when mtimes are equal.
  int _compareSessionActivity(SessionMetadata a, SessionMetadata b) {
    final aTime = a.lastUpdatedAt ?? a.createdAt;
    final bTime = b.lastUpdatedAt ?? b.createdAt;
    final result = bTime.compareTo(aTime);
    if (result != 0) return result;
    return b.createdAt.compareTo(a.createdAt);
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
      final contents = _fsOrThrow(
        await _fs.readTextFile(path),
        'Failed to read $path',
      );
      // A session that holds only its header record has zero or one
      // non-empty line; anything more means real transcript.
      final nonEmpty = contents
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .length;
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

  Future<List<SessionMetadata>> _collectRootSessions() async {
    final root = await _getSessionsRoot();
    final exists = _fsOrThrow(
      await _fs.exists(root),
      'Failed to check sessions root $root',
    );
    if (!exists) return [];
    final sessions = <SessionMetadata>[];
    await _collectSessionsInDir(root, sessions);
    return sessions;
  }

  Future<void> _collectSessionsInDir(
    String dirPath,
    List<SessionMetadata> out,
  ) async {
    final entries = _fsOrThrow(
      await _fs.listDir(dirPath),
      'Failed to list session directory $dirPath',
    );
    for (final entry in entries) {
      if (entry.kind == FileKind.directory) {
        await _collectSessionsInDir(entry.path, out);
        continue;
      }
      if (!entry.name.endsWith('.jsonl')) continue;
      final metadata = await _tryLoadSessionMetadata(entry);
      if (metadata != null) out.add(metadata);
    }
  }

  Future<SessionMetadata?> _tryLoadSessionMetadata(FileInfo entry) async {
    try {
      return await loadJsonlSessionMetadata(
        _fs,
        entry.path,
        lastUpdatedAt: DateTime.fromMillisecondsSinceEpoch(entry.mtimeMs),
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
