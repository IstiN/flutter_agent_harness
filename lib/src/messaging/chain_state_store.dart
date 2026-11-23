/// Persistence for the chain guard (issue #2226): the budget spend and
/// per-counterparty window state survive a restart, so relaunching
/// mid-chain never grants a fresh budget (the `state.json` sidecar under
/// the messages root's `_chain/` directory). Best-effort by contract — a
/// failing load or save degrades to in-memory accounting and never breaks
/// waking.
library;

import 'dart:convert';

import '../env/execution_env.dart';

/// One counterparty pair-window's persisted state.
final class ChainWindowState {
  const ChainWindowState({
    required this.stuckRounds,
    required this.prevMasked,
    required this.prevStateTokens,
    required this.lastSimilarity,
  });

  final int stuckRounds;
  final String prevMasked;
  final List<String> prevStateTokens;
  final double lastSimilarity;

  Map<String, Object?> toJson() => {
    'stuckRounds': stuckRounds,
    'prevMasked': prevMasked,
    'prevTokens': prevStateTokens,
    'lastSimilarity': lastSimilarity,
  };

  static ChainWindowState fromJson(Map node) => ChainWindowState(
    stuckRounds: (node['stuckRounds'] as num?)?.toInt() ?? 0,
    prevMasked: node['prevMasked'] as String? ?? '',
    prevStateTokens: [
      for (final token in node['prevTokens'] as List? ?? const []) '$token',
    ],
    lastSimilarity: (node['lastSimilarity'] as num?)?.toDouble() ?? 0,
  );
}

/// The guard's persisted snapshot.
final class ChainSnapshot {
  const ChainSnapshot({required this.tokensSpent, required this.windows});

  final int tokensSpent;
  final Map<String, ChainWindowState> windows;

  Map<String, Object?> toJson() => {
    'tokensSpent': tokensSpent,
    'windows': {
      for (final MapEntry(key: sender, value: state) in windows.entries)
        sender: state.toJson(),
    },
  };

  static ChainSnapshot fromJson(Map node) => ChainSnapshot(
    tokensSpent: (node['tokensSpent'] as num?)?.toInt() ?? 0,
    windows: {
      for (final MapEntry(key: sender, value: state)
          in (node['windows'] as Map? ?? {}).entries)
        if (state is Map) '$sender': ChainWindowState.fromJson(state),
    },
  );
}

/// Loads and saves [ChainSnapshot]s over the env filesystem.
// ignore_for_file: prefer_initializing_formals
final class ChainStateStore {
  ChainStateStore({
    required ExecutionEnv env,
    required String Function() path,
    this.onError,
  }) : _env = env,
       _path = path;

  final ExecutionEnv _env;
  final String Function() _path;

  /// Host-visible notice when persistence fails (same channel as the
  /// receipt trail's [onError]).
  final void Function(String text)? onError;

  /// Reads the persisted snapshot; null when absent or unreadable.
  Future<ChainSnapshot?> load() async {
    try {
      if (!await _exists(_path())) return null;
      final result = await _env.readTextFile(_path());
      final error = result.errorOrNull;
      if (error != null) {
        onError?.call('chain state read failed: $error');
        return null;
      }
      final text = result.valueOrNull;
      if (text == null || text.trim().isEmpty) return null;
      return ChainSnapshot.fromJson(jsonDecode(text) as Map);
    } on Object catch (e) {
      onError?.call('chain state read failed: $e');
      return null;
    }
  }

  /// Persists [snapshot]; never throws.
  Future<void> save(ChainSnapshot snapshot) async {
    try {
      final result = await _env.writeFile(
        _path(),
        jsonEncode(snapshot.toJson()),
      );
      final error = result.errorOrNull;
      if (error != null) onError?.call('chain state write failed: $error');
    } on Object catch (e) {
      onError?.call('chain state write failed: $e');
    }
  }

  Future<bool> _exists(String path) async {
    final result = await _env.exists(path);
    return result.valueOrNull ?? false;
  }
}
