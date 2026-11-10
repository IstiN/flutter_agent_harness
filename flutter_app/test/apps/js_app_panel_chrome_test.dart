// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT-style license that can be
// found in the LICENSE file.

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa_ui/fa_ui.dart'
    show
        FaDuoControlRail,
        FaHeaderCircularAction,
        FaRouteHeader,
        FaSurface,
        FaVisualDirection,
        FaWindowChrome,
        buildFaTheme;
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<MemoryExecutionEnv> _brokenAppEnv() async {
  final env = MemoryExecutionEnv();
  // Deterministic start error before a native JS engine is needed.
  await env.writeFile('apps/demo/manifest.json', '{}');
  return env;
}

Future<void> _pumpView(
  WidgetTester tester, {
  required double width,
  required bool embeddedInPanel,
  bool withPanelChrome = true,
  bool fullScreen = false,
  bool pushedRoute = false,
  bool leadingMinimize = false,
  double rightInset = 0,
  double topInset = 0,
  List<String>? calls,
  ThemeData? theme,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  tester.view.padding = FakeViewPadding(top: topInset, right: rightInset);
  addTearDown(tester.view.reset);
  final env = await _brokenAppEnv();
  final permissions = await AppPermissionsStore.load(env);
  final view = JsAppView(
    app: JsAppInfo.fromManifest(
      const {'id': 'demo', 'name': 'Demo'},
      bundled: false,
      fallbackId: 'demo',
    ),
    env: env,
    permissionsStore: permissions,
    embeddedInPanel: embeddedInPanel,
    panelChrome: withPanelChrome
        ? JsAppPanelChrome(
            fullScreen: fullScreen,
            pinned: false,
            onFullScreen: () => calls?.add('full'),
            onPin: () => calls?.add('pin'),
            onClose: () => calls?.add('close'),
            onMinimize: () => calls?.add('minimize'),
            onBack: leadingMinimize ? () => calls?.add('minimize') : null,
          )
        : null,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: pushedRoute
          ? Builder(
              builder: (context) => TextButton(
                key: const ValueKey('openApp'),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: (_) => view)),
                child: const Text('Open app'),
              ),
            )
          : view,
    ),
  );
  if (pushedRoute) {
    await tester.tap(find.byKey(const ValueKey('openApp')));
  }
  await tester.pumpAndSettle();
}

