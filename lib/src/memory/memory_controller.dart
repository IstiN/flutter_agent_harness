/// Session-scoped facade over the `flutter_agent_memory` package.
///
/// Owns two [KbStorage]+[KBSearchEngine] pairs (project + user scope),
/// created lazily from an [ExecutionEnv]. Exposes `add`/`search`/`list` for
/// the memory tools and `formatPromptSection` for the system prompt.
library;

import 'dart:async';

import 'package:flutter_agent_memory/flutter_agent_memory.dart';

import '../env/execution_env.dart';
import 'execution_env_kb_storage.dart';

/// Formats the `/memory` stats block (pure, testable): counts per type,
/// last maintenance, and the due hint.
List<String> formatMemoryStatsLines(
  List<MemoryEntry> entries,
  DateTime? lastMaintenance,
  bool maintenanceDue,
) {
  final byType = <String, int>{};
  for (final entry in entries) {
    byType[entry.type] = (byType[entry.type] ?? 0) + 1;
  }
  final lines = <String>['[Memory]', '  entries: ${entries.length}'];
  for (final type in byType.keys.toList()..sort()) {
    lines.add('  $type: ${byType[type]}');
  }
  lines.add(
    lastMaintenance == null
        ? '  last maintenance: never (/memory maintain to run)'
        : '  last maintenance: $lastMaintenance',
  );
  if (maintenanceDue) {
    lines.add('  maintenance due — /memory maintain');
  }
  return lines;
}

/// A single memory entry returned by [MemoryController.search] / [list].
final class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.type,
    required this.text,
    this.tags = const [],
    this.importance = 0.5,
    this.scope = 'project',
  });

  final String id;
  final String type;
  final String text;
  final List<String> tags;
  final double importance;
  final String scope;

  String get displayLine {
    final tagStr = tags.isNotEmpty ? ' [${tags.join(',')}]' : '';
    return '($type) $text$tagStr';
  }
}

/// Controls the agent's durable memory across sessions and projects.
final class MemoryController {
  MemoryController({
    required ExecutionEnv env,
    String? projectRoot,
    String? userRoot,
    LlmProvider? llmProvider,
  }) : _env = env,
       _projectRoot = projectRoot ?? env.cwd,
       _userRoot = userRoot,
       _llmProvider = llmProvider;

  final ExecutionEnv _env;
  final String _projectRoot;
  final String? _userRoot;
  final LlmProvider? _llmProvider;

  KbStorage? _projectStorage;
  KbStorage? _userStorage;
  KBMemoryStore? _projectStore;
  KBMemoryStore? _userStore;
  KBSearchEngine? _projectSearch;
  KBSearchEngine? _userSearch;

  /// Lazily initializes the project-scope store + search engine.
  Future<KBMemoryStore> get projectStore async {
    if (_projectStore != null) return _projectStore!;
    _projectStorage = ExecutionEnvKbStorage(_env, '$_projectRoot/.fah/memory');
    await _projectStorage!.initialize();
    _projectStore = KBMemoryStore(_projectStorage!, provider: _llmProvider);
    _projectSearch = KBSearchEngine(_projectStorage!, provider: _llmProvider);
    return _projectStore!;
  }

  /// Lazily initializes the user-scope store + search engine.
  Future<KBMemoryStore?> get userStore async {
    if (_userRoot == null) return null;
    if (_userStore != null) return _userStore;
    _userStorage = ExecutionEnvKbStorage(_env, '$_userRoot/.fah/memory');
    await _userStorage!.initialize();
    _userStore = KBMemoryStore(_userStorage!, provider: _llmProvider);
    _userSearch = KBSearchEngine(_userStorage!, provider: _llmProvider);
    return _userStore!;
  }

  /// Adds a memory entry (project scope by default).
  Future<MemoryEntry> add({
    required String text,
    String type = 'note',
    List<String> tags = const [],
    double importance = 0.5,
    String scope = 'project',
  }) async {
    final store = scope == 'user' ? await userStore : await projectStore;
    if (store == null) {
      return MemoryEntry(
        id: 'no-store',
        type: type,
        text: text,
        tags: tags,
        importance: importance,
        scope: scope,
      );
    }
    final record = await store.addNote(
      text: text,
      tags: tags,
      area: scope,
      importance: importance,
      author: 'agent',
    );
    return MemoryEntry(
      id: record.id,
      type: type,
      text: text,
      tags: tags,
      importance: importance,
      scope: scope,
    );
  }

  /// Searches both scopes (project first, then user).
  Future<List<MemoryEntry>> search(String query, {int limit = 10}) async {
    final results = <MemoryEntry>[];
    await projectStore; // ensure initialized
    await _searchScope(_projectSearch, query, limit, 'project', results);
    await userStore;
    if (results.length < limit) {
      await _searchScope(
        _userSearch,
        query,
        limit - results.length,
        'user',
        results,
      );
    }
    return results;
  }

  /// Searches one scope and appends matching results to [results].
  Future<void> _searchScope(
    KBSearchEngine? engine,
    String query,
    int limit,
    String scope,
    List<MemoryEntry> results,
  ) async {
    if (engine == null) return;
    try {
      final found = await engine.searchByText(query);
      results.addAll(
        found.results.take(limit).map((r) => _fromSearchResult(r, scope)),
      );
    } on StateError {
      // No LLM provider — fall back to keyword-only search.
      final found = await engine.searchByKeywords(query);
      results.addAll(found.take(limit).map((r) => _fromSearchResult(r, scope)));
    }
  }

