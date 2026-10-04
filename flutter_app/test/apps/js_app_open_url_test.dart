// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found in
// the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter/widgets.dart' show LinkDelegate;
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/method_channel_url_launcher.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import '../native_test_guard.dart';

/// Skip value stamped on this file's engine-dependent tests: every one
/// boots a real JS engine (issue #184). Resolved once per isolate.
final _engineSkip = quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable;

/// Mock seam for `url_launcher` (the dev dependency
/// url_launcher_platform_interface exists exactly for this — same pattern
/// as test/ui/github_connect_sheet_test.dart): records every launch and
/// gates `canLaunch` per URL.
final class _FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <String>[];
  final canLaunchUrls = <String, bool>{};
  bool launchResult = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => canLaunchUrls[url] ?? false;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return launchResult;
  }
}

void main() {
  group('jsr.openUrl (engine bridge)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late _FakeUrlLauncher launcher;

    setUp(() {
      launcher = _FakeUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
    });

    tearDown(() {
      UrlLauncherPlatform.instance = MethodChannelUrlLauncher();
    });

    JsAppInfo app() => JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo'},
      bundled: false,
      fallbackId: 'demo',
    );

    /// Boots an engine whose widget.js runs [body] and waits until the app
    /// exported state (bridge calls cross real platform channels, so a
    /// single fixed settle can race under load).
    Future<JsAppEngine> boot(WidgetTester tester, String body) async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', body);
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      await engine.start();
      for (var i = 0; i < 40 && engine.exportedState == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      return engine;
    }

    testWidgets('resolves true and launches in the external browser', (
      tester,
    ) async {
      await tester.runAsync(() async {
        launcher.canLaunchUrls['https://example.com'] = true;
        launcher.canLaunchUrls['https://example.org'] = true;
        final engine = await boot(
          tester,
          '''
(function() {
  Promise.all([
    jsr.openUrl('https://example.com'),
    jsr.openUrl('https://example.org'),
  ]).then(function(results) {
    jsr.exportState({opened: results});
  }, function(err) {
    jsr.exportState({openError: String(err)});
  });
})();
''',
        );
        try {
          expect(engine.exportedState, isNotNull);
          expect(engine.exportedState!['opened'], [true, true]);
          // Both URLs crossed the url_launcher mock, in call order.
          expect(launcher.launched, [
            'https://example.com',
            'https://example.org',
          ]);
          expect(engine.exportedState!['openError'], isNull);
        } finally {
          await engine.dispose();
        }
      });
    }, skip: _engineSkip);

    testWidgets('rejects when the platform cannot launch the URL', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final engine = await boot(
          tester,
          '''
(function() {
  jsr.openUrl('bad-scheme://nowhere').then(function(ok) {
    jsr.exportState({opened: ok});
  }, function(err) {
    jsr.exportState({openError: String(err)});
  });
})();
''',
        );
        try {
          expect(engine.exportedState, isNotNull);
          expect(engine.exportedState!['opened'], isNull);
          expect(
            engine.exportedState!['openError'],
            'Error: cannot launch bad-scheme://nowhere',
          );
          expect(launcher.launched, isEmpty);
        } finally {
          await engine.dispose();
        }
      });
    }, skip: _engineSkip);

    testWidgets('rejects when the launch itself fails', (tester) async {
      await tester.runAsync(() async {
        launcher.canLaunchUrls['https://example.com'] = true;
        launcher.launchResult = false;
        final engine = await boot(
          tester,
          '''
(function() {
  jsr.openUrl('https://example.com').then(function(ok) {
    jsr.exportState({opened: ok});
  }, function(err) {
    jsr.exportState({openError: String(err)});
  });
})();
''',
        );
        try {
          expect(engine.exportedState, isNotNull);
          expect(engine.exportedState!['opened'], isNull);
          expect(
            engine.exportedState!['openError'],
            'Error: launch failed',
          );
          expect(launcher.launched, ['https://example.com']);
        } finally {
          await engine.dispose();
        }
      });
    }, skip: _engineSkip);
  });
}
