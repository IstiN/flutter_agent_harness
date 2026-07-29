// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:firebase_analytics/firebase_analytics.dart';

/// Thin analytics facade for the app: named events with a strict privacy
/// rule — NEVER log API keys, message content, file contents, or paths
/// beyond provider/model identifiers and coarse buckets. No-ops when
/// Firebase is unavailable (placeholder options, content blockers, tests).
///
/// Production installs the Firebase-backed instance in `main()`; tests
/// install a recorder via [AppAnalytics.install]. Callers use the global
/// [AppAnalytics.instance] so coverage doesn't need threading through
/// every constructor.
final class AppAnalytics {
  AppAnalytics._(this._sink);

  /// No-op analytics (events are dropped).
  AppAnalytics.noop() : this._(null);

  /// The global instance; replaced by [install] at boot / in tests.
  static AppAnalytics instance = AppAnalytics.noop();

  /// Installs the Firebase-backed instance (null [analytics] → noop).
  static void installFirebase(FirebaseAnalytics? analytics) {
    instance = AppAnalytics._(
      analytics == null
          ? null
          : (name, params) => analytics.logEvent(
              name: name,
              // Firebase accepts only String/num parameter values — a bool
              // crashes logEvent with an assertion in debug builds.
              // Normalize at the boundary; custom sinks (tests) keep the
              // raw typed params.
              parameters: {
                for (final e in params.entries)
                  e.key: e.value is bool
                      ? (e.value as bool)
                            ? 'true'
                            : 'false'
                      : e.value,
              },
            ),
    );
  }

  /// Installs a custom sink (tests record events through it).
  static void install(
    void Function(String name, Map<String, Object> params)? sink,
  ) {
    instance = AppAnalytics._(sink);
  }

  final void Function(String name, Map<String, Object> params)? _sink;

  void _log(String name, [Map<String, Object> params = const {}]) {
    _sink?.call(name, params);
  }

  /// The app finished booting (includes whether analytics itself works).
  void appStart({required bool analyticsAvailable}) =>
      _log('app_start', {'analytics_available': analyticsAvailable});

  /// Boot routing result of [BootstrapScreen].
  void bootstrapResult(String outcome) =>
      _log('bootstrap_result', {'outcome': outcome});

  /// The setup form was displayed (first run or failed restore).
  void setupShown(String reason) => _log('setup_shown', {'reason': reason});

  /// A connection attempt succeeded or failed from setup/settings.
  void connectResult({
    required bool success,
    required String providerKind,
    required bool isCustomProvider,
    required bool isOnDevice,
  }) => _log('connect_result', {
    'success': success,
    'provider_kind': providerKind,
    'is_custom_provider': isCustomProvider,
    'is_on_device': isOnDevice,
  });

  /// A custom provider was added/edited/deleted in the settings form.
  void providerSaved(String action) =>
      _log('provider_saved', {'action': action});

  /// The endpoint model fetch finished (quick select); count is bucketed.
  void modelsFetchResult(int count) => _log('models_fetch_result', {
    'count_bucket': _bucket(count, [0, 1, 10, 50, 200]),
  });

  /// The user picked a suggestion from the model quick select (vs free text).
  void modelPickedFromSuggestions({required bool fromSuggestions}) =>
      _log('model_picked', {'from_suggestions': fromSuggestions});

  /// A chat message was sent. Metadata only: attachment presence and a
  /// coarse length bucket — never the text.
  void messageSent({required bool hasAttachments, required int textLength}) =>
      _log('message_sent', {
        'has_attachments': hasAttachments,
        'length_bucket': _bucket(textLength, [0, 50, 200, 1000]),
      });

  /// A chat session was created/switched/deleted in the sidebar.
  void sessionAction(String action) =>
      _log('session_action', {'action': action});

  /// The settings dialog/screen was opened.
  void settingsOpened() => _log('settings_opened');

  /// A key was saved/deleted in the Keys section (NAME only — names like
  /// OPENROUTER_API_KEY are not secrets; values never logged).
  void keyAction(String action, String keyName) =>
      _log('key_action', {'action': action, 'key_name': keyName});

  /// Files were attached to a message (count only).
  void uploadAdded(int count) => _log('upload_added', {'count': count});

  /// The first-launch onboarding flow was displayed.
  void onboardingStarted() => _log('onboarding_started');

  /// The onboarding flow was finished via its last-page primary button.
  void onboardingCompleted() => _log('onboarding_completed');

  /// The onboarding flow was skipped (the 0-based page it was skipped on —
  /// never any content).
  void onboardingSkipped(int page) =>
      _log('onboarding_skipped', {'page': page});

  static String _bucket(int value, List<int> edges) {
    for (final edge in edges) {
      if (value <= edge) return '<=$edge';
    }
    return '>${edges.last}';
  }
}
