import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/services/contact_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// End-to-end contacts probe: creates a contact through the real
/// fah/contacts channel, boots the demo, taps Call, and expects the
/// actionable no-handler error (Simulator has no Phone app) to surface in
/// the app UI — proving the button fires and the failure is visible.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('contacts Call button surfaces the no-handler error', (
    tester,
  ) async {
    final contacts = createContactService();
    if (!await contacts.isAvailable) return;
    final granted = await contacts.requestAccess();
    expect(granted, isTrue, reason: 'contacts permission must be granted');
    final id = await contacts.createContact(
      name: 'Probe Person',
      phones: const ['+15551234567'],
    );
    addTearDown(() => contacts.deleteContact(id: id));

    final env = await createPlatformEnv();
    final manifestRaw = await rootBundle.loadString(
      'assets/apps/contacts/manifest.json',
    );
    final manifest = (jsonDecode(manifestRaw) as Map).cast<String, Object?>();
    await env.writeFile('apps/contacts/manifest.json', manifestRaw);
    await env.writeFile(
      'apps/contacts/widget.js',
      await rootBundle.loadString('assets/apps/contacts/widget.js'),
    );
    final app = JsAppInfo.fromManifest(
      manifest,
      bundled: true,
      fallbackId: 'contacts',
    );
    final permissions = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: JsAppView(app: app, env: env, permissionsStore: permissions),
      ),
    );
    // Boot + initial search render.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      if (find.text('Probe Person').evaluate().isNotEmpty) break;
    }
    expect(find.text('Probe Person'), findsOneWidget);

    await tester.tap(find.text('Probe Person'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Call'), findsOneWidget);

    await tester.tap(find.text('Call'));
    // The no-handler FlutterError must become a visible notice, never a
    // silent no-op.
    var surfaced = false;
    for (var i = 0; i < 20 && !surfaced; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      surfaced = find
          .textContaining(RegExp('No app|Phone|Messages|unavailable'))
          .evaluate()
          .isNotEmpty;
    }
    expect(surfaced, isTrue, reason: 'no-handler error never surfaced');
  });
}
