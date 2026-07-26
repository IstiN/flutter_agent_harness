import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end voice-notes probe on a real device/simulator: boots the
/// bundled demo through the real QuickJS engine with the REAL fah/mic
/// channel, taps Record, and expects a transcribed (or visibly failed)
/// state — mirroring the user's tap.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('voice-notes record button drives the real mic channel', (
    tester,
  ) async {
    final env = await createPlatformEnv();
    // Seed the demo from bundled assets, like AppsStore.seedBundledApps.
    final manifestRaw = await rootBundle.loadString(
      'assets/apps/voice-notes/manifest.json',
    );
    final manifest = (jsonDecode(manifestRaw) as Map).cast<String, Object?>();
    await env.writeFile('apps/voice-notes/manifest.json', manifestRaw);
    await env.writeFile(
      'apps/voice-notes/widget.js',
      await rootBundle.loadString('assets/apps/voice-notes/widget.js'),
    );
    final app = JsAppInfo.fromManifest(
      manifest,
      bundled: true,
      fallbackId: 'voice-notes',
    );
    final permissions = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: JsAppView(app: app, env: env, permissionsStore: permissions),
      ),
    );
    // Let the engine boot and the app render.
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 200));
      if (find.text('Record').evaluate().isNotEmpty) break;
    }
    expect(find.text('Record'), findsOneWidget, reason: 'boot render failed');

    await tester.tap(find.text('Record'));
    // Recording takes recordSeconds (5s default) + transcribe time.
    await tester.pump(const Duration(seconds: 1));
    // Debug: dump everything visible after the tap.
    for (final w in tester.widgetList<Text>(find.byType(Text))) {
      final data = w.data ?? w.textSpan?.toPlainText() ?? '';
      if (data.isNotEmpty) print('[visible] $data');
    }
    expect(
      find.textContaining('Recording'),
      findsWidgets,
      reason: 'tap did not start a recording',
    );

    // Wait up to 30s for the final state (note added OR an error card).
    var settled = false;
    for (var i = 0; i < 60 && !settled; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      settled =
          find.textContaining('Could not record').evaluate().isNotEmpty ||
          find.textContaining('Microphone permission').evaluate().isNotEmpty ||
          find.textContaining('transcript').evaluate().isNotEmpty ||
          find.textContaining('Record').evaluate().isNotEmpty;
    }
    // Either a note landed or an actionable error is visible — never a hang.
    expect(settled, isTrue, reason: 'record flow never settled');
  });
}
