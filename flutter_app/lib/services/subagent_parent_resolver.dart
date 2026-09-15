// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_agent_harness/flutter_agent_harness.dart'
    show SessionMetadata, isSubagentSession, subagentParentId;

/// Re-links subagent sessions to their parents when the session header
/// lost the link (issue #426).
///
/// WHY THIS EXISTS: a child's parent link lives in its session-file header
/// (`metadata: {agent: 'subagent', parent: <mainSessionId>}`), but both
/// hosts used to construct the subagent manager with an empty
/// `parentSessionId`, so real child files were written with `parent: ""`.
/// `subagentParentId` returns null for the empty string and the sidebar's
/// tree degrades to a flat `subagent <id>` list.
///
/// The surviving link is in the PARENT transcript: at turn boundaries the
/// parent appends a `subagent_registry` record whose entries carry the
/// child session's file path (`sessionId`). This resolver scans parent
/// transcripts for the LAST such record and maps child session id →
/// parent session id.
///
/// Bounded by design — this runs on the UI's persisted-session reload:
/// - only parent files are read, newest first, and the pass stops as soon
///   as every unresolved child found a home;
/// - each parent is read from the END in expanding windows up to
///   [maxTailBytes] (a registry appended this turn sits at EOF; one
///   appended hours ago may sit megabytes deep — beyond the budget the
///   child stays unresolved and renders flat, the documented fallback);
/// - results are cached per file path + mtime, so steady-state reloads
///   (the common case) read nothing.
///
/// Fresh sessions are unaffected: a child whose header already names its
/// parent is not part of the resolution at all, and once hosts write real
/// parent ids this scan finds no work and costs nothing.
final class SubagentParentResolver {
  /// Creates a resolver. [maxTailBytes] caps how deep into a parent
  /// transcript the backward scan may reach.
  SubagentParentResolver({this.maxTailBytes = 16 * 1024 * 1024});

  /// The tail-scan budget per parent transcript.
  final int maxTailBytes;

  /// Cached scan result per parent file path: the listing mtime the result
  /// was computed from plus the registry's child FILE links.
  final Map<String, ({DateTime? mtime, Set<String> links})> _cache = {};

  /// Returns child session id → parent session id for every [sessions]
  /// entry classified as a subagent whose header parent is missing or
  /// empty. Never throws: a broken transcript yields no links, never an
  /// error (the sidebar must list regardless).
  Future<Map<String, String>> resolve(List<SessionMetadata> sessions) async {
    if (kIsWeb) return const {};
    final unresolved = <String, SessionMetadata>{
      for (final session in sessions)
        if (isSubagentSession(session) && subagentParentId(session) == null)
          session.id: session,
    };
    if (unresolved.isEmpty) return const {};
    // Registry entries carry the child FILE path as recorded at attach
    // time — exact when the root still matches, basename-only after a
    // root drift (legacy per-project layout → shared container).
    final childIdByLink = <String, String>{
      for (final child in unresolved.values) ...{
        child.path: child.id,
        basename(child.path): child.id,
      },
    };
    final parents =
        sessions.where((s) => !isSubagentSession(s)).toList()
          ..sort((a, b) {
            final result = (b.lastUpdatedAt ?? b.createdAt).compareTo(
              a.lastUpdatedAt ?? a.createdAt,
            );
            if (result != 0) return result;
            return b.id.compareTo(a.id);
          });
    final resolved = <String, String>{};
    for (final parent in parents) {
      if (resolved.length == unresolved.length) break;
      for (final link in await _linksFor(parent)) {
        final childId = childIdByLink[link] ?? childIdByLink[basename(link)];
        if (childId == null) continue;
        if (resolved.containsKey(childId)) continue;
        resolved[childId] = parent.id;
      }
    }
    return resolved;
  }

  /// The child FILE links (paths or basenames, exactly as the registry
  /// recorded them) found in [parent]'s last registry record, cached by
  /// the listing mtime.
  Future<Set<String>> _linksFor(SessionMetadata parent) async {
    final cached = _cache[parent.path];
    if (cached != null && cached.mtime == parent.lastUpdatedAt) {
      return cached.links;
    }
    final links = await _scanRegistryLinks(parent.path) ?? const <String>{};
    _cache[parent.path] = (mtime: parent.lastUpdatedAt, links: links);
    return links;
  }

  /// Reads [path] from the end in expanding windows and parses the LAST
  /// `subagent_registry` record inside them. Returns the record's child
  /// links, or null when no parsable record exists in the whole reachable
  /// tail (or the file is unreadable) so the caller caches the miss.
  Future<Set<String>?> _scanRegistryLinks(String path) async {
    try {
      final file = File(path);
      final length = await file.length();
      for (var window = 256 * 1024; ; window *= 4) {
        final capped = window > maxTailBytes ? maxTailBytes : window;
        final start = length > capped ? length - capped : 0;
        final tail = await _readTail(file, start, length - start);
        final parsed = _parseRegistryLinks(tail);
        if (parsed != null) return parsed;
        if (start == 0 || capped >= maxTailBytes) return null;
      }
    } on FileSystemException {
      return null;
    }
  }

  Future<String> _readTail(File file, int start, int length) async {
    final raf = await file.open();
    try {
      await raf.setPosition(start);
      final bytes = await raf.read(length);
      return utf8.decode(bytes, allowMalformed: true);
    } finally {
      await raf.close();
    }
  }
}

/// Finds the last *parsable* `subagent_registry` record in [tail] and
/// returns the child file links its entries carry. Null when the tail
/// holds no parsable record (caller widens the window; at the file start
/// it caches the miss). Markers are tried last-to-first: a corrupt or
/// truncated newest record (a window can cut a line's head, a crash can
/// leave a partial line) falls back to the previous complete record.
Set<String>? _parseRegistryLinks(String tail) {
  final markers = <int>[];
  const key = '"customType"';
  const compact = ':"subagent_registry"';
  const spaced = ': "subagent_registry"';
  var found = tail.indexOf(key);
  while (found >= 0) {
    final after = found + key.length;
    if (tail.startsWith(compact, after) || tail.startsWith(spaced, after)) {
      markers.add(found);
    }
    found = tail.indexOf(key, found + 1);
  }
  if (markers.isEmpty) return null;
  for (final at in markers.reversed) {
    // The marker sits mid-record (after type/id fields) — widen to the
    // record's full line before decoding.
    final lineStart = at == 0 ? 0 : tail.lastIndexOf('\n', at - 1) + 1;
    final end = tail.indexOf('\n', at);
    final line = tail.substring(
      lineStart,
      end < 0 ? tail.length : end,
    );
    try {
      final record = jsonDecode(line);
      if (record is! Map) continue;
      final data = record['data'];
      if (data is! List) continue;
      return {
        for (final entry in data)
          if (entry is Map && entry['sessionId'] is String)
            entry['sessionId'] as String,
      };
    } on FormatException {
      // Truncated or corrupt record — the previous marker is next.
    }
  }
  return null;
}

/// The last path segment — local stand-in for `p.basename` so this service
/// carries no path-package dependency.
String basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}