  /// Lists recent entries from both scopes (project first, then user).
  Future<List<MemoryEntry>> list({int limit = 20}) async {
    final results = <MemoryEntry>[];
    await projectStore;
    await _listScope(_projectStorage, 'project', limit, results);
    if (results.length < limit) {
      await userStore;
      await _listScope(_userStorage, 'user', limit - results.length, results);
    }
    return results;
  }

  /// Appends up to [limit] note entries of one scope's storage.
  Future<void> _listScope(
    KbStorage? storage,
    String scope,
    int limit,
    List<MemoryEntry> results,
  ) async {
    if (storage == null) return;
    final noteIds = await storage.listEntityIds('note');
    for (final id in noteIds.take(limit)) {
      if (results.length >= limit) break;
      final entry = await _readNoteEntry(storage, id, scope);
      if (entry != null) results.add(entry);
    }
  }

  /// Reads one entity as a [MemoryEntry], or null if the entity is absent.
  /// The raw file is frontmatter + body markdown — parse it properly
  /// (the naive first line is the `---` delimiter, not the fact).
  Future<MemoryEntry?> _readNoteEntry(
    KbStorage? storage,
    String id,
    String scope,
  ) async {
    final raw = await storage?.readEntity('note', id);
    if (raw == null) return null;
    String text;
    try {
      text = KBFileParser().parseNote(raw).text;
    } on Object {
      text = _firstLine(raw);
    }
    return MemoryEntry(id: id, type: 'note', text: text, scope: scope);
  }

  /// Formats a ≤2 KiB `<memory>` block for the system prompt.
  Future<String> formatPromptSection() async {
    final entries = await list(limit: 15);
    if (entries.isEmpty) return '';
    final lines = <String>[
      '<memory>',
      'Durable facts from past sessions (memory_search finds more):',
    ];
    for (final entry in entries) {
      final line = '  ${entry.displayLine}';
      if (lines.join('\n').length + line.length + 10 > 2000) break;
      lines.add(line);
    }
    lines.add('</memory>');
    return lines.join('\n');
  }

  /// Phase 2: runs `maintainMemoryLevels()` + `consolidate()` on both
  /// scopes sequentially (smol-role cost class). Guarded: a second call
  /// while one runs is a no-op returning `false`. Consolidation needs an
  /// LLM provider — without one only level maintenance runs.
  Future<bool> maintain() async {
    if (_maintaining) return false;
    _maintaining = true;
    try {
      for (final store in [await projectStore, await userStore]) {
        if (store == null) continue;
        await store.maintainMemoryLevels();
        if (_llmProvider != null) {
          try {
            await store.consolidate();
          } on Object {
            // Consolidation is best-effort: stale summary, LLM hiccup, or
            // a concurrent write all skip this cycle (phase 2 spec).
          }
        }
      }
      await _writeMaintenanceStamp();
      return true;
    } finally {
      _maintaining = false;
    }
  }

  bool _maintaining = false;

  /// True while a [maintain] run is in flight (the phase 2 running guard).
  bool get isMaintaining => _maintaining;

  /// Reads the last-maintenance timestamp (null when never maintained).
  Future<DateTime?> lastMaintenanceAt() async {
    final info = await _env.fileInfo(_maintenanceStampPath);
    final mtimeMs = info.valueOrNull?.mtimeMs;
    if (mtimeMs == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(mtimeMs);
  }

  /// True when maintenance is due: never run, or > [maxMaintenanceAge] old.
  Future<bool> maintenanceDue() async {
    final last = await lastMaintenanceAt();
    if (last == null) return true;
    return DateTime.now().difference(last) > maxMaintenanceAge;
  }

  String get _maintenanceStampPath =>
      '$_projectRoot/.fah/memory/.last_maintenance';

  /// Maintenance cadence: due when the last run is older than 24 h.
  static const maxMaintenanceAge = Duration(hours: 24);

  Future<void> _writeMaintenanceStamp() async {
    await _env.writeFile(_maintenanceStampPath, '');
  }

  /// Counters backing the add-trigger (phase 2): after
  /// [addsBeforeMaintenance] `memory_add` calls the next idle moment runs
  /// [maintain] (debounced by the host).
  int _addsSinceMaintenance = 0;
  static const addsBeforeMaintenance = 20;

  /// Records an `add` toward the maintenance counter. Returns true when the
  /// threshold was just crossed (host should schedule maintenance).
  bool noteAddForMaintenance() =>
      ++_addsSinceMaintenance >= addsBeforeMaintenance;

  MemoryEntry _fromSearchResult(KBSearchResult r, String scope) {
    final note = r.note;
    return MemoryEntry(
      id: note?.id ?? r.path,
      type: note != null ? 'note' : 'entity',
      text: note?.text ?? r.path,
      tags: note?.tags ?? const [],
      importance: note?.importance ?? 0.5,
      scope: scope,
    );
  }

  String _firstLine(String text) {
    final idx = text.indexOf('\n');
    return idx < 0 ? text : text.substring(0, idx);
  }
}
