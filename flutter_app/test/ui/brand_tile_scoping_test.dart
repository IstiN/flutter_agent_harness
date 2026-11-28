// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The brand-tile scoping (gh-2391 addendum 8 item 1): [FaBrandTile] — and
/// the chat-pane header brand routed through it — must consult
/// [ProductConfigScope] themselves. A non-stock profile renders the host
/// mark (the `icon192` asset, else the deterministic monogram) — never the
/// stock `>Fa` tile, on any of the call sites (boot, bootstrap errors,
/// onboarding, network home, the wide shell's header/profile routes).
/// Stock renders today's `FaLogo` tile byte-identically (REG).
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/widgets/fa_mark.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa/ui/widgets/wide_layout_shell.dart';
import 'package:fa_ui/fa_ui.dart' show FaLogo, FaVisualDirection, buildFaTheme;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

AgentService _service(ExecutionEnv env) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
  );
}

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

Future<void> _pumpShell(WidgetTester tester, {FaProductConfig? config}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final env = MemoryExecutionEnv();
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', _service(env));
  // The scope rides the navigator builder (the main.dart mounting): routes
  // pushed later must see the same ambient product identity.
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFaTheme(
        direction: FaVisualDirection.glass,
        brightness: Brightness.dark,
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: WideLayoutShell(manager: manager),
      builder: config == null
          ? null
          : (context, child) =>
                ProductConfigScope(productConfig: config, child: child!),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

FaProductConfig _brandedProfile() => FaProductConfig.fromJson({
  'productId': 'ain',
  'displayName': 'AIIN Agent',
  'apiEndpoint': 'https://api.aiin.example/v1',
  'featureFlags': <String>[],
  'hostConnection': {
    'baseUrl': 'https://api.aiin.example/v1',
    'sessionBridge': {'storage': 'localStorage', 'key': 'aiin_agent_session'},
    'defaultModel': 'aiin/aiin_flash',
  },
});

/// The brand mark a branded tile must render: the host asset, else the
/// monogram. This profile declares no assets, so the deterministic
/// monogram is the observable.
final _monogram = find.byKey(const ValueKey('productBrandMonogram'));

void main() {
  group('FaBrandTile consults the product scope itself', () {
    testWidgets('non-stock scope renders the host mark, never the stock '
        'tile', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.light,
          ),
          home: ProductConfigScope(
            productConfig: _brandedProfile(),
            child: const Scaffold(body: Center(child: FaBrandTile(size: 48))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_monogram, findsOneWidget);
      expect(find.byType(FaLogo), findsNothing);
    });

    testWidgets('stock scope keeps the stock tile (REG)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.light,
          ),
          home: ProductConfigScope(
            productConfig: FaProductConfig.stock,
            child: const Scaffold(body: Center(child: FaBrandTile(size: 48))),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FaLogo), findsOneWidget);
      expect(_monogram, findsNothing);
    });

    testWidgets('no scope at all (bare unit tests) keeps the stock tile '
        '(REG)', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildFaTheme(
            direction: FaVisualDirection.glass,
            brightness: Brightness.light,
          ),
          home: const Scaffold(body: Center(child: FaBrandTile(size: 48))),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(FaLogo), findsOneWidget);
    });
  });

  group('the chat-pane header brand (the visible one)', () {
    testWidgets('branded build: the header renders the host mark', (
      tester,
    ) async {
      await _pumpShell(tester, config: _brandedProfile());
      final brand = find
          .ancestor(
            of: find.byKey(const ValueKey('wideShellFaBrand')),
            matching: find.byType(SizedBox),
          )
          .first;
      expect(
        find.descendant(of: brand, matching: _monogram),
        findsOneWidget,
        reason: 'the chat-pane header never shows the stock >Fa logo',
      );
    });

    testWidgets('stock: the header keeps the Fa logo (REG)', (tester) async {
      await _pumpShell(tester);
      final brand = find
          .ancestor(
            of: find.byKey(const ValueKey('wideShellFaBrand')),
            matching: find.byType(SizedBox),
          )
          .first;
      expect(
        find.descendant(of: brand, matching: find.byType(FaLogo)),
        findsOneWidget,
      );
    });

    testWidgets('branded build: the narrow profile route renders the host '
        'mark too', (tester) async {
      await _pumpShell(tester, config: _brandedProfile());
      await tester.tap(find.byKey(const ValueKey('messengerProfile')));
      await tester.pumpAndSettle();
      // The profile route's FaBrandTile(size: 64) is scoped.
      expect(_monogram, findsWidgets);
    });
  });
}
