import 'dart:async';
import 'dart:convert';

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/app_log.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa_ui/fa_ui.dart' show isFaSystemNoticeContent;
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

/// Per-manager preview state: the stamp-keyed preview cache plus the warm
/// generation guard. Lives on an [Expando] so the cache follows the
/// manager instance — the adapter is recreated on every projection
/// refresh, the manager is not (mirrors the manager's own name cache).
final class _PreviewWarmState {
  final Map<String, String> byStamp = {};
  int generation = 0;
}

final _previewWarmStates = Expando<_PreviewWarmState>();

/// Issues #2053 — the persisted transcript previews are OFF the first
/// emission: the boot path previously awaited one 128 KiB tail read per
/// persisted session (hundreds of IPC round-trips on the mount env ≈ the
/// reported ~6 s before the Local folders painted). The projection now
/// emits immediately with whatever the stamp cache holds. Only rows that
/// reach the viewport request a bounded fill, which notifies once at
/// completion; offscreen transcripts are never opened. Stamps (size +
/// mtime) key the cache, so a grown visible transcript re-reads once.
/// Projects live + persisted Flutter sessions into messenger rows without
/// opening every session or inventing persisted previews.
final class LocalChatListAdapter implements LocalChatListChangeSource {
  LocalChatListAdapter({
    required this.manager,
    required this.titleBuilder,
    this.sessionInfoNames = const {},
    this.readPersistedNames = true,
    this.namesStore,
    LocalChatPreviewSource? previewReader,
  }) : previewReader = previewReader ?? LocalChatPreviewReader(manager.env);

  final FlutterSessionManager manager;
  final Map<String, String> sessionInfoNames;

  /// False when the host supplies the JSONL-name snapshot used during
  /// projection in [sessionInfoNames]. Visible rows still warm unknown
  /// names through the manager so that host snapshot can refresh.
  final bool readPersistedNames;
  final SessionNamesStore? namesStore;
  final LocalChatTitleBuilder titleBuilder;
  final LocalChatPreviewSource previewReader;

