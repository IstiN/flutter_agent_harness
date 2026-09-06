// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The UI-facing projection of [WidgetPublication.lastKnownState]: `open`
/// under catalog review, `published` (PR merged), `rejected` (closed
/// unmerged), `unknown` (never refreshed / PR gone).
enum WidgetPublicationState { unknown, open, published, rejected }

/// Maps a persisted `lastKnownState` string onto [WidgetPublicationState].
WidgetPublicationState widgetPublicationStateOf(String raw) => switch (raw) {
  WidgetPublication.stateOpen => WidgetPublicationState.open,
  WidgetPublication.stateMerged => WidgetPublicationState.published,
  WidgetPublication.stateClosed => WidgetPublicationState.rejected,
  _ => WidgetPublicationState.unknown,
};

/// One widget-publishing submission recorded in the local ledger
/// (card `goal/widget-publishing-github.md`, issue #35).
///
/// The ledger is the kill-resume memory of the publish flow (edge case E7):
/// [step] records how far a publish got, so a re-publish after an app kill
/// continues from the right place instead of duplicating work.
final class WidgetPublication {
  const WidgetPublication({
    required this.widgetId,
    required this.version,
    required this.repoFullName,
    required this.repoCommit,
    required this.step,
    required this.submittedAt,
    this.prNumber,
    this.prHtmlUrl,
    this.lastKnownState = stateOpen,
  });

  factory WidgetPublication.fromJson(Map<String, dynamic> json) {
    return WidgetPublication(
      widgetId: (json['widgetId'] ?? '').toString(),
      version: (json['version'] ?? '').toString(),
      repoFullName: (json['repoFullName'] ?? '').toString(),
      repoCommit: (json['repoCommit'] ?? '').toString(),
      step: (json['step'] ?? stepRepoPushed).toString(),
      submittedAt:
          DateTime.tryParse((json['submittedAt'] ?? '').toString())?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      prNumber: (json['prNumber'] as num?)?.toInt(),
      prHtmlUrl: json['prHtmlUrl']?.toString(),
      lastKnownState: (json['lastKnownState'] ?? stateOpen).toString(),
    );
  }

  /// Publish steps (E7 resume markers).
  static const stepRepoPushed = 'repo_pushed';
  static const stepPrOpened = 'pr_opened';

  /// Last-known PR states.
  static const stateOpen = 'open';
  static const stateMerged = 'merged';
  static const stateClosed = 'closed';
  static const stateUnknown = 'unknown';

  /// The widget id (folder name under `apps/`).
  final String widgetId;

  /// The published semver version.
  final String version;

  /// The user's widget repository as `<owner>/<name>`.
  final String repoFullName;

  /// The commit sha of [repoFullName] the catalog gitlink pins.
  final String repoCommit;

  /// The catalog pull request number, once [step] is [stepPrOpened].
  final int? prNumber;

  /// Browser URL of the pull request, for deep links.
  final String? prHtmlUrl;

  /// How far the publish got: [stepRepoPushed] or [stepPrOpened].
  final String step;

  /// When the submission was recorded (UTC).
  final DateTime submittedAt;

  /// The last PR state seen by status polling
  /// ([stateOpen] / [stateMerged] / [stateClosed] / [stateUnknown]).
  final String lastKnownState;

  /// The UI-facing state projection of [lastKnownState].
  WidgetPublicationState get state => widgetPublicationStateOf(lastKnownState);

  /// Browser URL of the pull request, or the empty string before the PR is
  /// opened (convenience for UI deep links).
  String get prUrl => prHtmlUrl ?? '';

  static const _unset = Object();

  WidgetPublication copyWith({
    String? version,
    String? repoFullName,
    String? repoCommit,
    String? step,
    DateTime? submittedAt,
    Object? prNumber = _unset,
    Object? prHtmlUrl = _unset,
    String? lastKnownState,
  }) {
    return WidgetPublication(
      widgetId: widgetId,
      version: version ?? this.version,
      repoFullName: repoFullName ?? this.repoFullName,
      repoCommit: repoCommit ?? this.repoCommit,
      step: step ?? this.step,
      submittedAt: submittedAt ?? this.submittedAt,
      prNumber: identical(prNumber, _unset) ? this.prNumber : prNumber as int?,
      prHtmlUrl: identical(prHtmlUrl, _unset)
          ? this.prHtmlUrl
          : prHtmlUrl as String?,
      lastKnownState: lastKnownState ?? this.lastKnownState,
    );
  }

