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
  return '--${cwd.replaceFirst(RegExp(r'^[/\\]'), '').replaceAll(RegExp(r'[/\\:]'), '-')}--';
}

/// Creates a new session id (time-ordered uuidv7).
String createSessionId() => uuidv7();

/// JSONL session repository on top of a [FileSystem].
///
/// Ported from pi's `JsonlSessionRepo`.
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

  Future<String> _getSessionDir(String cwd) async {
    return _fsOrThrow(
      await _fs.joinPath([await _getSessionsRoot(), _encodeCwd(cwd)]),
      'Failed to resolve session directory for $cwd',
    );
  }

  Future<String> _createSessionFilePath(
    String cwd,
    String sessionId,
    DateTime timestamp,
  ) async {
    final safeTimestamp = timestamp.toIso8601String().replaceAll(
      RegExp(r'[:.]'),
      '-',
    );
    return _fsOrThrow(
      await _fs.joinPath([
        await _getSessionDir(cwd),
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
    final sessionDir = await _getSessionDir(options.cwd);
    _fsOrThrow(
      await _fs.createDir(sessionDir, recursive: true),
      'Failed to create session directory $sessionDir',
    );
    final filePath = await _createSessionFilePath(options.cwd, id, createdAt);
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
    final dirs = cwd != null
        ? [await _getSessionDir(cwd)]
        : await _listSessionDirs();
    final sessions = <SessionMetadata>[];
    for (final dir in dirs) {
      final exists = _fsOrThrow(
        await _fs.exists(dir),
        'Failed to check session directory $dir',
      );
      if (!exists) continue;
      final files = _fsOrThrow(
        await _fs.listDir(dir),
        'Failed to list sessions in $dir',
      );
      for (final file in files) {
        if (file.kind == FileKind.directory || !file.name.endsWith('.jsonl')) {
          continue;
        }
        try {
          sessions.add(await loadJsonlSessionMetadata(_fs, file.path));
        } on SessionException catch (error) {
          if (error.code != SessionErrorCode.invalidSession) rethrow;
        }
      }
    }
    sessions.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return sessions;
  }

  @override
  Future<void> delete(SessionMetadata metadata) async {
    _fsOrThrow(
      await _fs.remove(metadata.path, force: true),
      'Failed to delete session ${metadata.path}',
    );
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
    final sessionDir = await _getSessionDir(cwd);
    _fsOrThrow(
      await _fs.createDir(sessionDir, recursive: true),
      'Failed to create session directory $sessionDir',
    );
    final storage = await JsonlSessionStorage.create(
      _fs,
      await _createSessionFilePath(cwd, sessionId, createdAt),
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

  Future<List<String>> _listSessionDirs() async {
    final root = await _getSessionsRoot();
    final exists = _fsOrThrow(
      await _fs.exists(root),
      'Failed to check sessions root $root',
    );
    if (!exists) return [];
    final entries = _fsOrThrow(
      await _fs.listDir(root),
      'Failed to list sessions root $root',
    );
    return [
      for (final entry in entries)
        if (entry.kind == FileKind.directory) entry.path,
    ];
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
