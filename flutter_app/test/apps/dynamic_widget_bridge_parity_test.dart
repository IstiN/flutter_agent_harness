// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Bridge-parity contract for dynamic-message widgets (AC6): a widget runs
/// the SAME [JsAppEngine] with the SAME fa bootstrap as an installed app —
/// no subclass, no stripped bridges, unchanged permission gates — with only
/// its storage/code directory redirected via [JsAppInfo.dirOverride].
///
/// Same harness as js_app_engine_test.dart: everything runs inside
/// `tester.runAsync` with small real delays — the JS→Dart bridge messages
/// are processed on the real event loop.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 300);

  JsAppInfo app() => JsAppInfo.fromManifest(
    const {'id': 'demo', 'name': 'Demo'},
    bundled: false,
    fallbackId: 'demo',
  );

  /// A session-scoped dynamic-message widget: code/storage live under the
  /// session folder instead of `apps/`.
  JsAppInfo widgetApp() => JsAppInfo(
    id: 'w-1',
    name: 'Widget',
    description: '',
    icon: '📦',
    declaredPermissions: const AppPermissions(),
    dirOverride: '.widgets/session-1/w-1',
  );

  const probeJs = '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  jsr.fa.emit('ping', {n: 1}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__rejected: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''';

  testWidgets('widget engine and app engine get the identical bridge surface', (
    tester,
  ) async {
    await tester.runAsync(() async {
      // Identity: a dirOverride app boots the SAME engine class — no
      // subclass with a stripped bridge set.
      expect(widgetApp(), isA<JsAppInfo>());
      expect(widgetApp().dir, '.widgets/session-1/w-1');

      final env = MemoryExecutionEnv();
      await env.writeFile('${widgetApp().dir}/widget.js', probeJs);
      await env.writeFile('apps/demo/widget.js', probeJs);
      final widgetEngine = JsAppEngine(
        app: widgetApp(),
        env: env,
        permissions: const AppPermissions(),
      );
      final appEngine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        expect(widgetEngine, isA<JsAppEngine>());

        await widgetEngine.start();
        await appEngine.start();
        await Future<void>.delayed(settle);

        // Byte parity: the same static bootstrap (see the method-set test
        // below) drives both engines, so the same fa.emit probe resolves
        // identically — {emitted: false}, neither has a host sink here.
        expect(
          jsonEncode(widgetEngine.exportedState?['result']),
          jsonEncode(appEngine.exportedState?['result']),
        );
        expect(widgetEngine.exportedState?['result'], {'emitted': false});
      } finally {
        await widgetEngine.dispose();
        await appEngine.dispose();
      }
    });
  });

  testWidgets('permission gates are unchanged for widget engines', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${widgetApp().dir}/widget.js', '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  jsr.fa.llm('ping').then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__rejected: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');
      final engine = JsAppEngine(
        app: widgetApp(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        await engine.start();
        await Future<void>.delayed(settle);

        // const AppPermissions() has every flag false: the llm gate still
        // denies through the same _faCall route (emit is the ONLY un-gated
        // addition, and it has no permission to check). Denials resolve as
        // {__error: ...}, which the runtime bootstrap surfaces as a promise
        // rejection — identical to an installed app.
        expect(
          engine.exportedState?['result']?['__rejected'],
          contains('llm permission'),
        );
      } finally {
        await engine.dispose();
      }
    });
  });

  test('bootstrap is public, non-empty, and bakes in the host locale', () {
    final bootstrap = JsAppEngine.faBootstrapJsFor('en');
    expect(bootstrap, isNotEmpty);
    expect(
      JsAppEngine.faBootstrapJsFor('ru'),
      startsWith("jsr.locale = 'ru';"),
    );
  });

  test('bootstrap declares exactly the _faCall bridge method set', () {
    final bootstrap = JsAppEngine.faBootstrapJsFor('en');

    // Bridge methods appear as literal first args of jsr.fa.call('...').
    // The last-char-letter shape excludes the runtime prefix concatenations
    // ('homekit.' / 'health.' / 'contacts.' + action — they share handlers
    // with the home.*/health.summary/contacts.* literals) while keeping the
    // dotless 'llm' shorthand and 'emit'.
    final methods = RegExp(
      r"jsr\.fa\.call\('([a-z][a-zA-Z.]*[a-zA-Z])'",
    ).allMatches(bootstrap).map((m) => m.group(1)!).toSet();
    const expected = {
      // llm — dotless one-shot shorthand + multi-turn + streaming.
      'llm', 'llm.chat', 'llm.stream',
      // calendar
      'calendar.events', 'calendar.create', 'calendar.update',
      'calendar.delete',
      // contacts
      'contacts.search', 'contacts.create', 'contacts.update',
      'contacts.delete', 'contacts.call', 'contacts.sms',
      // health
      'health.summary',
      // home (legacy homekit.<action> aliases route to the same handlers)
      'home.homes', 'home.rooms', 'home.list', 'home.read', 'home.write',
      'home.scenes', 'home.executeScene', 'home.setPower',
      'home.setBrightness', 'home.setTemperature',
      // asr
      'asr.record', 'asr.stop', 'asr.transcribe',
      // notify
      'notify.schedule', 'notify.cancel',
      // media
      'media.generateImage', 'media.speak', 'media.generateMusic',
      'media.generateVideo', 'media.readVideo',
      // keys
      'keys.list', 'keys.get', 'keys.request',
      // back navigation + the widget->host emit channel.
      'back.handler', 'back.close', 'emit',
    };
    expect(methods, expected);

    // Shell exec and network fetch ride OUTSIDE jsr.fa.call (jsr.exec is the
    // transport jsr.fa.call itself builds on; jsr.fetchJson is core runtime,
    // not part of the fa bootstrap) — assert the exec reference that exists
    // today.
    expect(bootstrap, contains('jsr.exec'));
  });
}