  /// Last index-priced listing used by [warmVisible]. Metadata is cheap;
  /// no transcript content is read until a row reaches the viewport.
  List<SessionMetadata> _lastPersisted = const [];
  Map<String, SessionMetadata> _lastPersistedById = const {};
  Set<String> _lastLiveIds = const {};

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
    _lastPersisted = persisted;
    _lastPersistedById = persistedById;
    _lastLiveIds = liveIds;
    // Names and previews leave BOTH the boot path and the all-corpus
    // background path. Rows render cached/derived values; only the
    // viewport calls [warmVisible] for real transcript/name probes.
    var jsonlNames = const <String, String>{};
    if (readPersistedNames) jsonlNames = manager.knownSessionNames;
    final infoNames = {...jsonlNames, ...sessionInfoNames};
    final warm = _previewWarmStates[manager] ??= _PreviewWarmState();
    final entries = <ChatListEntry>[];
    for (final session in live) {
      final metadata = persistedById[session.id];
      final preview = _livePreview(session.service);
      // A newly-created own session has no transcript or listing metadata
      // yet. Its in-memory activity stamp would otherwise keep an untitled
      // placeholder at the top of All until the first real message lands.
      if (metadata == null && preview == null) continue;
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
          title: _title(
            session.id,
            createdAt,
            isSubagent,
            infoNames,
            metadata: metadata,
          ),
          createdAt: createdAt,
          lastActivity:
              metadata?.lastUpdatedAt ??
              metadata?.createdAt ??
              session.lastUpdatedAt,
          preview: preview,
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
      final cached = warm.byStamp[_previewStamp(metadata)];
      entries.add(
        ChatListEntry(
          id: ChatEntryId.local(metadata.id),
          kind: ChatListEntryKind.localAgent,
          title: _title(
            metadata.id,
            metadata.createdAt,
            isSubagent,
            infoNames,
            metadata: metadata,
          ),
          createdAt: metadata.createdAt,
          lastActivity: metadata.lastUpdatedAt ?? metadata.createdAt,
          // '' caches "no preview" — both surface as null to the row.
          preview: (cached == null || cached.isEmpty) ? null : cached,
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

  /// Warms decorations for rows that actually reached the viewport.
  /// Repeated builds are served by the managers' positive/negative caches;
  /// live sessions already have an in-memory preview and are not re-read.
  Future<void> warmVisible(Iterable<String> sessionIds) async {
    final selected = <SessionMetadata>[
      for (final id in sessionIds) ?_lastPersistedById[id],
    ];
    if (selected.isEmpty) return;
    final warm = _previewWarmStates[manager] ??= _PreviewWarmState();
    final previewMisses = <SessionMetadata>[
      for (final metadata in selected)
        if (!_lastLiveIds.contains(metadata.id) &&
            warm.byStamp[_previewStamp(metadata)] == null)
          metadata,
    ];
    await Future.wait([
      manager.warmSessionNames(selected),
      if (previewMisses.isNotEmpty) _warmPreviews(warm, previewMisses),
      manager.warmSubagentParents(selected, allSessions: _lastPersisted),
    ]);
  }

  /// The cache key for one persisted session: id + file stamp, so a grown
  /// or rewritten transcript re-reads exactly once.
  static String _previewStamp(SessionMetadata metadata) =>
      '${metadata.id}:${metadata.sizeBytes ?? -1}:'
      '${metadata.lastUpdatedAt?.millisecondsSinceEpoch ?? 0}';

  /// The bounded background preview fill (4 at a time, mirroring the
  /// manager's name fill): caches every landed read under its file stamp
  /// and notifies ONCE at completion so the rows repaint through
  /// [changes]. A newer fill supersedes an older one's remaining probes.
  Future<void> _warmPreviews(
    _PreviewWarmState warm,
    List<SessionMetadata> pending,
  ) async {
    final generation = ++warm.generation;
    final stopwatch = Stopwatch()..start();
    var filled = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < pending.length && generation == warm.generation) {
        final metadata = pending[next++];
        try {
          final preview = await previewReader.read(metadata);
          if (generation != warm.generation) return;
          warm.byStamp[_previewStamp(metadata)] = preview ?? '';
          if (preview != null && preview.isNotEmpty) filled++;
        } on Object {
          // Broken or unreadable transcript: cache the miss, never break
          // the fill.
          warm.byStamp[_previewStamp(metadata)] = '';
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < 4 && i < pending.length; i++) worker(),
    ]);
    if (generation != warm.generation) return;
    AppLog.i(
      'chats',
      'local previews: $filled/${pending.length} filled in '
          '${stopwatch.elapsedMilliseconds}ms',
    );
    manager.notifySessionListeners();
  }

  String _title(
    String id,
    DateTime createdAt,
    bool isSubagent,
    Map<String, String> infoNames, {
    SessionMetadata? metadata,
  }) {
    final persistedName = namesStore?.titleFor(id) ?? infoNames[id];
    if (persistedName != null && persistedName.trim().isNotEmpty) {
      return persistedName;
    }
    if (isSubagent && metadata != null) {
      // The terminal/task identity is the human name for a delegated agent.
      // Never replace it with the transcript UUID when no session_info name
      // exists yet (the JSONL name fill is intentionally asynchronous).
      for (final key in const ['id', 'name', 'displayName']) {
        final value = metadata.metadata?[key];
        final candidate = value is String ? value.trim() : null;
        if (candidate != null &&
            candidate.isNotEmpty &&
            candidate != id &&
            !_uuidPattern.hasMatch(candidate)) {
          return candidate;
        }
      }
    }
    final derived = titleBuilder(id, createdAt, isSubagent).trim();
    if (derived.isNotEmpty) return derived;
    return isSubagent && id.length > 8 ? id.substring(0, 8) : id;
  }

  static final RegExp _uuidPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

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
      if (text.isEmpty || isFaSystemNoticeContent(text)) continue;
      return text;
    }
    return null;
  }
}

/// Reads one persisted session's transcript tail preview. The seam behind
/// [LocalChatPreviewReader] so tests can gate/count reads.
abstract interface class LocalChatPreviewSource {
  Future<String?> read(SessionMetadata metadata);
}

/// Reads only the persisted transcript tail when the filesystem supports
/// ranges. A truncated/encrypted/unknown record produces no preview, never a
/// synthetic "last message".
final class LocalChatPreviewReader implements LocalChatPreviewSource {
  LocalChatPreviewReader(this.env, {this.tailBytes = 128 * 1024});

  final ExecutionEnv env;
  final int tailBytes;

  @override
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
          // System notices are agent bookkeeping, not the conversation's
          // last human-readable reply. Keep walking the persisted tail.
          if (preview.isNotEmpty && !isFaSystemNoticeContent(preview)) {
            return preview;
          }
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
