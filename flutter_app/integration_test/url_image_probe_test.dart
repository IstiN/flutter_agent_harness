// ignore_for_file: avoid_print
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/sandbox/env_factory.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// Probe: does the `image` node render a network URL on a real device?
/// Writes a tiny app into the sandbox, boots it, and checks the image
/// decodes (RawImage with a non-null image) instead of a blank/broken state.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('image node renders an https URL', (tester) async {
    final env = await createPlatformEnv();
    const widgetJs = '''
(function() {
  jsr.render({ type: 'column', children: [
    { type: 'text', data: 'url image below' },
    { type: 'image',
      url: 'https://www.gstatic.com/webp/gallery/1.jpg',
      width: 120, height: 120 },
    { type: 'image',
      url: 'https://invalid.invalid/nope.png',
      width: 120, height: 120 },
    { type: 'text', data: 'end' }
  ] });
})();
''';
    await env.writeFile('apps/img-probe/manifest.json', '''
{"id":"img-probe","name":"Img Probe","version":"1.0.0","description":"probe","network":true}
''');
    await env.writeFile('apps/img-probe/widget.js', widgetJs);
    final app = JsAppInfo.fromManifest(
      const {'id': 'img-probe', 'name': 'Img Probe', 'network': true},
      bundled: false,
      fallbackId: 'img-probe',
    );
    final permissions = await AppPermissionsStore.load(env);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: JsAppView(app: app, env: env, permissionsStore: permissions),
      ),
    );

    var decoded = false;
    var sawBroken = false;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      decoded = tester
          .widgetList<RawImage>(find.byType(RawImage))
          .any((r) => r.image != null);
      sawBroken = find.byIcon(Icons.broken_image).evaluate().isNotEmpty;
      if (decoded) break;
    }
    print('[probe] decoded=$decoded broken=$sawBroken');
    expect(decoded, isTrue, reason: 'network image never decoded');
  });
}
