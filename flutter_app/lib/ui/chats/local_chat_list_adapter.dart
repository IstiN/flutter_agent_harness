import 'dart:async';
import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:path/path.dart' as p;

import 'chat_list_entry.dart';

abstract interface class LocalChatListSource {
  Future<List<ChatListEntry>> load();
}

/// A local source whose backing session state can change between explicit
/// loads. The controller subscribes to [changes] and reloads the projection.
abstract interface class LocalChatListChangeSource
    implements LocalChatListSource {
  Listenable get changes;
}

/// Deterministic local source for controller and widget tests.
final class StaticChatListAdapter implements LocalChatListSource {
  StaticChatListAdapter(this.entries);

  final List<ChatListEntry> entries;

  @override
  Future<List<ChatListEntry>> load() async => List.of(entries);
}

typedef LocalChatTitleBuilder =
    String Function(String id, DateTime createdAt, bool isSubagent);

/// Projects live + persisted Flutter sessions into messenger rows without
/// opening every session or inventing persisted previews.
final class LocalChatListAdapter implements LocalChatListChangeSource {
  LocalChatListAdapter({
    required this.manager,
    required this.titleBuilder,
    this.sessionInfoNames = const {},
    this.readPersistedNames = true,
    this.namesStore,
    LocalChatPreviewReader? previewReader,
  }) : previewReader = previewReader ?? LocalChatPreviewReader(manager.env);

  final FlutterSessionManager manager;
  final Map<String, String> sessionInfoNames;

  /// False when the host already supplied the authoritative JSONL name
  /// snapshot in [sessionInfoNames], avoiding a duplicate disk scan.
  final bool readPersistedNames;
  final SessionNamesStore? namesStore;
  final LocalChatTitleBuilder titleBuilder;
  final LocalChatPreviewReader previewReader;

  @override
  Listenable get changes => manager;

  @override
  Future<List<ChatListEntry>> load() async {
    // A constructor snapshot can predate a successful delete (and an older
    // async host refresh can finish after a newer one). Always project the
    // fresh manager/store listing so no cached row can resurrect a session.
    // AC5 (#2053): concurrent loads share the manager's ONE listing pass.
    final persisted = await manager.listPersistedSessions();
    final live = manager.sessions;
    final liveIds = live.map((session) => session.id).toSet();
    final persistedById = {
      for (final metadata in persisted) metadata.id: metadata,
    };
    // Issue #2053 AC4: names leave the boot path. Rows render with the
    // names already known (persisted listing index + previous fills) and
    // the bounded background fill tops up the rest — it completes after
    // this projection and repaints through [changes] (the manager).
    var jsonlNames = const <String, String>{};
    if (readPersistedNames) {
      jsonlNames = manager.knownSessionNames;
      if (persisted.isNotEmpty) {
        unawaited(manager.warmSessionNames(persisted));
      }
    }
    final infoNames = {...jsonlNames, ...sessionInfoNames};
    final entries = <ChatListEntry>[];
    for (final session in live) {
      final metadata = persistedById[session.id];
      final createdAt = metadata?.createdAt ?? session.createdAt;
      final isSubagent = metadata != null && isSubagentSession(metadata);
      final cwd =
          metadata?.cwd ??
          session.service.currentSessionCwd ??
          session.service.env.cwd;
      entries.add(
        ChatListEntry(
          id: ChatEntryId.local(session.id),
          kind: ChatListEntryKind.localAgent,
          title: _title(session.id, createdAt, isSubagent, infoNames),
          createdAt: createdAt,
          lastActivity:
              metadata?.lastUpdatedAt ??
              metadata?.createdAt ??
              session.lastUpdatedAt,
          preview: _livePreview(session.service),
          folderName: _folderName(cwd),
          folderPath: _folderPath(cwd),
          unreadCount: 0,
          isStreaming: session.service.isStreaming,
          presence: session.service.isStreaming ? ChatPresence.busy : null,
          parentId: metadata == null ? null : subagentParentId(metadata),
          isSubagent: isSubagent,
          localMessageCount: session.service.messages.length,
        ),
      );
    }
    for (final metadata in persisted) {
      if (liveIds.contains(metadata.id)) continue;
      final isSubagent = isSubagentSession(metadata);
      entries.add(
        ChatListEntry(
          id: ChatEntryId.local(metadata.id),
          kind: ChatListEntryKind.localAgent,
          title: _title(metadata.id, metadata.createdAt, isSubagent, infoNames),
          createdAt: metadata.createdAt,
          lastActivity: metadata.lastUpdatedAt ?? metadata.createdAt,
          preview: await previewReader.read(metadata),
          folderName: _folderName(metadata.cwd),
          folderPath: _folderPath(metadata.cwd),
          unreadCount: 0,
          parentId: subagentParentId(metadata),
          isSubagent: isSubagent,
        ),
      );
    }
    return entries;
  }

  String _title(
    String id,
    DateTime createdAt,
    bool isSubagent,
    Map<String, String> infoNames,
  ) =>
      namesStore?.titleFor(id) ??
      infoNames[id] ??
      titleBuilder(id, createdAt, isSubagent);

  static String? _folderName(String? cwd) {
    if (cwd == null || cwd.isEmpty) return null;
    final name = p.basename(cwd);
    return name.isEmpty || name == '/' || name == '.' ? null : name;
  }

  static String? _folderPath(String? cwd) {
    if (cwd == null || _folderName(cwd) == null) return null;
    return cwd;
  }

  static String? _livePreview(AgentService service) {
    for (final message in service.messages.reversed) {
      if (message.role != 'user' && message.role != 'assistant') continue;
      final text = message.content.trim();
      if (text.isNotEmpty) return text;
    }
    return null;
  }
}

/// Reads only the persisted transcript tail when the filesystem supports
/// ranges. A truncated/encrypted/unknown record produces no preview, never a
/// synthetic "last message".
final class LocalChatPreviewReader {
  LocalChatPreviewReader(this.env, {this.tailBytes = 128 * 1024});

  final ExecutionEnv env;
  final int tailBytes;

  Future<String?> read(SessionMetadata metadata) async {
    try {
      String? text;
      var skipPartialFirstLine = false;
      final env = this.env;
      final ranged = env is RangedReadFileSystem
          ? env as RangedReadFileSystem
          : null;
      if (ranged != null) {
        final info = (await env.fileInfo(metadata.path)).valueOrNull;
        if (info != null) {
          final start = (info.size - tailBytes).clamp(0, info.size);
          final bytes = (await ranged.readRange(
            metadata.path,
            start,
            info.size,
          )).valueOrNull;
          if (bytes != null) {
            text = utf8.decode(bytes, allowMalformed: true);
            skipPartialFirstLine = start > 0;
          }
        }
      }
      text ??= (await env.readTextFile(metadata.path)).valueOrNull;
      if (text == null || text.isEmpty) return null;
      var lines = const LineSplitter().convert(text);
      if (skipPartialFirstLine && lines.isNotEmpty) {
        lines = lines.sublist(1);
      }
      for (final line in lines.reversed) {
        if (line.trim().isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is! Map<String, dynamic>) continue;
          final record = SessionRecord.fromJson(decoded);
          if (record is! MessageRecord) continue;
          final message = record.message;
          if (message is! UserMessage && message is! AssistantMessage) continue;
          final preview = AgentService.tailMessagePairs([
            message,
          ], 1).first.$2.trim();
          if (preview.isNotEmpty) return preview;
        } on Object {
          // Ignore non-message/torn tail lines and keep looking backwards.
        }
      }
    } on Object {
      return null;
    }
    return null;
  }
}
