// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:flutter/painting.dart'
    show Color, HSLColor;
import 'package:path/path.dart' as p;

import 'chat_list_entry.dart';

/// The pure Local-section model: persisted sessions grouped folder-first by
/// their session cwd, plus the deterministic folder-avatar algorithm ported
/// from the yoloit boards (two-stop HSL ramp + uppercase first rune).
///
/// Grouping happens client-side over the chat projection (whose rows ride
/// FlutterSessionManager's single-flight listing) — no extra disk reads.

/// One local session folder: every non-subagent session sharing one cwd.
final class LocalSessionFolder {
  const LocalSessionFolder({
    required this.id,
    required this.name,
    required this.personal,
    required this.sessions,
    required this.latestActivity,
    required this.runningCount,
  });

  /// The folder identity: the absolute cwd path ('' = the Personal sandbox).
  final String id;

  /// Display name: the cwd basename, or the host's Personal label.
  final String name;

  /// Whether this is the Personal (no cwd) group.
  final bool personal;

  /// The folder's sessions, most recent first.
  final List<ChatListEntry> sessions;

  /// The newest session activity in the folder (folder sort key).
  final DateTime? latestActivity;

  /// How many sessions are live and streaming right now.
  final int runningCount;

  /// The folder avatar's hue seed — the stable cwd string itself.
  String get avatarSeed => id;

  /// Alias of [id] for row assertions (the folder identity is its cwd).
  String get folder => id;
}

/// Groups the local chat projection into folders sorted by their most
/// recent session. [personalName] labels the empty-cwd group.
List<LocalSessionFolder> groupLocalSessionFolders(
  List<ChatListEntry> entries, {
  required String personalName,
}) {
  final byFolder = <String, List<ChatListEntry>>{};
  for (final entry in entries) {
    if (entry.kind != ChatListEntryKind.localAgent || entry.isSubagent) {
      continue;
    }
    final cwd = entry.folderPath ?? '';
    byFolder.putIfAbsent(cwd, () => []).add(entry);
  }
  final folders = <LocalSessionFolder>[];
  for (final id in byFolder.keys) {
    final sessions = [...byFolder[id]!]
      ..sort(_SessionOrder.compare);
    DateTime? latest;
    var running = 0;
    for (final session in sessions) {
      final activity = session.lastActivity ?? session.createdAt;
      if (latest == null || activity.isAfter(latest)) latest = activity;
      if (session.isStreaming) running++;
    }
    final personal = id.isEmpty;
    folders.add(
      LocalSessionFolder(
        id: id,
        name: personal ? personalName : _basename(id),
        personal: personal,
        sessions: List.unmodifiable(sessions),
        latestActivity: latest,
        runningCount: running,
      ),
    );
  }
  folders.sort((a, b) {
    final byTime = (b.latestActivity ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.latestActivity ?? DateTime.fromMillisecondsSinceEpoch(0));
    return byTime != 0 ? byTime : a.name.toLowerCase().compareTo(
      b.name.toLowerCase(),
    );
  });
  return folders;
}

String _basename(String cwd) {
  final name = p.basename(cwd.replaceAll('\\', '/'));
  return name.isEmpty || name == '/' || name == '.' ? cwd : name;
}

class _SessionOrder {
  static int compare(ChatListEntry a, ChatListEntry b) {
    final aTime = a.lastActivity ?? a.createdAt;
    final bTime = b.lastActivity ?? b.createdAt;
    final byTime = bTime.compareTo(aTime);
    return byTime != 0 ? byTime : a.id.canonical.compareTo(b.id.canonical);
  }
}

// ---------------------------------------------------------------------------
// Folder avatar algorithm (yoloit tier-1 port)
// ---------------------------------------------------------------------------

/// The folder's avatar hue: `folderId.hashCode.abs() % 360` — stable per
/// cwd across restarts.
int folderAvatarHue(String folderId) => folderId.hashCode.abs() % 360;

/// The deterministic two-stop gradient: HSL(hue, .45, .42) →
/// HSL(hue+32, .5, .3), painted topLeft → bottomRight.
(Color, Color) folderAvatarGradient(String folderId) {
  final hue = folderAvatarHue(folderId);
  return (
    HSLColor.fromAHSL(1, hue.toDouble(), 0.45, 0.42).toColor(),
    HSLColor.fromAHSL(1, ((hue + 32) % 360).toDouble(), 0.5, 0.3).toColor(),
  );
}

/// The avatar letter: the first Unicode rune of the trimmed name,
/// uppercased ('?' when there is nothing to show).
String folderAvatarLetter(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final rune = trimmed.runes.first;
  return String.fromCharCode(rune).toUpperCase();
}
