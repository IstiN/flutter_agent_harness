// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/apps/js_app_navigation.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/apps/js_theme.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Coverage for the JS-app theme pipeline: the `jsr.theme` map built from
/// the app theme ([jsThemeMap]), the engine's initialTheme/updateTheme
/// plumbing, live propagation from [JsAppView] on host theme flips, and the
/// compact Theme line appended to in-app agent messages.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 300);

  group('jsThemeMap', () {
    Future<Map<String, dynamic>> capture(
      WidgetTester tester,
      ThemeData theme,
    ) async {
      Map<String, dynamic>? captured;
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (context) {
              captured = jsThemeMap(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return captured!;
    }

    testWidgets('emits every key with the dark palette values', (tester) async {
      final theme = await capture(tester, buildFahTheme());
      expect(theme, {
        'brightness': 'dark',
        'dark': true,
        'background': '#070A10',
        'surface': '#0D1420',
        'surfaceAlt': '#101928',
        'border': '#1C2637',
        'borderBright': '#2B3A52',
        'text': '#E8EEF7',
        'muted': '#93A1B5',
        'accent': '#5EEAD4',
        'accent2': '#818CF8',
        'onAccent': '#06121A',
        'error': '#FF8A80',
        'userBubble': '#818CF8', // alpha stripped from 0x2E818CF8
        'userBubbleBorder': '#818CF8',
        'codeBg': '#93A1B5',
        'isDark': true,
        'bg': '#070A10',
      });
    });

    testWidgets('emits every key with the light palette values', (
      tester,
    ) async {
      final theme = await capture(tester, buildFahThemeLight());
      expect(theme, {
        'brightness': 'light',
        'dark': false,
        'background': '#F8F9FC',
        'surface': '#FFFFFF',
        'surfaceAlt': '#F3F4F6',
        'border': '#E5E7EB',
        'borderBright': '#D1D5DB',
        'text': '#111827',
        'muted': '#6B7280',
        'accent': '#0F766E',
        'accent2': '#4F46E5',
        'onAccent': '#FFFFFF',
        'error': '#B3261E',
        'userBubble': '#EEF2FF',
        'userBubbleBorder': '#C7D2FE',
        'codeBg': '#5B6676',
        'isDark': false,
        'bg': '#F8F9FC',
      });
    });

    testWidgets('the summary line is compact and agent-ready', (tester) async {
      final theme = await capture(tester, buildFahTheme());
      expect(
        jsThemeSummaryLine(theme),
        'Theme: dark, bg #070A10, surface #0D1420, text #E8EEF7, '
        'accent #5EEAD4, accent2 #818CF8',
      );
    });
  });

  group('engine theme plumbing', () {
    // Renders jsr.theme.accent and re-renders + re-exports on theme change.
    const themedWidgetJs = '''
(function() {
  function render() {
    jsr.render({type:'text', data:'hi', style:{color: jsr.theme.accent}});
    jsr.exportState({
      accent: jsr.theme.accent,
      brightness: jsr.theme.brightness,
    });
  }
  jsr.onEvent(function(){});
  jsr._onThemeChange = function() { render(); };
  render();
})();
''';

    testWidgets('initialTheme reaches JS and updateTheme fires '
        '_onThemeChange', (tester) async {
      await tester.runAsync(() async {
        final env = MemoryExecutionEnv();
        await env.writeFile('apps/themed/widget.js', themedWidgetJs);
        final engine = JsAppEngine(
          app: JsAppInfo.fromManifest(
            const {'id': 'themed', 'name': 'Themed'},
            bundled: false,
            fallbackId: 'themed',
          ),
          env: env,
          permissions: const AppPermissions(),
          initialTheme: const {
            'brightness': 'dark',
            'dark': true,
            'accent': '#5EEAD4',
          },
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          // The boot theme is visible in both the render tree and the
          // exported state.
          expect(jsonEncode(engine.tree.value), contains('#5EEAD4'));
          expect(engine.exportedState?['accent'], '#5EEAD4');
          expect(engine.exportedState?['brightness'], 'dark');

          // A host theme flip replaces jsr.theme and fires _onThemeChange.
          await engine.updateTheme(const {
            'brightness': 'light',
            'dark': false,
            'accent': '#0F766E',
          });
          await Future<void>.delayed(settle);
          expect(jsonEncode(engine.tree.value), contains('#0F766E'));
          expect(engine.exportedState?['accent'], '#0F766E');
          expect(engine.exportedState?['brightness'], 'light');
        } finally {
          await engine.dispose();
        }
      });
    });
  });

  group('JsAppView live theme propagation', () {
    const themedWidgetJs = '''
(function() {
  function render() {
    jsr.render({
      type: 'container', width: 80, height: 80,
      decoration: { color: jsr.theme.accent, borderRadius: 4 },
    });
    jsr.exportState({ brightness: jsr.theme.brightness });
  }
  jsr.onEvent(function(){});
  jsr._onThemeChange = function() { render(); };
  render();
})();
''';

    bool hasAccentContainer(WidgetTester tester, int argb) {
      return tester.widgetList<Container>(find.byType(Container)).any((c) {
        final decoration = c.decoration;
        return decoration is BoxDecoration &&
            decoration.color?.toARGB32() == argb;
      });
    }

    testWidgets('flipping the host theme pushes updateTheme into the JS app', (
      tester,
    ) async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/themed/manifest.json', '{}');
      await env.writeFile('apps/themed/widget.js', themedWidgetJs);
      final permissions = await AppPermissionsStore.load(env);
      final controller = ThemeController.inMemory(FahThemeMode.dark);
      addTearDown(controller.dispose);

      // The initial pumpWidget runs inside runAsync so flutter_js's periodic
      // XHR timer is a REAL timer (a fake-zone one would trip the
      // timers-pending invariant at teardown).
      await tester.runAsync(() async {
        await tester.pumpWidget(
          ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              return MaterialApp(
                theme: buildFahThemeLight(),
                darkTheme: buildFahTheme(),
                themeMode: controller.themeMode,
                locale: const Locale('en'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: FahThemeScope(
                  controller: controller,
                  child: JsAppView(
                    app: JsAppInfo.fromManifest(
                      const {'id': 'themed', 'name': 'Themed'},
                      bundled: false,
                      fallbackId: 'themed',
                    ),
                    env: env,
                    permissionsStore: permissions,
                  ),
                ),
              );
            },
          ),
        );

        // Boot on the dark theme: the accent-colored container appears.
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          if (hasAccentContainer(tester, 0xFF5EEAD4)) return;
        }
      });
      expect(hasAccentContainer(tester, 0xFF5EEAD4), isTrue);

      // Flip to light: didChangeDependencies → engine.updateTheme →
      // jsr._onThemeChange → re-render with the light accent.
      await tester.runAsync(() async {
        await controller.setMode(FahThemeMode.light);
        // MaterialApp wraps home in an AnimatedTheme whose lerp is driven by
        // the fake clock: zero-duration pumps never advance it, so push the
        // clock past the animation before waiting on the JS bridge.
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          if (hasAccentContainer(tester, 0xFF0F766E)) return;
        }
      });
      expect(hasAccentContainer(tester, 0xFF0F766E), isTrue);

      // Unmount the view so the engine is disposed before teardown.
      await tester.runAsync(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
    });
  });

  group('agent message theme line', () {
    testWidgets('forwardAppMessageToAgent appends the Theme line after the '
        'app state', (tester) async {
      String? lastUserText;
      StreamFunction capturingStream() {
        return (model, context, {cancelToken}) {
          final last = context.messages.last;
          final content = (last as UserMessage).content;
          lastUserText = content is String
              ? content
              : [
                  for (final block in content as List<ContentBlock>)
                    if (block is TextContent) block.text,
                ].join();
          final stream = AssistantMessageEventStream();
          final message = AssistantMessage(
            content: [TextContent(text: 'ok')],
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

      final env = MemoryExecutionEnv();
      final manager = FlutterSessionManager(
        env: env,
        sessionsRoot: '/sessions',
      );
      final service = AgentService(
        agent: Agent(
          model: Model(
            id: 'test-model',
            api: 'test-api',
            provider: 'test',
            baseUrl: 'https://example.com',
            contextWindow: 100000,
            maxTokens: 4096,
          ),
          systemPrompt: 'You are Fa.',
          streamFunction: capturingStream(),
          toolRegistry: ToolRegistry(const []),
        ),
        env: env,
        sessionsRoot: '/sessions',
        config: AgentConfig(
          providerKind: 'test',
          modelId: 'test-model',
          baseUrl: 'https://example.com',
          apiKey: '',
        ),
      );
      manager.addSession('original-session', service);

      const themeLine =
          'Theme: dark, bg #070A10, surface #0D1420, text #E8EEF7, '
          'accent #5EEAD4, accent2 #818CF8';
      await tester.runAsync(() async {
        await forwardAppMessageToAgent(
          manager,
          const FaAppMessage(
            text: 'make it pop',
            appId: 'notes',
            appStateJson: '{"count":1}',
            themeLine: themeLine,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });

      expect(lastUserText, isNotNull);
      expect(lastUserText, contains('Current app state:\n```json'));
      expect(lastUserText, contains(themeLine));
      // The Theme line comes after the app-state block.
      expect(
        lastUserText!.indexOf(themeLine),
        greaterThan(lastUserText!.indexOf('```json')),
      );

      for (final session in manager.sessions) {
        session.service.dispose();
      }
    });
  });
}
