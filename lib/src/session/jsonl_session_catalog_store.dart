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
import 'session_record.dart';
import 'session_repo.dart';
import 'session_storage.dart';

/// Reads the repo's indexed listing and lazily probes only display data that
/// the header does not carry. First-prompt reads are bounded (128 KiB at the
/// file head, 16-way fan-out) and cached by path+size+mtime; the catalog never
/// materializes whole transcripts on ranged filesystems.
final class JsonlSessionCatalogStore implements SessionCatalogStore {
  JsonlSessionCatalogStore({required this.repo});

  final JsonlSessionRepo repo;
  final _promptCache = <String, _CachedPrompt>{};

  /// Number of cold/changed transcript-head probes (test/diagnostic seam).
  int get debugTranscriptScans => _transcriptScans;
  var _transcriptScans = 0;

  @override
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  }) async {
    final sessions = await repo.list();
    // The persisted listing index is the zero-probe name source. Probe only
    // missing/stale names, then remember them for the next process/boot.
    final names = await repo.knownSessionNames();
    final missing = [
      for (final session in sessions)
        if (!names.containsKey(session.id)) session,
    ];
    if (missing.isNotEmpty) {
      names.addAll(await repo.sessionNamesQuick(missing));
      await repo.rememberSessionNames(names);
    }
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
          title: names[sessions[i].id],
          sessionName: names[sessions[i].id],
          snippet: snippets[i],
          cwd: sessions[i].cwd,
          lastActiveAt: sessions[i].lastUpdatedAt ?? sessions[i].createdAt,
        ),
    ];
  }

  Future<String?> _firstPrompt(SessionMetadata session) async {
    final stamp =
        '${session.sizeBytes}:'
        '${session.lastUpdatedAt?.millisecondsSinceEpoch ?? 0}';
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
      if (lines != null) {
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
          final runes = text.runes;
          snippet = String.fromCharCodes(
            runes.take(sessionCatalogSnippetMaxRunes),
          );
          break;
        }
      }
    } on Object {
      // A broken/foreign session remains in the catalog with path/id fallback.
      snippet = null;
    }
    _promptCache[session.path] = _CachedPrompt(stamp, snippet);
    return snippet;
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
