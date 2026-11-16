// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pure, host-neutral projection of a device's persisted session catalog.
///
/// The CLI and Flutter hosts both use this file: stores supply metadata-only
/// rows, this projection normalizes/sorts/caps them, computes minimal deltas,
/// and pages full snapshots to the fa_network roster PATCH limit. No
/// transcript content beyond the bounded first-prompt snippet crosses it.
library;

/// Maximum rows published by one device. Stores with more rows expose the
/// newest [maxSessionCatalogEntries]; all rows below the cap are retained.
const maxSessionCatalogEntries = 4096;

/// Maximum session rows in one roster PATCH (the deployed server limit).
const sessionCatalogRosterPageSize = 40;

/// Display-field bounds shared with the additive roster contract.
const sessionCatalogTitleMaxRunes = 120;
const sessionCatalogSnippetMaxRunes = 160;
const sessionCatalogPathMaxRunes = 240;

/// Loads the device's complete persisted-session metadata catalog.
abstract interface class SessionCatalogStore {
  /// Loads every stored session. [liveSessionIds] is a hint used only to set
  /// [SessionCatalogEntry.live]; it must not filter the persisted corpus.
  Future<List<SessionCatalogEntry>> loadSessions({
    Set<String> liveSessionIds = const {},
  });
}

/// One metadata-only persisted session row.
final class SessionCatalogEntry {
  /// Builds a catalog row. [title] is the preferred display title;
  /// [sessionName] is the explicit `--session`/`session_info` name used by
  /// the headless wake command. They differ when the title is a fallback.
  const SessionCatalogEntry({
    required this.id,
    required this.live,
    required this.cwd,
    required this.lastActiveAt,
    this.title,
    this.snippet,
    this.sessionName,
  });

  final String id;
  final bool live;
  final String? title;
  final String? snippet;
  final String? sessionName;
  final String cwd;
  final DateTime lastActiveAt;

  /// Human label: explicit/derived title, then first-prompt snippet, then
  /// cwd basename. A UUID is only the final short-id fallback, never the
  /// primary label when any human metadata exists.
  String get displayName => sessionCatalogDisplayName(this);

  /// Project directory basename, accepting both POSIX and Windows paths.
  String? get cwdSlug => sessionCatalogCwdSlug(cwd);

  /// Additive fa_network roster fields. Unknown additive keys are ignored by
  /// older peers; `path`/`lastActivity` retain the existing contract names.
  Map<String, Object?> toRosterMetadata() => {
    if (title != null) 'title': title,
    if (snippet != null) 'snippet': snippet,
    if (sessionName != null) 'sessionName': sessionName,
    if (cwd.isNotEmpty) 'path': cwd,
    if (cwdSlug != null) 'cwd': cwdSlug,
    'lastActivity': lastActiveAt.toUtc().toIso8601String(),
  };

