import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import '../native_test_guard.dart';

Future<void> _pumpPresentedApp(
  WidgetTester tester,
  MemoryExecutionEnv env, {
  required String id,
  required String source,
  required String readyText,
}) async {
  await env.writeFile('apps/$id/widget.js', source);
  final permissions = await AppPermissionsStore.load(env);
  tester.view.physicalSize = const Size(680, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: JsAppView(
        app: JsAppInfo.fromManifest(
          {'id': id, 'name': id},
          bundled: false,
          fallbackId: id,
        ),
        env: env,
        permissionsStore: permissions,
        embeddedInPanel: true,
        panelChrome: JsAppPanelChrome(
          fullScreen: false,
          pinned: false,
          onFullScreen: () {},
          onPin: () {},
          onClose: () {},
          onMinimize: () {},
        ),
      ),
    ),
  );
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
    if (find.text(readyText).evaluate().isNotEmpty) {
      await tester.pump(const Duration(milliseconds: 300));
      return;
    }
  }
  fail('$id did not render $readyText');
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('presented JS app canvas layout', () {
    testWidgets('intrinsic leaf root stays top-centered', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await _pumpPresentedApp(
          tester,
          env,
          id: 'demo',
          readyText: 'Demo',
          source: "jsr.render({type: 'text', data: 'Demo'});",
        );
        final label = tester.getRect(find.text('Demo'));
        expect(label.center.dx, 340);
        expect(label.top, tester.getRect(find.byType(AppBar)).bottom);
        await _unmount(tester);
      });
    });

    testWidgets('explicit flex root keeps its size and top-start position', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await _pumpPresentedApp(
          tester,
          env,
          id: 'fixed',
          readyText: 'Fixed header',
          source: r'''
jsr.render({type: 'container', width: 320, height: 220,
  decoration: {color: '#172554'},
  child: {type: 'column', children: [
    {type: 'text', data: 'Fixed header'},
    {type: 'expanded', child: {type: 'text', data: 'Fixed canvas'}}
  ]}
});
''',
        );
        final root = tester
            .widgetList<Container>(find.byType(Container))
            .firstWhere(
              (widget) =>
                  widget.constraints?.maxWidth == 320 &&
                  widget.constraints?.maxHeight == 220,
            );
        final rect = tester.getRect(find.byWidget(root));
        expect(rect.left, 180);
        expect(rect.top, tester.getRect(find.byType(AppBar)).bottom);
        expect(rect.size, const Size(320, 220));
        await _unmount(tester);
      });
    });

    testWidgets('root list does not repeat the app-bar inset', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await _pumpPresentedApp(
          tester,
          env,
          id: 'calculator',
          readyText: '0',
          source: r'''
jsr.render({
  type: 'padding', padding: [12, 12, 12, 12],
  child: {type: 'listView', shrinkWrap: false, children: [
    {type: 'animatedContainer', height: 110, duration: 250, curve: 'easeOut',
      margin: [0, 0, 0, 8], padding: [16, 12, 16, 12],
      decoration: {color: '#111827'},
      child: {type: 'column', mainAxisAlignment: 'center',
        crossAxisAlignment: 'end', children: [
          {type: 'text', data: '0',
            style: {color: '#F9FAFB', fontSize: 46, height: 1.0}}
        ]}},
    {type: 'text', data: 'C'}
  ]}
});
''',
        );
        expect(find.text('C'), findsOneWidget);
        // The canvas reserves 56pt for the presented chrome. Scaffold also
        // exposes that inset as MediaQuery padding; an un-padded ListView
        // would otherwise insert the same 56pt above its first item again.
        expect(
          tester.getRect(find.text('0')).top -
              tester.getRect(find.byType(AppBar)).bottom,
          lessThan(60),
        );
        await _unmount(tester);
      });
    });

    testWidgets('unsigned column keeps its header above an expanded list', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await _pumpPresentedApp(
          tester,
          env,
          id: 'calendar',
          readyText: 'Calendar day',
          source: r'''
jsr.render({
  type: 'column', crossAxisAlignment: 'stretch', children: [
    {type: 'padding', padding: [16, 12, 16, 12],
      child: {type: 'text', data: 'Calendar day'}},
    {type: 'divider', height: 1},
    {type: 'expanded', child: {
      type: 'listView', shrinkWrap: false, padding: [0, 0, 0, 24],
      children: [{type: 'text', data: 'Event 1'}]
    }}
  ]
});
''',
        );
        expect(find.text('Event 1'), findsOneWidget);
        expect(
          tester.getRect(find.text('Calendar day')).top -
              tester.getRect(find.byType(AppBar)).bottom,
          lessThan(40),
        );
        await _unmount(tester);
      });
    });

    testWidgets('expanded canvas and stretch controls survive unbounded rows', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await _pumpPresentedApp(
          tester,
          env,
          id: 'neon-breakout-3d',
          readyText: 'NEON BREAKOUT',
          source: r'''
jsr.render({
  type: 'container', decoration: {color: '#050816'},
  child: {type: 'safeArea', child: {
    type: 'padding', padding: [12, 8, 12, 10],
    child: {type: 'column', crossAxisAlignment: 'stretch', children: [
      {type: 'text', data: 'NEON BREAKOUT'},
      {type: 'expanded', child: {
        type: 'container', child: {type: 'text', data: '3D CANVAS'}
      }},
      {type: 'row', crossAxisAlignment: 'stretch', children: [
        {type: 'expanded', child: {
          type: 'button', label: 'LAUNCH', onPressed: 'launch'
        }},
        {type: 'expanded', child: {
          type: 'outlinedButton', label: 'PAUSE', onPressed: 'pause'
        }}
      ]}
    ]}
  }}
});
''',
        );
        expect(find.text('3D CANVAS'), findsOneWidget);
        expect(find.text('LAUNCH'), findsOneWidget);
        expect(find.text('PAUSE'), findsOneWidget);
        expect(tester.getRect(find.text('3D CANVAS')).height, greaterThan(0));
        await _unmount(tester);
      });
    });
  }, skip: quickJsBridgeAvailable ? false : kQuickJsBridgeUnavailable);
}
