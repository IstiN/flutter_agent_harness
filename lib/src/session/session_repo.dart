/// Session repository: creates, lists, opens, deletes, and forks JSONL
/// sessions on top of a [FileSystem], managing session ids and paths per
/// pi's on-disk scheme.
///
/// Ported from pi-mono `packages/agent/src/harness/session/jsonl-repo.ts`
/// (`JsonlSessionRepo`) and `repo-utils.ts`. Layout:
/// `<sessionsRoot>/<--encoded-cwd-->/<timestamp>_<sessionId>.jsonl`.
library;

import 'dart:async';
import 'dart:convert' as json_conv;
import '../env/execution_env.dart';
import '../env/session_parse_executor.dart';
import '../exceptions.dart';
import '../session_io_retry.dart';
import 'session_chunk_reader.dart';
import 'session_record.dart';
import 'session_storage.dart';
import 'windowed_session_storage.dart';
import 'attach/session_presence.dart';
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
  ///
  /// Issue #522: the delete is journaled (who/what/when into the root's
  /// `session_ops.journal`), soft (the file moves into `<root>/.trash/`),
  /// and refused with [SessionErrorCode.liveSession] while a fresh
  /// presence row exists for the session — unless the deleting process
  /// owns that row. [actor] names the calling flow for the journal.
  Future<void> delete(SessionMetadata metadata, {String actor = 'unknown'});

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
  /// [ioRetry] wires the transient-ENOENT retry of session-file opens,
  /// creations and appends (issue #427); hosts pass their diagnostic log
  /// sink to see one `session_io_retry` line per retry.
  JsonlSessionRepo({
    required this._fs,
    required String sessionsRoot,
    this._parseExecutor,
    this._ioRetry = const SessionIoRetryConfig(),
    this.presenceStore,
    this.processId,
    DateTime Function()? now,
  }) : _sessionsRootInput = sessionsRoot,
       now = now ?? DateTime.now;

  final FileSystem _fs;
  final String _sessionsRootInput;
  String? _sessionsRoot;
  final SessionParseExecutor? _parseExecutor;

  /// Transient-ENOENT retry wiring (issue #427) threaded into every
  /// session-file open/create this repo performs.
  final SessionIoRetryConfig _ioRetry;

  /// Live-session presence (issue #522): when set, `delete` refuses any
  /// session with a fresh heartbeat unless the deleting process owns the
  /// registration (its own pid).
  final SessionPresenceStore? presenceStore;

  /// The host process id, journaled as the deletion culprit and matched
  /// against presence rows for the self-ownership exemption. Null (web)
  /// treats every live row as foreign.
  final int? processId;

  /// Clock seam for journal timestamps and trash file stamps (tests).
  final DateTime Function() now;

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
      ioRetry: _ioRetry,
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
              ioRetry: _ioRetry,
            )
          : await JsonlSessionStorage.open(
              _fs,
              metadata.path,
              parseExecutor: _parseExecutor,
              ioRetry: _ioRetry,
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
  Future<void> delete(
    SessionMetadata metadata, {
    String actor = 'unknown',
  }) async {
    // Issue #522 live guard: a fresh presence row means a running process
    // owns this session. `list()` already expired stale heartbeats, so a
    // dead owner never blocks. The owner itself may delete its own file
    // (the emptiness-gated cleanup flows) — that is the pid match.
    final row = (await presenceStore?.list())?[metadata.id];
    final ownRow = row != null && processId != null && row.pid == processId;
    if (row != null && !ownRow) {
      throw SessionException(
        'Session ${metadata.id} is live (pid ${row.pid ?? 'unknown'}, '
        'heartbeat ${row.touchedAt}) — delete refused. Stop the owning '
        'process first; the refusal is itself the data-loss guard.',
        code: SessionErrorCode.liveSession,
      );
    }
    await _softDelete(
      metadata.path,
      op: 'delete',
      sessionId: metadata.id,
      actor: actor,
    );
  }

  /// Trashes every `.jsonl` session whose file contains **only the header
  /// record** and no further entries.
  ///
  /// Used after the migrate-from-eager-creation change to clean up the
  /// legacy empty files that the old `SubagentManager.register` /
  /// `AgentService.initialize` paths left on disk. Returns the number of
  /// files actually trashed (best-effort: a failed read leaves the file in
  /// place). Issue #522: empty does not mean deletable while live — a
  /// just-booted process owns a header-only file, so live rows are skipped,
  /// and everything routes through the journaled soft-delete gate.
  Future<int> cleanupEmptySessions() async {
    var removed = 0;
    final root = await _getSessionsRoot();
    final rootExists = _fsOrThrow(
      await _fs.exists(root),
      'Failed to check sessions root $root',
    );
    if (!rootExists) return 0;
    final live = (await presenceStore?.list()) ?? const {};
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
      final id = _sessionIdFromPath(path);
      if (id != null && live.containsKey(id)) continue;
      await _softDelete(
        path,
        op: 'cleanup-empty',
        sessionId: id,
        actor: 'repo:cleanup-empty',
      );
      removed++;
    }
    return removed;
  }

  /// The `.trash` directory under the sessions root (issue #522): deleted
  /// session files land here — `<root>/.trash/<timestamp>_<name>` — and
  /// stay recoverable until [purgeTrash] drops them past a TTL.
  static const String trashDirName = '.trash';

  /// The per-root deletion journal (issue #522): one JSON line per
  /// delete/move/purge with the culprit (pid + actor tag), the path, and
  /// the outcome. A vanished session file always has a named record.
  static const String journalFileName = 'session_ops.journal';

  /// Moves [path] into `<root>/.trash/` and journals the operation.
  ///
  /// Trash-first: the move is atomic, so a crash can only leave the file
  /// recoverable in `.trash` (its presence there IS the record) or in
  /// place — never gone. Backends without a rename primitive (pure web)
  /// fall back to a journaled remove: the intent line lands BEFORE the
  /// unlink so even that path names its culprit.
  Future<void> _softDelete(
    String path, {
    required String op,
    String? sessionId,
    required String actor,
  }) async {
    final root = await _getSessionsRoot();
    final exists = _fsOrThrow(
      await _fs.exists(path),
      'Failed to check session $path',
    );
    if (!exists) {
      await _journal(
        root,
        op: op,
        path: path,
        sessionId: sessionId,
        actor: actor,
        result: 'missing',
      );
      return;
    }
    final trashPath = await _trashPathFor(root, path);
    if (_fs is! RenamableFileSystem) {
      await _journal(
        root,
        op: op,
        path: path,
        sessionId: sessionId,
        actor: actor,
        result: 'remove-fallback',
      );
      _fsOrThrow(
        await _fs.remove(path, force: true),
        'Failed to delete session $path',
      );
      return;
    }
    final trashDir = _fsOrThrow(
      await _fs.joinPath([root, trashDirName]),
      'Failed to resolve trash directory',
    );
    _fsOrThrow(
      await _fs.createDir(trashDir, recursive: true),
      'Failed to create trash directory',
    );
    _fsOrThrow(
      await (_fs as RenamableFileSystem).renamePath(path, trashPath),
      'Failed to move session $path to trash $trashPath',
    );
    await _journal(
      root,
      op: op,
      path: path,
      sessionId: sessionId,
      actor: actor,
      result: 'trash',
      trash: trashPath,
    );
  }

  /// `<root>/.trash/<timestamp>_<basename>` — the stamp keeps repeated
  /// deletions of the same-named file apart.
  Future<String> _trashPathFor(String root, String path) async {
    final stamp = now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    final base = path.split(RegExp(r'[/\\]')).last;
    return _fsOrThrow(
      await _fs.joinPath([root, trashDirName, '${stamp}_$base']),
      'Failed to resolve trash path for $path',
    );
  }

  /// Appends one auditable line to the root's `session_ops.journal`.
  Future<void> _journal(
    String root, {
    required String op,
    required String path,
    String? sessionId,
    required String actor,
    required String result,
    String? trash,
  }) async {
    final line = json_conv.jsonEncode({
      'at': now().toIso8601String(),
      'op': op,
      'path': path,
      'session': ?sessionId,
      'pid': ?processId,
      'actor': actor,
      'result': result,
      'trash': ?trash,
    });
    final journalPath = _fsOrThrow(
      await _fs.joinPath([root, journalFileName]),
      'Failed to resolve journal path',
    );
    _fsOrThrow(
      await _fs.appendFile(journalPath, '$line\n'),
      'Failed to append session ops journal $journalPath',
    );
  }

  /// Removes trash entries older than [ttl] (issue #522): trash is
  /// recoverable storage with a lifetime, not an unbounded second copy of
  /// every deleted session. Returns the number of entries purged; every
  /// purge is journaled.
  Future<int> purgeTrash({
    Duration ttl = const Duration(days: 30),
    String actor = 'repo:purge-trash',
  }) async {
    final root = await _getSessionsRoot();
    final trashDir = _fsOrThrow(
      await _fs.joinPath([root, trashDirName]),
      'Failed to resolve trash directory',
    );
    if (!_fsOrThrow(await _fs.exists(trashDir), 'Failed to check $trashDir')) {
      return 0;
    }
    final entries = _fsOrThrow(
      await _fs.listDir(trashDir),
      'Failed to list $trashDir',
    );
    final cutoffMs = now().subtract(ttl).millisecondsSinceEpoch;
    var purged = 0;
    for (final entry in entries) {
      if (entry.mtimeMs >= cutoffMs) continue;
      _fsOrThrow(
        await _fs.remove(entry.path, force: true),
        'Failed to purge ${entry.path}',
      );
      await _journal(
        root,
        op: 'purge',
        path: entry.path,
        actor: actor,
        result: 'removed',
      );
      purged++;
    }
    return purged;
  }

  /// The session id encoded in a session file basename
  /// (`<timestamp>_<sessionId>.jsonl`); null when the name has no id part.
  String? _sessionIdFromPath(String path) {
    final base = path.split(RegExp(r'[/\\]')).last;
    if (!base.endsWith('.jsonl')) return null;
    final parts = base.substring(0, base.length - '.jsonl'.length).split('_');
    return parts.length < 2 || parts.last.isEmpty ? null : parts.last;
  }

  Future<List<String>> _collectJsonlFiles(String dirPath) async {
    final entries = _fsOrThrow(
      await _fs.listDir(dirPath),
      'Failed to list session directory $dirPath',
    );
    final files = <String>[];
    for (final entry in entries) {
      if (entry.kind == FileKind.directory) {
        // The trash (issue #522) is recoverable storage, not a session
        // folder — its files must never re-enter list()/cleanup sweeps.
        if (entry.name == trashDirName) continue;
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
      ioRetry: _ioRetry,
    );
    for (final entry in forkedEntries) {
      await storage.appendEntry(entry);
    }
    return Session(storage);
  }

  /// The session's display name WITHOUT a full open (issue #199): the
  /// newest `session_info` record — the same record `(await open(m))
  /// .getSessionName()` reports within the probe cap (an empty or
  /// whitespace newest name clears it). Read-only: never rewrites torn
  /// lines. Issue #369 — the CLI cold start resolves `--session NAME`
  /// across every session file, and named-at-creation sessions
  /// keep their only session_info at the file START, so chunk-paged
  /// parsing made a 400 MB file cost its whole JSON body per scan.
  /// Resolution is two bounded byte probes instead: the file's head
  /// window first (where creation-time names live), then the tail
  /// window, whose record wins whenever present — at most `2 MiB` +
  /// the probed lines' bytes, never a full read, on hosts with ranged
  /// reads (ranged-read support is required; hosts without it cannot
  /// open sessions windowed at all). Throws [SessionException] like
  /// [open] when the file is missing/unreadable — callers already
  /// guard.
  Future<String?> sessionNameQuick(SessionMetadata metadata) async {
    final reader = SessionChunkReader(
      fs: _fs,
      path: metadata.path,
      parseExecutor: _parseExecutor,
    );
    final name = await reader.readNewestSessionInfoName();
    final trimmed = name?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// Raw file scan for custom records whose `customType` is in [types]
  /// (issue #437). Custom records are side-leaves of the record tree, so
  /// the windowed storage's branch parse never materializes them into
  /// [Session.getEntries] — restart-time scans (e.g. recovered steering)
  /// must read the file instead of trusting the resident window. The
  /// cheap substring gate keeps JSON decodes proportional to the match
  /// count, not the file size. Returns [] for a missing/unreadable file:
  /// a broken session must still boot.
  Future<List<CustomRecord>> readCustomRecordsOfType(
    SessionMetadata metadata,
    Set<String> types,
  ) async {
    final read = await _fs.readTextLines(metadata.path);
    if (read.isErr) return const [];
    final records = <CustomRecord>[];
    for (final line in read.valueOrNull ?? const <String>[]) {
      if (!types.any(line.contains)) continue;
      final Object? json;
      try {
        json = json_conv.jsonDecode(line);
      } on Object {
        continue; // torn tail line from a crash — skip.
      }
      if (json is! Map) continue;
      final record = SessionRecord.fromJson(json.cast<String, dynamic>());
      if (record is CustomRecord && types.contains(record.customType)) {
        records.add(record);
      }
    }
    return records;
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
      for (var i = 0; i < _listConcurrency && i < sessions.length; i++)
        worker(),
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
            // Trash (issue #522) never surfaces as live sessions.
            if (entry.name == trashDirName) continue;
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