  SessionCatalogEntry _normalized() {
    final normalizedId = id.trim();
    return SessionCatalogEntry(
      id: normalizedId,
      live: live,
      title: _displayText(title, sessionCatalogTitleMaxRunes),
      snippet: _displayText(snippet, sessionCatalogSnippetMaxRunes),
      sessionName: _displayText(sessionName, sessionCatalogTitleMaxRunes),
      cwd: _pathText(cwd),
      lastActiveAt: lastActiveAt.toUtc(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SessionCatalogEntry &&
      other.id == id &&
      other.live == live &&
      other.title == title &&
      other.snippet == snippet &&
      other.sessionName == sessionName &&
      other.cwd == cwd &&
      other.lastActiveAt == lastActiveAt;

  @override
  int get hashCode =>
      Object.hash(id, live, title, snippet, sessionName, cwd, lastActiveAt);
}

/// Result of projecting one complete store snapshot against the last one.
final class SessionCatalogProjection {
  const SessionCatalogProjection({
    required this.entries,
    required this.upserts,
    required this.retractedIds,
    required this.pages,
  });

  /// Complete normalized, newest-first catalog (including over-page rows).
  final List<SessionCatalogEntry> entries;

  /// Changed rows for a delta, or every row for an unpaged full snapshot.
  final List<SessionCatalogEntry> upserts;

  /// Ids that disappeared and must be removed from every exposure network.
  final List<String> retractedIds;

  /// Full snapshots larger than one PATCH use these pages instead of
  /// [upserts]. Null means callers use [upserts].
  final List<List<SessionCatalogEntry>>? pages;
}

/// Normalizes, sorts and caps one complete store snapshot.
List<SessionCatalogEntry> normalizeSessionCatalog(
  Iterable<SessionCatalogEntry> rows,
) {
  final byId = <String, SessionCatalogEntry>{};
  for (final row in rows) {
    final normalized = row._normalized();
    if (normalized.id.isEmpty) continue;
    // Duplicate ids are a store defect, not a reason to duplicate wire rows.
    // Prefer a live row; otherwise the later row is the freshest projection.
    final previous = byId[normalized.id];
    if (previous == null || normalized.live || !previous.live) {
      byId[normalized.id] = normalized;
    }
  }
  final entries = byId.values.toList()
    ..sort((left, right) {
      final activity = right.lastActiveAt.compareTo(left.lastActiveAt);
      return activity != 0 ? activity : left.id.compareTo(right.id);
    });
  if (entries.length > maxSessionCatalogEntries) {
    entries.removeRange(maxSessionCatalogEntries, entries.length);
  }
  return List.unmodifiable(entries);
}

/// Computes a minimal delta, or a complete (and, when needed, paged) connect
/// snapshot. Diffing happens AFTER normalization so caps/whitespace/UTC do
/// not cause metadata-only republish loops.
SessionCatalogProjection projectSessionCatalog({
  required Iterable<SessionCatalogEntry> previous,
  required Iterable<SessionCatalogEntry> current,
  bool fullSnapshot = false,
}) {
  final before = {
    for (final row in normalizeSessionCatalog(previous)) row.id: row,
  };
  final entries = normalizeSessionCatalog(current);
  final now = {for (final row in entries) row.id: row};
  final retracted = before.keys.where((id) => !now.containsKey(id)).toList()
    ..sort();
  if (fullSnapshot) {
    if (entries.length > sessionCatalogRosterPageSize) {
      final pages = <List<SessionCatalogEntry>>[
        for (
          var start = 0;
          start < entries.length;
          start += sessionCatalogRosterPageSize
        )
          List.unmodifiable(
            entries.sublist(
              start,
              (start + sessionCatalogRosterPageSize).clamp(0, entries.length),
            ),
          ),
      ];
      return SessionCatalogProjection(
        entries: entries,
        upserts: const [],
        retractedIds: List.unmodifiable(retracted),
        pages: List.unmodifiable(pages),
      );
    }
    return SessionCatalogProjection(
      entries: entries,
      upserts: entries,
      retractedIds: List.unmodifiable(retracted),
      pages: null,
    );
  }
  return SessionCatalogProjection(
    entries: entries,
    upserts: List.unmodifiable([
      for (final row in entries)
        if (before[row.id] != row) row,
    ]),
    retractedIds: List.unmodifiable(retracted),
    pages: null,
  );
}

/// Human display fallback shared by CLI output and Flutter session cards.
String sessionCatalogDisplayName(SessionCatalogEntry row) {
  final title = _displayText(row.title, sessionCatalogTitleMaxRunes);
  if (title != null && title != row.id) return title;
  final snippet = _displayText(row.snippet, sessionCatalogSnippetMaxRunes);
  if (snippet != null && snippet != row.id) return snippet;
  final slug = row.cwdSlug;
  if (slug != null && slug.isNotEmpty) return slug;
  final shortId = _looksLikeUuid(row.id) && row.id.length > 8
      ? row.id.substring(0, 8)
      : row.id;
  return 'Session $shortId';
}

/// Basename used as the compact cwd label.
String? sessionCatalogCwdSlug(String path) {
  final trimmed = path.trim().replaceAll(RegExp(r'[/\\]+$'), '');
  if (trimmed.isEmpty) return null;
  final cut = trimmed.lastIndexOf(RegExp(r'[/\\]'));
  final slug = trimmed.substring(cut + 1).trim();
  return slug.isEmpty ? null : slug;
}

/// Compact relative activity for roster/CLI rows.
String formatSessionCatalogRelativeTime(DateTime? value, {DateTime? now}) {
  if (value == null) return 'unknown';
  final reference = (now ?? DateTime.now()).toUtc();
  var seconds = reference.difference(value.toUtc()).inSeconds;
  if (seconds < 0) seconds = 0;
  if (seconds < 45) return 'now';
  if (seconds < 3600) return '${(seconds / 60).round()}m ago';
  if (seconds < 86400) return '${(seconds / 3600).round()}h ago';
  return '${(seconds / 86400).round()}d ago';
}

String? _displayText(String? value, int maxRunes) {
  final normalized = value?.trim().replaceAll(RegExp(r'\s+'), ' ') ?? '';
  if (normalized.isEmpty) return null;
  return _clipRunes(normalized, maxRunes);
}

String _pathText(String value) {
  final normalized = value.trim();
  return _clipRunes(normalized, sessionCatalogPathMaxRunes);
}

String _clipRunes(String value, int maxRunes) {
  final runes = value.runes;
  if (runes.length <= maxRunes) return value;
  return String.fromCharCodes(runes.take(maxRunes));
}

bool _looksLikeUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
).hasMatch(value);
