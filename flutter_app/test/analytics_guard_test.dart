// Guardrails that keep the analytics layer wired and visible.
//
// 1. Every screen file (plus the shared composer and the JS-app surfaces)
//    carries at least one `AppAnalytics.instance.` call, or is listed in
//    `_documentedExemptions` with a reason — screens always carry
//    analytics, so user paths stay visible.
// 2. Every public event method on AppAnalytics is referenced at least once
//    in lib/ outside analytics.dart — no dead events accrete in the facade.
//
// Pure Dart (dart:io directory scan, no widget pumping): runs under both
// `dart test` and `flutter test`.

import 'dart:io';

import 'package:test/test.dart';

/// Tracked files that legitimately carry no AppAnalytics call, and why.
const _documentedExemptions = <String, String>{
  'lib/ui/screens/onboarding_mockups.dart':
      'Part file of onboarding_screen.dart (pure mockup widgets); the '
      'onboarding analytics (started/completed/skipped/screenOpened) live '
      'in the main file.',
  'lib/ui/screens/codemie_sso_webview.dart':
      'Fallback-only WebView (the primary iOS SSO path is '
      'ASWebAuthenticationSession in codemie_sso_flow.dart, which carries '
      'the analytics); shown only when the system session cannot start — '
      'no meaningful user path to track.',
  'lib/ui/widgets/chat_composer.dart':
      'Adapter shim — the composer lives in packages/fa_ui; messageSent/'
      'uploadAdded/voiceInputUsed fire via FaChatHost.track, routed into '
      'AppAnalytics by the FaChatHost.analytics hookup in main.dart.',
  'lib/ui/screens/chat_screen.dart':
      'Adapter shim — the screen lives in packages/fa_ui (FaChatScreen); '
      'screenOpened/filesOpened/settingsOpened fire via FaChatHost.track, '
      'routed into AppAnalytics by the FaChatHost.analytics hookup in '
      'main.dart.',
  'lib/ui/screens/media_slot_picker_page.dart':
      'Re-export shim — the page lives in packages/fa_ui; screenOpened is '
      'logged at the app-side push point (MediaModelsSection._editSlot).',
  'lib/ui/screens/provider_editor_page.dart':
      'Re-export shim — the page lives in packages/fa_ui; screenOpened is '
      'logged at the app-side push points (settings, presets, onboarding).',
  'lib/ui/screens/providers_section.dart':
      'Not a screen — the settings sub-section adapter; its host '
      'SettingsScreen logs screenOpened.',
  'lib/ui/screens/tools_availability_section.dart':
      'Not a screen — the settings sub-section for per-tool availability; '
      'its host SettingsScreen logs screenOpened.',
};

/// Every `lib/ui/screens/*.dart` file plus the shared non-screen surfaces.
Iterable<String> _trackedFiles() sync* {
  for (final entity in Directory('lib/ui/screens').listSync()) {
    if (entity is File && entity.path.endsWith('.dart')) {
      yield entity.path.replaceAll('\\', '/');
    }
  }
  yield 'lib/ui/widgets/chat_composer.dart';
  yield 'lib/apps/js_app_view.dart';
  yield 'lib/apps/session_chat_sheet.dart';
}

/// `  void name(` method declarations on AppAnalytics (two-space indent).
final _eventMethodPattern = RegExp(r'^ {2}void ([a-zA-Z]+)\(', multiLine: true);

void main() {
  group('analytics guard', () {
    test('tracked UI files carry analytics or a documented exemption', () {
      final violations = <String>[];
      for (final path in _trackedFiles()) {
        if (_documentedExemptions.containsKey(path)) continue;
        final content = File(path).readAsStringSync();
        if (!content.contains('AppAnalytics.instance.')) {
          violations.add(path);
        }
      }
      expect(
        violations,
        isEmpty,
        reason:
            'UI files without a single AppAnalytics.instance call — wire '
            'screenOpened (initState) plus the file\'s user actions, or add '
            'a _documentedExemptions entry with a reason:\n'
            '${violations.join('\n')}',
      );
      // Exemptions must not rot: each one still points at a real file.
      for (final path in _documentedExemptions.keys) {
        expect(
          File(path).existsSync(),
          isTrue,
          reason: 'stale _documentedExemptions entry: $path',
        );
      }
    });

    test('every AppAnalytics event method is referenced in lib/', () {
      final analytics = File('lib/services/analytics.dart').readAsStringSync();
      final names = <String>{};
      for (final match in _eventMethodPattern.allMatches(analytics)) {
        final name = match.group(1)!;
        // install/installFirebase are sinks, not events; _log is private.
        if (name.startsWith('install')) continue;
        names.add(name);
      }
      expect(names, isNotEmpty, reason: 'no event methods parsed');

      final haystack = StringBuffer();
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.replaceAll('\\', '/') ==
            'lib/services/analytics.dart') {
          continue;
        }
        haystack.writeln(entity.readAsStringSync());
      }
      final dead = [
        for (final name in names)
          if (!haystack.toString().contains('.$name(')) name,
      ]..sort();
      expect(
        dead,
        isEmpty,
        reason:
            'AppAnalytics events never called outside analytics.dart — wire '
            'them at the user action they describe, or remove them from the '
            'facade:\n${dead.join('\n')}',
      );
    });
  });
}
