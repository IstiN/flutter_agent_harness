/// Persisted listing index for a sessions root (issue #2053).
///
/// One JSON sidecar per root — `<root>/.listing-index.json`, written
/// atomically (tmp + rename when the backend can rename) — that remembers
/// what the last full listing saw: the header metadata of every session
/// file plus a per-directory fingerprint (gh-1734's stat-fingerprint
/// pattern lifted to listing level). A warm `JsonlSessionRepo.list` serves
/// its rows from this index after validating the fingerprint against the
/// cheap directory walk, paying ZERO per-file header reads instead of one
/// open + read + stat per session (the measured ~6.7 s of app boot on a
/// 908-file corpus).
///
/// The index is a **cache, never the authority**: every read path
/// cross-checks each served row against the walk's own stat data (size +
/// mtime), entries are only served for files the walk still sees, and any
/// mismatch is healed by re-reading that file's header. A stale, torn or
/// foreign index can therefore never hide or resurrect a session — the
/// worst case is today's full scan (the broken-sessions-dir rule).
library;

import 'dart:convert' as json_conv;

import 'env/execution_env.dart';

/// File-system stat terms of one directory of the sessions tree: the
/// number of `.jsonl` files in it, their total size, and the newest mtime
/// among them. Count+size+mtime TOGETHER catch created / deleted /
/// appended / rotated files; the documented residual (gh-1734) is a
/// same-count, same-total-size, same-max-mtime mutation — e.g. two
/// same-size files swapping within one directory between listings — which
/// the per-entry stat cross-check in the repo still catches.
final class ListingDirStats {
  /// Creates the stats of one directory.
  const ListingDirStats({
    required this.fileCount,
    required this.totalBytes,
    required this.maxMtimeMs,
  });

  /// Number of `.jsonl` session files in the directory.
  final int fileCount;

  /// Sum of their sizes in bytes.
  final int totalBytes;

  /// Newest mtime among them (epoch ms; 0 when the directory holds none).
  final int maxMtimeMs;

  /// Decodes `[count, totalBytes, maxMtimeMs]`; null on any shape drift.
  static ListingDirStats? fromJson(Object? json) {
    if (json is! List || json.length != 3) return null;
    final count = json[0];
    final total = json[1];
    final mtime = json[2];
    if (count is! int || total is! int || mtime is! int) return null;
    if (count < 0 || total < 0 || mtime < 0) return null;
    return ListingDirStats(
      fileCount: count,
      totalBytes: total,
      maxMtimeMs: mtime,
    );
  }

  /// Encodes as the compact `[count, totalBytes, maxMtimeMs]` triple.
  List<int> toJson() => [fileCount, totalBytes, maxMtimeMs];

  @override
  bool operator ==(Object other) =>
      other is ListingDirStats &&
      other.fileCount == fileCount &&
      other.totalBytes == totalBytes &&
      other.maxMtimeMs == maxMtimeMs;

  @override
  int get hashCode => Object.hash(fileCount, totalBytes, maxMtimeMs);
}

/// One remembered session row of [SessionListingIndex]: everything
/// [JsonlSessionRepo] needs to serve the session's listing metadata
/// without opening its file — header identity (id, cwd, createdAt, parent,
/// free-form header metadata), the stat pair the walk is cross-checked
/// against, and the lazily learned extras (display name, rotated-segment
/// flag).
final class SessionListingIndexEntry {
  /// Creates an index entry.
  const SessionListingIndexEntry({
    required this.id,
    required this.path,
    required this.sizeBytes,
    required this.mtimeMs,
    required this.createdAtIso,
    required this.cwd,
    this.lastUpdatedAtMs,
    this.parentSessionPath,
    this.metadata,
    this.name,
    this.hasParts = false,
  });

  /// Session id (from the file header).
  final String id;

  /// Absolute file path this entry was built from — the join key against
  /// the directory walk. A file that moved is a different path, so a
  /// renamed/moved session is never served from its old entry.
  final String path;

  /// File size at entry time (bytes).
  final int sizeBytes;

  /// File mtime at entry time (epoch ms).
  final int mtimeMs;

  /// Session creation time, the header's exact ISO string — kept verbatim
  /// so a served row reproduces the cold scan's parse bit-for-bit (an
  /// epoch-ms int would quantize away the sub-millisecond tiebreaker the
  /// newest-first sort relies on).
  final String createdAtIso;

  /// Working directory from the header.
  final String cwd;

  /// Header-record timestamp when known; drives the newest-first order.
  final int? lastUpdatedAtMs;

  /// Parent session path from the header (subagent chains).
  final String? parentSessionPath;

  /// Free-form header metadata (same shape the header carried).
  final Map<String, dynamic>? metadata;