  Map<String, Object?> toJson() => {
    'widgetId': widgetId,
    'version': version,
    'repoFullName': repoFullName,
    'repoCommit': repoCommit,
    'step': step,
    'submittedAt': submittedAt.toUtc().toIso8601String(),
    if (prNumber != null) 'prNumber': prNumber,
    if (prHtmlUrl != null) 'prHtmlUrl': prHtmlUrl,
    'lastKnownState': lastKnownState,
  };

  @override
  String toString() =>
      'WidgetPublication($widgetId $version, $step, pr #$prNumber, '
      '$lastKnownState)';
}

/// The submissions ledger: every publish attempt of every widget, persisted
/// as `widget_publications.json` at the env root.
///
/// One entry per widget id — re-publishing upserts (replaces) the previous
/// record. Persistence is immediate on every [record]; the file is plain
/// JSON so a corrupt or missing file simply reads as an empty ledger.
class WidgetPublicationStore extends ChangeNotifier {
  WidgetPublicationStore(this._env);

  /// An env-less store: keeps the ledger in memory only (no persistence).
  /// Used by the shared-holder fallback below and by widget tests.
  WidgetPublicationStore.inMemory() : _env = null;

  /// Ledger file at the env cwd root.
  static const fileName = 'widget_publications.json';

  /// On-disk schema version.
  static const schemaVersion = 1;

  final ExecutionEnv? _env;
  final List<WidgetPublication> _items = [];

  /// Loads the ledger from [env]; a missing or corrupt file yields an empty
  /// store (never throws).
  static Future<WidgetPublicationStore> load(ExecutionEnv env) async {
    final store = WidgetPublicationStore(env);
    final text = (await env.readTextFile(fileName)).valueOrNull;
    if (text == null) return store;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) return store;
      final items = decoded['items'];
      if (items is! List) return store;
      for (final raw in items) {
        if (raw is! Map) continue;
        try {
          store._items.add(
            WidgetPublication.fromJson(Map<String, dynamic>.from(raw)),
          );
        } on Object {
          // A single malformed entry must not sink the whole ledger.
        }
      }
    } on FormatException {
      // Corrupt file → empty ledger.
    }
    return store;
  }

  /// All publications, newest submission first.
  List<WidgetPublication> get publications {
    final sorted = [..._items]
      ..sort((a, b) => b.submittedAt.compareTo(a.submittedAt));
    return List.unmodifiable(sorted);
  }

  /// The publication for [id], or null when the widget was never published.
  WidgetPublication? byWidgetId(String id) {
    for (final item in _items) {
      if (item.widgetId == id) return item;
    }
    return null;
  }

  /// Upserts [publication] by widget id (a re-publish REPLACES the previous
  /// record), persists the ledger immediately, and notifies listeners.
  Future<WidgetPublication> record(WidgetPublication publication) async {
    _items.removeWhere((item) => item.widgetId == publication.widgetId);
    _items.add(publication);
    await _persist();
    notifyListeners();
    return publication;
  }

  Future<void> _persist() async {
    final env = _env;
    if (env == null) return; // In-memory store: nothing to persist.
    final payload = jsonEncode({
      'version': schemaVersion,
      'items': [for (final item in _items) item.toJson()],
    });
    // FileSystem results encode failures instead of throwing; a failed
    // write leaves the in-memory ledger authoritative for this session.
    await env.writeFile(fileName, payload);
  }
}

/// The app-wide shared ledger instance. No DI scope exists for it yet
/// (same situation as [sharedGithubAccountStore]), so the settings
/// section, the launcher tile menu and the apps panel all share this one
/// instance — a widget published from a tile menu shows up in "My
/// publications" immediately.
WidgetPublicationStore? _sharedPublications;

/// Loads the shared ledger from [env] (persisting across restarts) unless
/// it was already initialized. The launcher/apps-panel call this at startup
/// — they own the app env; the settings section falls back to whatever the
/// holder holds (or an in-memory store in tests).
Future<WidgetPublicationStore> initSharedWidgetPublicationStore(
  ExecutionEnv env,
) async => _sharedPublications ??= await WidgetPublicationStore.load(env);

/// The shared ledger, initialized or in-memory.
WidgetPublicationStore sharedWidgetPublicationStore() =>
    _sharedPublications ??= WidgetPublicationStore.inMemory();
