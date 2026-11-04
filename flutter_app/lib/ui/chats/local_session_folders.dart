// Copyright (c) 2026, the Flutter Agent Harness authors.

import 'package:flutter/painting.dart' show Color, HSLColor;
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
    final sessions = [...byFolder[id]!]..sort(_SessionOrder.compare);
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
    return byTime != 0
        ? byTime
        : a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return folders;
}

String _basename(String cwd) {
  final name = p.basename(cwd.replaceAll('\\', '/'));
  return name.isEmpty || name == '/' || name == '.' ? cwd : name;
}

class _SessionOrder {
  static int compare(ChatListEntry a, ChatListEntry b) =>
      compareSessionRecency(a, b);
}

/// The folder path a session entry belongs to: the entry's folderPath,
/// falling back to its folderName — the SAME identity the chats sidebar's
/// folder destinations group by (persisted rows may carry only the name).
/// Null for unfoldered (Personal) rows and non-local entries.
String? sessionEntryFolderPath(ChatListEntry entry) {
  if (entry.kind != ChatListEntryKind.localAgent) return null;
  final path = entry.folderPath ?? entry.folderName;
  if (path == null || path.isEmpty) return null;
  return path;
}

/// Orders folder sessions like the folder grouping does: most recent
/// activity first (createdAt fallback), stable by canonical id.
int compareSessionRecency(ChatListEntry a, ChatListEntry b) {
  final aTime = a.lastActivity ?? a.createdAt;
  final bTime = b.lastActivity ?? b.createdAt;
  final byTime = bTime.compareTo(aTime);
  return byTime != 0 ? byTime : a.id.canonical.compareTo(b.id.canonical);
}

/// The drill-down session list for one folder: every non-subagent entry
/// under [folderPath] (see [sessionEntryFolderPath]), most recent first —
/// the same rows [groupLocalSessionFolders] puts in the folder (subagents
/// never became folder sessions; they stay under their parent at root).
List<ChatListEntry> folderSessionList(
  List<ChatListEntry> entries, {
  required String folderPath,
}) => entries
    .where(
      (entry) =>
          sessionEntryFolderPath(entry) == folderPath && !entry.isSubagent,
    )
    .toList()
  ..sort(compareSessionRecency);

// ---------------------------------------------------------------------------
// Folder avatar algorithm (yoloit tier-1 port, vision-audit rework)
// ---------------------------------------------------------------------------

/// The fixed 10-slot palette the folder avatar's hue comes from: evenly
/// spread around the wheel so sibling folders never cluster into mud (the
/// old raw `% 360` ramp audited at S 28–46%, L 31–45% with visible hue
/// clustering).
const folderAvatarHues = [4, 40, 125, 150, 175, 200, 235, 265, 300, 335];

/// The folder avatar's hue: the palette slot at `folderId.hashCode.abs() %
/// 10` — deterministic per cwd across restarts, and never clustered.
int folderAvatarHue(String folderId) =>
    folderAvatarHues[folderId.hashCode.abs() % folderAvatarHues.length];

/// The deterministic two-stop gradient: HSL(hue, .72, .58) →
/// HSL(hue+30, .66, .42), painted topLeft → bottomRight. Saturated stops
/// that hold up on both the dark and light shells (the tiles sit on
/// glass/dark cards).
(Color, Color) folderAvatarGradient(String folderId) {
  final hue = folderAvatarHue(folderId);
  return (
    HSLColor.fromAHSL(1, hue.toDouble(), 0.72, 0.58).toColor(),
    HSLColor.fromAHSL(1, ((hue + 30) % 360).toDouble(), 0.66, 0.42).toColor(),
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