  /// Display name learned by a lazy name probe (session_info record).
  /// Survives only while the file's stats stay identical — an appended
  /// rename record changes the stats and the name is re-learned.
  final String? name;

  /// Whether the walk saw `.part-NN` segment siblings for this session.
  final bool hasParts;

  /// Returns a copy with [name] replaced.
  SessionListingIndexEntry withName(String? name) => SessionListingIndexEntry(
    id: id,
    path: path,
    sizeBytes: sizeBytes,
    mtimeMs: mtimeMs,
    createdAtIso: createdAtIso,
    cwd: cwd,
    lastUpdatedAtMs: lastUpdatedAtMs,
    parentSessionPath: parentSessionPath,
    metadata: metadata,
    name: name,
    hasParts: hasParts,
  );

  /// Returns a copy with the stat pair (and part flag) refreshed — used
  /// by the writer path after a rotation moved records into segments.
  SessionListingIndexEntry withStats({
    required int sizeBytes,
    required int mtimeMs,
    bool? hasParts,
  }) {
    final currentParts = this.hasParts;
    return SessionListingIndexEntry(
      id: id,
      path: path,
      sizeBytes: sizeBytes,
      mtimeMs: mtimeMs,
      createdAtIso: createdAtIso,
      cwd: cwd,
      lastUpdatedAtMs: lastUpdatedAtMs,
      parentSessionPath: parentSessionPath,
      metadata: metadata,
      name: name,
      hasParts: hasParts ?? currentParts,
    );
  }

  /// Decodes one entry; null on any shape drift (the whole index is then
  /// treated as cold — fail-open, never fail boot).
  static SessionListingIndexEntry? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    final path = json['path'];
    final size = json['size'];
    final mtime = json['mtime'];
    final createdAt = json['createdAt'];
    final cwd = json['cwd'];
    if (id is! String ||
        path is! String ||
        size is! int ||
        mtime is! int ||
        createdAt is! String ||
        cwd is! String) {
      return null;
    }
    final lastUpdated = json['lastUpdatedAt'];
    final parent = json['parent'];
    final meta = json['meta'];
    final name = json['name'];
    final parts = json['parts'];
    return SessionListingIndexEntry(
      id: id,
      path: path,
      sizeBytes: size,
      mtimeMs: mtime,
      createdAtIso: createdAt,
      cwd: cwd,
      lastUpdatedAtMs: lastUpdated is int ? lastUpdated : null,
      parentSessionPath: parent is String ? parent : null,
      metadata: meta is Map<String, dynamic> ? meta : null,
      name: name is String ? name : null,
      hasParts: parts == true,
    );
  }

  /// Encodes the entry (compact keys — hundreds of rows ride in one
  /// small JSON file).
  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    'size': sizeBytes,
    'mtime': mtimeMs,
    'createdAt': createdAtIso,
    'cwd': cwd,
    'lastUpdatedAt': ?lastUpdatedAtMs,
    'parent': ?parentSessionPath,
    'meta': ?metadata,
    'name': ?name,
    'parts': ?(hasParts ? true : null),
  };
}

/// The persisted listing index of one sessions root.
final class SessionListingIndex {
  /// The schema version this build reads and writes. An index written by
  /// another version is ignored (cold scan) — never guessed at.
  static const int currentVersion = 1;

  /// Creates an index snapshot.
  SessionListingIndex({
    this.version = currentVersion,
    required this.dirStats,
    required this.entries,
    required this.writtenAtMs,
  });

  /// Schema version of this snapshot.
  final int version;

  /// Per-directory fingerprint terms, keyed by the directory's path
  /// relative to the sessions root ('' = the root itself).
  final Map<String, ListingDirStats> dirStats;

  /// One row per seen session file.
  final List<SessionListingIndexEntry> entries;

  /// When this snapshot was written (epoch ms).
  final int writtenAtMs;

  /// Entry for [path], or null.
  SessionListingIndexEntry? entryFor(String path) {
    for (final entry in entries) {
      if (entry.path == path) return entry;
    }
    return null;
  }

