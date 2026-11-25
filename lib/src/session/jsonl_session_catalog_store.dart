// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Metadata-only [SessionCatalogStore] over a [JsonlSessionRepo].
library;

import 'dart:convert';
import 'dart:math' as math;

import '../context.dart';
import '../env/execution_env.dart';
import '../user_text.dart';
import 'session_catalog.dart';
import 'session_grouping.dart';
import 'session_record.dart';
import 'session_repo.dart';
import 'session_storage.dart';

/// Reads the repo's indexed listing and lazily probes only display data that
/// the header does not carry. First-prompt reads are bounded (128 KiB at the
/// file head, 16-way fan-out); they and the name probes are memoized per file
/// under its (size, mtime) stamp, so a refresh of an unchanged store costs
/// ZERO transcript reads and only stats (gh-2410: the name probe used to
/// re-read the windows of every unnamed session on every periodic pass — the
/// idle-CPU burn on large stores). The catalog never materializes whole
/// transcripts on ranged filesystems.
final class JsonlSessionCatalogStore implements SessionCatalogStore {
  JsonlSessionCatalogStore({required this.repo});

  final JsonlSessionRepo repo;
  final _promptCache = <String, _CachedPrompt>{};

  /// Name-probe memo keyed by file path: the stamp the probe ran under and
  /// its answer (`null` = probed, the file carries no `session_info` name).
  final _nameCache = <String, _CachedName>{};

  /// Number of cold/changed transcript-head probes (test/diagnostic seam).
  int get debugTranscriptScans => _transcriptScans;

  /// Files currently held in the stamp cache (test/diagnostic seam).
  int get debugCachedSessions => _promptCache.length;
  var _transcriptScans = 0;

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async {
    final sessions = await repo.list();
    _forgetRemoved(sessions);
    final names = await _sessionNames(sessions);
    final snippets = List<String?>.filled(sessions.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < sessions.length) {
        final index = next++;
        snippets[index] = await _firstPrompt(sessions[index]);
      }
    }

    await Future.wait([
      for (var i = 0; i < 16 && i < sessions.length; i++) worker(),
    ]);
    return [
      for (var i = 0; i < sessions.length; i++)
        SessionCatalogEntry(
          id: sessions[i].id,
          live: liveSessionIds.contains(sessions[i].id),
          isSubagent: isSubagentSession(sessions[i]),
          title: names[sessions[i].id],
          sessionName: names[sessions[i].id],
          snippet: snippets[i],
          cwd: sessions[i].cwd,
          lastActiveAt: sessions[i].lastUpdatedAt ?? sessions[i].createdAt,
        ),
    ];
  }

  /// Display names of [sessions]: the persisted listing index's learned
  /// names first (the zero-probe source, stat-validated), then this
  /// process's probe memo, then ONE bounded probe per file that is still
  /// unnamed AND unprobed under its current stamp. A session without a
  /// `session_info` record never gains a name, so re-probing it on every
  /// refresh only re-read its windows (measured ~1 GiB per pass on a
  /// 1450-file store, 1420 of them unnamed). Freshly learned names are
  /// remembered for the next process/boot.
  Future<Map<String, String>> _sessionNames(
    List<SessionMetadata> sessions,
  ) async {
    // A copy: the repo hands out an unmodifiable map (const {} without a
    // persisted index), and the probe results are merged in below.
    final names = Map.of(await repo.knownSessionNames());
    final missing = <SessionMetadata>[];
    for (final session in sessions) {
      if (names.containsKey(session.id)) continue;
      final probed = _nameCache[session.path];
      if (probed != null && probed.stamp == _stamp(session)) {
        if (probed.name case final name?) names[session.id] = name;
        continue;
      }
      missing.add(session);
    }
    if (missing.isEmpty) return names;
    names.addAll(await repo.sessionNamesQuick(missing));
    for (final session in missing) {
      _nameCache[session.path] = _CachedName(
        _stamp(session),
        names[session.id],
      );
    }
    await repo.rememberSessionNames(names);
    return names;
  }

  /// Drops the memo rows of files the listing no longer sees (deleted,
  /// trashed, moved) so both caches stay bounded by the live store.
  void _forgetRemoved(List<SessionMetadata> sessions) {
    final live = {for (final session in sessions) session.path};
    _promptCache.removeWhere((path, _) => !live.contains(path));
    _nameCache.removeWhere((path, _) => !live.contains(path));
  }

  /// Validity key of a per-file memo row: the file's size + mtime (the
  /// same stat pair the listing index validates its rows against).
  static String _stamp(SessionMetadata session) =>
      '${session.sizeBytes}:'
      '${session.lastUpdatedAt?.millisecondsSinceEpoch ?? 0}';

  Future<String?> _firstPrompt(SessionMetadata session) async {
    final stamp = _stamp(session);
    final cached = _promptCache[session.path];
    if (cached != null && cached.stamp == stamp) return cached.snippet;
    _transcriptScans++;
    String? snippet;
    try {
      final fs = repo.fileSystem;
      final lines = switch (fs) {
        final RangedReadFileSystem ranged => await _readHeadLines(
          ranged,
          session,
        ),
        _ => (await fs.readTextLines(session.path, maxLines: 256)).valueOrNull,
      };
      if (lines != null) snippet = _firstPromptFromLines(lines);
    } on Object {
      // A broken/foreign session remains in the catalog with path/id fallback.
      snippet = null;
    }
    _promptCache[session.path] = _CachedPrompt(stamp, snippet);
    return snippet;
  }

  String? _firstPromptFromLines(List<String> lines) {
    for (final line in lines) {
      if (line.trim().isEmpty) continue;
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on Object {
        continue;
      }
      if (decoded is! Map) continue;
      final SessionRecord record;
      try {
        record = SessionRecord.fromJson(decoded.cast<String, dynamic>());
      } on Object {
        continue;
      }
      if (record is! MessageRecord || record.message is! UserMessage) {
        continue;
      }
      final text = userMessageText(
        (record.message as UserMessage).content,
      ).replaceAll(RegExp(r'\s+'), ' ').trim();
      if (text.isEmpty || isSyntheticUserText(text)) continue;
      return String.fromCharCodes(
        text.runes.take(sessionCatalogSnippetMaxRunes),
      );
    }
    return null;
  }

  Future<List<String>> _readHeadLines(
    RangedReadFileSystem fs,
    SessionMetadata session,
  ) async {
    final end = math.min(session.sizeBytes ?? 128 * 1024, 128 * 1024);
    if (end <= 0) return const [];
    final bytes = (await fs.readRange(session.path, 0, end)).valueOrNull;
    if (bytes == null) return const [];
    return const LineSplitter().convert(
      utf8.decode(bytes, allowMalformed: true),
    );
  }
}

final class _CachedPrompt {
  const _CachedPrompt(this.stamp, this.snippet);

  final String stamp;
  final String? snippet;
}

final class _CachedName {
  const _CachedName(this.stamp, this.name);

  final String stamp;
  final String? name;
}