void _testOnPlatform(
  String description,
  TargetPlatform platform,
  Future<void> Function(WidgetTester tester) body,
) {
  testWidgets(description, (tester) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      await body(tester);
    } finally {
      // The binding checks debug globals before tearDown callbacks run.
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  _testOnPlatform(
    'presented app uses one capsule and every action still fires',
    TargetPlatform.android,
    (tester) async {
      final calls = <String>[];
      await _pumpView(tester, width: 520, embeddedInPanel: true, calls: calls);

      final band = find.byKey(const ValueKey('appChromeActions'));
      expect(band, findsOneWidget);
      expect(
        find.descendant(of: band, matching: find.byType(FaSurface)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: band,
          matching: find.byType(FaHeaderCircularAction),
        ),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('appOverflow')), findsOneWidget);

      for (final key in ['appFull', 'appPin', 'appMinimize', 'appClose']) {
        await tester.tap(find.byKey(ValueKey(key)));
      }
      expect(calls, ['full', 'pin', 'minimize', 'close']);

      await tester.tap(find.byKey(const ValueKey('appOverflow')));
      await tester.pumpAndSettle();
      expect(find.text('App permissions'), findsOneWidget);
      expect(find.text('Reload app'), findsOneWidget);
      await tester.tap(find.text('Close app'));
      await tester.pumpAndSettle();
      expect(calls, ['full', 'pin', 'minimize', 'close', 'close']);
    },
  );

  _testOnPlatform(
    '320px panel keeps every app action inline at 28px without overflow',
    TargetPlatform.android,
    (tester) async {
      await _pumpView(tester, width: 320, embeddedInPanel: true);

      const actionKeys = [
        'appFull',
        'appPin',
        'appMinimize',
        'appPermissions',
        'appReload',
        'appClose',
      ];
      for (final key in actionKeys) {
        final action = find.byKey(ValueKey(key));
        expect(action, findsOneWidget, reason: '$key must stay inline');
        expect(tester.getSize(action), const Size.square(28));
      }
      expect(find.byKey(const ValueKey('appOverflow')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  _testOnPlatform(
    '160px panel overflow opens with intrinsic-safe rows for every action',
    TargetPlatform.android,
    (tester) async {
      final calls = <String>[];
      await _pumpView(tester, width: 160, embeddedInPanel: true, calls: calls);

      for (final key in [
        'appFull',
        'appPin',
        'appMinimize',
        'appPermissions',
        'appReload',
        'appClose',
      ]) {
        expect(find.byKey(ValueKey(key)), findsNothing);
      }
      await tester.tap(find.byKey(const ValueKey('appOverflow')));
      await tester.pumpAndSettle();

      // This really lays out the popup route. In particular, a LayoutBuilder
      // in an item fails here while PopupMenuItem computes intrinsics.
      expect(tester.takeException(), isNull);
      final entries = tester
          .widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>))
          .toList();
      expect(entries.map((entry) => entry.value), [
        'full',
        'pin',
        'minimize',
        'permissions',
        'reload',
        'close',
      ]);
      for (final entry in entries) {
        final row = entry.child as Row;
        expect(row.children[0], isA<Icon>());
        expect(row.children[1], isA<SizedBox>());
        final label = (row.children[2] as Flexible).child as Text;
        expect(label.overflow, TextOverflow.ellipsis);
      }

      await tester.tap(find.text('Close app'));
      await tester.pumpAndSettle();
      expect(calls, ['close']);
    },
  );

  _testOnPlatform(
    'Duo presented app actions stay below the camera in the right rail',
    TargetPlatform.iOS,
    (tester) async {
      final calls = <String>[];
      await _pumpView(
        tester,
        width: 1230,
        embeddedInPanel: true,
        rightInset: 84,
        calls: calls,
        theme: buildFaTheme(
          brightness: Brightness.light,
          direction: FaVisualDirection.glass,
        ),
      );

      final rail = find.byKey(const ValueKey('appChromeActions'));
      expect(rail, findsOneWidget);
      expect(tester.widget<FaDuoControlRail>(rail), isA<FaDuoControlRail>());
      expect(tester.getRect(rail).left, greaterThanOrEqualTo(1230 - 84));
      for (final key in [
        'duoAppBack',
        'appFull',
        'appPin',
        'appPermissions',
        'appReload',
        'appClose',
      ]) {
        final control = find.byKey(ValueKey(key));
        final rect = tester.getRect(control);
        expect(rect.left, greaterThanOrEqualTo(1230 - 84));
        expect(rect.top, greaterThanOrEqualTo(FaDuoControlRail.top));
        if (key != 'appPermissions' && key != 'appReload') {
          await tester.tap(control);
        }
      }
      // With no explicit Back callback the rail's Back action returns to
      // the directory through the existing minimize callback.
      expect(calls, ['minimize', 'full', 'pin', 'close']);
      expect(find.byKey(const ValueKey('appOverflow')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  _testOnPlatform(
    'Duo folded toolbar does not SafeArea its title to zero height',
    TargetPlatform.iOS,
    (tester) async {
      await _pumpView(
        tester,
        width: 390,
        embeddedInPanel: true,
        rightInset: 84,
        topInset: 59,
      );

      final appBar = find.byType(AppBar);
      final toolbarClip = find
          .descendant(of: appBar, matching: find.byType(ClipRect))
          .first;
      expect(tester.getSize(toolbarClip).height, kToolbarHeight);
      final title = find.descendant(of: appBar, matching: find.text('Demo'));
      expect(title, findsOneWidget);
      expect(tester.getRect(title).top, greaterThanOrEqualTo(59));
      expect(tester.getRect(title).right, lessThanOrEqualTo(390 - 84));
      final preferred = find.byType(PreferredSize).first;
      final canvasPadding = tester.widget<Padding>(
        find.byKey(const ValueKey('appCanvasHeaderInset')),
      );
      expect(
        canvasPadding.padding.resolve(TextDirection.ltr).top,
        tester.getRect(preferred).height,
      );
      expect(tester.takeException(), isNull);
    },
  );

  _testOnPlatform(
    'desktop leading action minimizes without a duplicate capsule action',
    TargetPlatform.macOS,
    (tester) async {
      final calls = <String>[];
      await _pumpView(
        tester,
        width: 1200,
        embeddedInPanel: true,
        leadingMinimize: true,
        calls: calls,
      );

      final leading = find.byKey(const ValueKey('presentedAppMinimizeButton'));
      expect(leading, findsOneWidget);
      expect(
        find.descendant(
          of: leading,
          matching: find.byIcon(Icons.remove_rounded),
        ),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('appMinimize')), findsNothing);
      await tester.tap(leading);
      expect(calls, ['minimize']);
    },
  );

  _testOnPlatform(
    'full presentation keeps Exit full inside the same capsule',
    TargetPlatform.android,
    (tester) async {
      await _pumpView(
        tester,
        width: 1200,
        embeddedInPanel: false,
        fullScreen: true,
      );
      final band = find.byKey(const ValueKey('appChromeActions'));
      expect(band, findsOneWidget);
      expect(find.byIcon(Icons.close_fullscreen), findsOneWidget);
      expect(find.byTooltip('Exit full'), findsOneWidget);
    },
  );

  _testOnPlatform(
    'glass app chrome keeps the canvas below its header',
    TargetPlatform.android,
    (tester) async {
      await _pumpView(
        tester,
        width: 520,
        embeddedInPanel: true,
        theme: buildFaTheme(
          brightness: Brightness.dark,
          direction: FaVisualDirection.glass,
        ),
      );
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.extendBodyBehindAppBar, isTrue);
      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.backgroundColor, Colors.transparent);
      expect(
        find.byKey(const ValueKey('appChromeGlassUnderlay')),
        findsOneWidget,
      );
      final inset = tester.widget<Padding>(
        find.byKey(const ValueKey('appCanvasHeaderInset')),
      );
      expect(inset.padding, const EdgeInsets.only(top: kToolbarHeight));
      expect(
        tester
            .getRect(
              find.descendant(
                of: find.byKey(const ValueKey('appCanvasHeaderInset')),
                matching: find.byType(RepaintBoundary),
              ),
            )
            .top,
        greaterThanOrEqualTo(tester.getRect(find.byType(AppBar)).bottom),
      );
    },
  );

  _testOnPlatform(
    'macOS compact and full panel chrome clear traffic lights',
    TargetPlatform.macOS,
    (tester) async {
      await _pumpView(tester, width: 390, embeddedInPanel: true);
      expect(tester.getTopLeft(find.text('Demo')).dx, greaterThanOrEqualTo(72));

      await _pumpView(
        tester,
        width: 1200,
        embeddedInPanel: false,
        fullScreen: true,
      );
      expect(tester.getTopLeft(find.text('Demo')).dx, greaterThanOrEqualTo(72));
    },
  );

  _testOnPlatform(
    'macOS pushed chrome lowers only Back below the titlebar',
    TargetPlatform.macOS,
    (tester) async {
      await _pumpView(
        tester,
        width: 1200,
        embeddedInPanel: false,
        withPanelChrome: false,
        pushedRoute: true,
      );
      expect(find.byType(FaRouteHeader), findsOneWidget);
      expect(
        tester.getTopLeft(find.byType(BackButton)).dy,
        greaterThanOrEqualTo(FaWindowChrome.titlebarHeight),
      );
      expect(
        tester.getRect(find.text('Demo')).center.dy,
        lessThan(FaWindowChrome.titlebarHeight),
      );
    },
  );

  _testOnPlatform(
    'wide inline macOS and compact phone geometry gain no inset',
    TargetPlatform.macOS,
    (tester) async {
      await _pumpView(tester, width: 1200, embeddedInPanel: true);
      expect(tester.getTopLeft(find.text('Demo')).dx, lessThan(72));

      await _pumpView(
        tester,
        width: 1200,
        embeddedInPanel: true,
        withPanelChrome: false,
      );
      expect(tester.getTopLeft(find.text('Demo')).dx, lessThan(72));
      expect(tester.getSize(find.byType(AppBar)).height, kToolbarHeight);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await _pumpView(tester, width: 390, embeddedInPanel: false);
      expect(tester.getTopLeft(find.text('Demo')).dx, lessThan(72));
    },
  );
}