  /// Entry by session id, or null.
  SessionListingIndexEntry? entryById(String id) {
    for (final entry in entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  /// Returns a copy with [entries] replaced (the store mutates by
  /// rebuilding — snapshots are treated as immutable).
  SessionListingIndex withEntries(List<SessionListingIndexEntry> entries) =>
      SessionListingIndex(
        version: version,
        dirStats: dirStats,
        entries: entries,
        writtenAtMs: writtenAtMs,
      );

  /// Returns a copy with [dirStats] replaced.
  SessionListingIndex withDirStats(Map<String, ListingDirStats> dirStats) =>
      SessionListingIndex(
        version: version,
        dirStats: dirStats,
        entries: entries,
        writtenAtMs: writtenAtMs,
      );

  /// Decodes an index; null on ANY shape problem (missing/foreign JSON,
  /// wrong version, bad rows) — the caller falls back to the cold scan.
  static SessionListingIndex? fromJson(Object? json) {
    if (json is! Map) return null;
    final version = json['version'];
    final dirs = json['dirs'];
    final rows = json['entries'];
    final writtenAt = json['writtenAt'];
    if (version is! int ||
        dirs is! Map ||
        rows is! List ||
        writtenAt is! int) {
      return null;
    }
    final dirStats = <String, ListingDirStats>{};
    for (final entry in dirs.entries) {
      final key = entry.key;
      final stats = ListingDirStats.fromJson(entry.value);
      if (key is! String || stats == null) return null;
      dirStats[key] = stats;
    }
    final entries = <SessionListingIndexEntry>[];
    for (final row in rows) {
      final entry = SessionListingIndexEntry.fromJson(row);
      if (entry == null) return null;
      entries.add(entry);
    }
    return SessionListingIndex(
      version: version,
      dirStats: dirStats,
      entries: entries,
      writtenAtMs: writtenAt,
    );
  }

  /// Encodes the index.
  Map<String, Object?> toJson() => {
    'version': version,
    'writtenAt': writtenAtMs,
    'dirs': {
      for (final entry in dirStats.entries) entry.key: entry.value.toJson(),
    },
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// Reads and writes `<root>/.listing-index.json` on a [FileSystem].
///
/// Every operation fails open: a read that fails, or decodes to a foreign
/// shape, yields null (the caller rescans); a write that fails is dropped
/// (the next listing rebuilds the index). Writers serialize through
/// tmp + rename when the backend supports atomic renames — two processes
/// (CLI + app) racing then converge last-writer-wins, and the fingerprint
/// cross-check on the next listing is the tiebreaker.
final class SessionListingIndexStore {
  /// Creates a store (constant — the store is stateless).
  const SessionListingIndexStore();

  /// Sidecar name under the sessions root. Dot-prefixed so legacy
  /// directory listings and trash sweeps never see it.
  static const String fileName = '.listing-index.json';

  /// In-flight temp name; consumed by the atomic rename on renamable
  /// backends, removed best-effort otherwise.
  static const String _tmpSuffix = '.tmp';

  /// Reads the root's index; null when absent, unreadable, or of a
  /// foreign/corrupt shape (issue #2053 AC7 — fail-open).
  Future<SessionListingIndex?> read(FileSystem fs, String root) async {
    try {
      final finalPath = await _finalPath(fs, root);
      final read = await fs.readTextFile(finalPath);
      if (read.isErr) return null;
      final text = read.valueOrNull;
      if (text == null || text.isEmpty) return null;
      final Object? decoded;
      try {
        decoded = json_conv.jsonDecode(text);
      } on Object {
        return null; // torn / foreign content — cold scan, never a crash.
      }
      final index = SessionListingIndex.fromJson(decoded);
      if (index == null || index.version != SessionListingIndex.currentVersion) {
        return null;
      }
      return index;
    } on Object {
      return null;
    }
  }

  /// Writes [index] atomically-ish: text to a tmp sibling, then a rename
  /// over the final name (renamable backends), or a direct write of the
  /// final name otherwise. Returns true when a write was observed
  /// successful; any failure is swallowed (cache-only concern).
  Future<bool> write(FileSystem fs, String root, SessionListingIndex index) async {
    try {
      final finalPath = await _finalPath(fs, root);
      final tmpPath = '$finalPath$_tmpSuffix';
      final text = json_conv.jsonEncode(index.toJson());
      final staged = await fs.writeFile(tmpPath, text);
      if (staged.isErr) {
        // Cannot stage: try the direct write (best effort, non-atomic).
        final direct = await fs.writeFile(finalPath, text);
        return direct.isOk;
      }
      if (fs case final RenamableFileSystem renamable) {
        final renamed = await renamable.renamePath(tmpPath, finalPath);
        if (renamed.isOk) return true;
        // Rename refused: fall through to the direct write, and clean the
        // staged tmp so the root does not litter.
        await fs.remove(tmpPath, force: true);
      }
      final direct = await fs.writeFile(finalPath, text);
      return direct.isOk;
    } on Object {
      return false;
    }
  }

  Future<String> _finalPath(FileSystem fs, String root) async {
    final joined = await fs.joinPath([root, fileName]);
    if (joined.isErr) {
      // joinPath failing is exotic (root vanished mid-call); the plain
      // concatenation keeps the cache best-effort instead of throwing.
      return '$root/$fileName';
    }
    return joined.valueOrNull ?? '$root/$fileName';
  }
}
