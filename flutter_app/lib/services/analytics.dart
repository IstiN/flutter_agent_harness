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

  /// Widget-catalog lifecycle event (`name` without the `widget_` prefix —
  /// added here so call sites stay grep-able and names stay consistent).
  void widgetEvent(String name, {Map<String, Object> params = const {}}) =>
      _log('widget_$name', params);

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

  /// A screen became visible. Named 'screen_opened' (not the reserved
  /// 'screen_view') because the facade is logEvent-based; the param carries
  /// the stable screen id — this is the user-path backbone.
  void screenOpened(String screen) =>
      _log('screen_opened', {'screen_name': screen});

  /// The session chat sheet changed state (collapsed/mini/expanded).
  void chatSheetState(String state) =>
      _log('chat_sheet_state', {'state': state});

  /// A JS app was opened from the launcher or the open_app tool. Demo flag
  /// only — user-given app ids could carry personal naming.
  void jsAppOpened({required bool isDemo, required String source}) =>
      _log('js_app_opened', {'is_demo': isDemo, 'source': source});

  /// A JS app was reloaded from its chrome menu.
  void jsAppReloaded() => _log('js_app_reloaded');

  /// A launcher folder was opened / created / dissolved.
  void launcherFolder(String action) =>
      _log('launcher_folder', {'action': action});

  /// A launcher tile was resized (WxH label like "2x2").
  void launcherTileResized(String size) =>
      _log('launcher_tile_resized', {'size': size});

  /// The launcher grid column count changed in settings.
  void launcherGridColumns(int columns) =>
      _log('launcher_grid_columns', {'columns': columns});

  /// The theme mode changed (system/light/dark).
  void themeChanged(String mode) => _log('theme_changed', {'mode': mode});

  /// The tool-approval mode changed (always-ask/write/yolo).
  void approvalModeChanged(String mode) =>
      _log('approval_mode_changed', {'mode': mode});

  /// The third-party skills access consent changed (ask/granted/denied).
  void skillsAccessChanged(String access) =>
      _log('skills_access_changed', {'access': access});

  /// A DAP hub settings interaction (open/probe/edit/save).
  void dapHubAction(String action) =>
      _log('dap_hub_action', {'action': action});

  /// A model preset was applied from the presets section.
  void modelPresetApplied(String presetId) =>
      _log('model_preset_applied', {'preset_id': presetId});

  /// A media model slot was (re)assigned in settings.
  void mediaSlotSet(String slot) => _log('media_slot_set', {'slot': slot});

  /// A media generation tool produced a file (image/speak/music/video).
  void mediaGenerated(String kind) => _log('media_generated', {'kind': kind});

  /// The mic voice input was used from the composer.
  void voiceInputUsed() => _log('voice_input_used');

  /// A secret-request prompt was answered (granted/declined — never the
  /// value, never a user-given name).
  void secretRequest(String outcome) =>
      _log('secret_request', {'outcome': outcome});

  /// The files browser was opened (from the launcher or chat).
  void filesOpened(String source) => _log('files_opened', {'source': source});

  static String _bucket(int value, List<int> edges) {
    for (final edge in edges) {
      if (value <= edge) return '<=$edge';
    }
    return '>${edges.last}';
  }
}
