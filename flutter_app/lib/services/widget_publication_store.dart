// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The UI-facing projection of [WidgetPublication.lastKnownState]: `open`
/// under catalog review, `published` (PR merged), `rejected` (closed
/// unmerged), `unknown` (never refreshed / PR gone). Issue #1045 adds the
/// publish-lifecycle states: `publishing` (optimistic, in-flight attempt),
/// `validating` (PR open, catalog CI running), `invalid` (a validator
/// check failed — [WidgetPublication.validatorErrors] carries the verbatim
/// error lines) and `failed` (the attempt itself failed —
/// [WidgetPublication.lastError] carries why).
enum WidgetPublicationState {
  unknown,
  open,
  published,
  rejected,
  publishing,
  validating,
  invalid,
  failed,
}

/// Maps a persisted `lastKnownState` string onto [WidgetPublicationState].
WidgetPublicationState widgetPublicationStateOf(String raw) => switch (raw) {
  WidgetPublication.stateOpen => WidgetPublicationState.open,
  WidgetPublication.stateMerged => WidgetPublicationState.published,
  WidgetPublication.stateClosed => WidgetPublicationState.rejected,
  WidgetPublication.statePublishing => WidgetPublicationState.publishing,
  WidgetPublication.stateValidating => WidgetPublicationState.validating,
  WidgetPublication.stateInvalid => WidgetPublicationState.invalid,
  WidgetPublication.stateFailed => WidgetPublicationState.failed,
  _ => WidgetPublicationState.unknown,
};

/// One reviewer comment of a publication's catalog PR, snapshotted by
/// status polling (plain text only — rendered as text in the UI, never as
/// markdown: reviewer input is display-only data).
final class WidgetPublicationComment {
  const WidgetPublicationComment({
    required this.author,
    required this.body,
    required this.createdAt,
    required this.isReview,
  });

  factory WidgetPublicationComment.fromJson(Map<String, dynamic> json) {
    return WidgetPublicationComment(
      author: (json['author'] ?? '').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt:
          DateTime.tryParse((json['createdAt'] ?? '').toString())?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      isReview: json['isReview'] == true,
    );
  }

  final String author;
  final String body;
  final DateTime createdAt;

  /// True for line-level review comments, false for conversation comments.
  final bool isReview;

  @override
  bool operator ==(Object other) =>
      other is WidgetPublicationComment &&
      other.author == author &&
      other.body == body &&
      other.createdAt == createdAt &&
      other.isReview == isReview;

  @override
  int get hashCode => Object.hash(author, body, createdAt, isReview);

  Map<String, Object?> toJson() => {
    'author': author,
    'body': body,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'isReview': isReview,
  };
}

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
    this.comments = const [],
    this.validatorErrors = const [],
    this.runHtmlUrl,
    this.lastError,
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
      comments: [
        for (final raw in (json['comments'] as List<dynamic>? ?? const []))
          if (raw is Map<String, dynamic>)
            WidgetPublicationComment.fromJson(raw),
      ],
      validatorErrors: [
        for (final raw in (json['validatorErrors'] as List<dynamic>? ?? const []))
          raw.toString(),
      ],
      runHtmlUrl: json['runHtmlUrl']?.toString(),
      lastError: json['lastError']?.toString(),
    );
  }

  /// Publish steps (E7 resume markers). [stepPublishing] marks the
  /// optimistic in-flight attempt recorded before any network work (the
  /// fire-and-forget UI of issue #1045).
  static const stepPublishing = 'publishing';
  static const stepRepoPushed = 'repo_pushed';
  static const stepPrOpened = 'pr_opened';

  /// Last-known PR states. [statePublishing]/[stateValidating]/
  /// [stateInvalid]/[stateFailed] are the issue-#1045 lifecycle states —
  /// every attempt that has not reached "published" stays visible (I4).
  static const statePublishing = 'publishing';
  static const stateValidating = 'validating';
  static const stateInvalid = 'invalid';
  static const stateFailed = 'failed';
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

  /// The commit sha of [repoFullName] the overlay `source.commit` pins.
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

  /// The reviewer comments at the last refresh (oldest first, newest last,
  /// capped by the poller). Empty until the first refresh.
  final List<WidgetPublicationComment> comments;

  /// The catalog validator's error lines, VERBATIM from the failing CI run
  /// (issue #1045 — the 2048 case: `ERROR 2048: external manifest:
  /// 'minRuntime' must be a non-empty string`). Non-empty only in the
  /// [stateInvalid] state; never aggregated or reworded.
  final List<String> validatorErrors;

  /// Browser URL of the failing CI run (the "run link" next to the
  /// verbatim errors).
  final String? runHtmlUrl;

  /// Why the last publish attempt failed, verbatim from the thrown error —
  /// set in the [stateFailed] state so a background failure that outlived
  /// the publish sheet stays inspectable (I4).
  final String? lastError;

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
    List<WidgetPublicationComment>? comments,
    List<String>? validatorErrors,
    Object? runHtmlUrl = _unset,
    Object? lastError = _unset,
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
      comments: comments ?? this.comments,
      validatorErrors: validatorErrors ?? this.validatorErrors,
      runHtmlUrl: identical(runHtmlUrl, _unset)
          ? this.runHtmlUrl
          : runHtmlUrl as String?,
      lastError: identical(lastError, _unset)
          ? this.lastError
          : lastError as String?,
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
    if (comments.isNotEmpty) 'comments': [for (final c in comments) c.toJson()],
    if (validatorErrors.isNotEmpty)
      'validatorErrors': validatorErrors,
    if (runHtmlUrl != null) 'runHtmlUrl': runHtmlUrl,
    if (lastError != null) 'lastError': lastError,
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
