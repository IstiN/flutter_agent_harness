// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/compaction_engine_loader.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_key_dialogs.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Deliberately disagree with ColorScheme: a passing assertion proves the
/// control reads the active Fa extension rather than a stock grey/indigo/red
/// or a compatibility-palette coincidence.
ThemeData _tokenTheme(FaVisualDirection direction, Brightness brightness) {
  final base = buildFaTheme(direction: direction, brightness: brightness);
  final tokens = FaDesignTokens.forDirection(direction, brightness);
  final sentinel = tokens.copyWith(
    surface1: const Color(0xFF123456),
    surface2: const Color(0xFF234561),
    ink1: const Color(0xFF101112),
    ink2: const Color(0xFF345612),
    hairline: const Color(0xFF456123),
    accent: const Color(0xFF009988),
    accentInk: const Color(0xFFFEFDFC),
    accentSoft: const Color(0xFFABCDEF),
    danger: const Color(0xFFB00040),
    warning: const Color(0xFFB56A00),
  );
  return base.copyWith(
    extensions: [...base.extensions.values.whereType<FaTypography>(), sentinel],
  );
}

Future<void> _pumpSection(
  WidgetTester tester,
  Widget child,
  ThemeData theme,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _textWithColor(Finder ancestor, Color color) => find.descendant(
  of: ancestor,
  matching: find.byWidgetPredicate(
    (widget) => widget is Text && widget.style?.color == color,
  ),
);

void _expectDialogTokens(WidgetTester tester, FaDesignTokens tokens) {
  final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
  expect(dialog.backgroundColor, tokens.surface1);
  expect(dialog.surfaceTintColor, Colors.transparent);
  final shape = dialog.shape! as RoundedSuperellipseBorder;
  expect(shape.side.color, tokens.hairline);
  expect(shape.borderRadius, BorderRadius.circular(tokens.radiusLg));
}

void main() {
  for (final direction in FaVisualDirection.values) {
    for (final brightness in Brightness.values) {
      final label = '${direction.name}/${brightness.name}';
      final theme = _tokenTheme(direction, brightness);
      final tokens = theme.extension<FaDesignTokens>()!;

      testWidgets(
        'main/shared settings controls use active Fa tokens ($label)',
        (tester) async {
          await _pumpSection(
            tester,
            Column(
              children: [
                ThemeModeSection(controller: ThemeController.inMemory()),
                const CliOnlySettingsSection(),
                HomeGridSection(layoutStore: LauncherLayoutStore.inMemory()),
                const DebugLogsSection(),
              ],
            ),
            theme,
          );

          final themeDropdown = tester.widget<DropdownButton<FahThemeMode>>(
            find.byType(DropdownButton<FahThemeMode>),
          );
          expect(themeDropdown.dropdownColor, tokens.surface2);
          expect(themeDropdown.iconEnabledColor, tokens.ink2);
          expect(
            themeDropdown.borderRadius,
            BorderRadius.circular(tokens.radiusMd),
          );

          expect(
            tester
                .widgetList<Icon>(find.byIcon(Icons.terminal))
                .every((icon) => icon.color == tokens.accent),
            isTrue,
          );
          expect(
            _textWithColor(find.byType(CliOnlySettingsSection), tokens.ink2),
            findsWidgets,
          );

          final gridDropdown = tester.widget<DropdownButton<int?>>(
            find.byType(DropdownButton<int?>),
          );
          expect(gridDropdown.dropdownColor, tokens.surface2);
          expect(gridDropdown.iconEnabledColor, tokens.ink2);
          expect(
            _textWithColor(find.byType(HomeGridSection), tokens.ink2),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byType(DebugLogsSection),
              matching: find.byType(FaIconButton),
            ),
            findsNWidgets(2),
          );
          expect(
            _textWithColor(find.byType(DebugLogsSection), tokens.ink2),
            findsNWidgets(2),
          );
        },
      );

      testWidgets(
        'settings confirmations and secret fields use Fa tokens ($label)',
        (tester) async {
          final store = SessionKeysStore.inMemory({
            'OPENROUTER_API_KEY': 'secret',
          });
          await _pumpSection(tester, KeysSection(store: store), theme);

          await tester.tap(find.byTooltip('Delete'));
          await tester.pumpAndSettle();
          _expectDialogTokens(tester, tokens);
          final delete = tester.widget<FaButton>(
            find.widgetWithText(FaButton, 'Delete'),
          );
          expect(delete.variant, FaButtonVariant.danger);

          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(store.has('OPENROUTER_API_KEY'), isTrue);

          await tester.tap(find.text('Set').first);
          await tester.pumpAndSettle();
          expect(find.byType(KeyEditorDialog), findsOneWidget);
          _expectDialogTokens(tester, tokens);
          final secret = tester.widget<TextField>(find.byType(TextField));
          expect(secret.obscureText, isTrue);
          expect(secret.autofocus, isTrue);
        },
      );

      testWidgets(
        'compaction and queue sections use active Fa tokens ($label)',
        (tester) async {
          await _pumpSection(
            tester,
            Column(
              children: [
                CompactionSection(
                  resolve: ({projectDir, homeDir}) =>
                      const AppCompactionEngineResolution(
                        CompactionEngine.structured,
                        AppCompactionEngineSource.fallback,
                      ),
                ),
                ProviderQueueSection(
                  resolve: ({projectDir, homeDir}) => ProviderQueueResolution(
                    scope: ProviderQueueScope.env,
                    entries: [
                      ProviderQueueEntry(
                        providerType: 'openai-completions',
                        model: 'model-a',
                      ),
                    ],
                    notices: const [],
                  ),
                ),
              ],
            ),
            theme,
          );

          final dropdown = tester.widget<DropdownButton<CompactionEngine>>(
            find.byType(DropdownButton<CompactionEngine>),
          );
          expect(dropdown.dropdownColor, tokens.surface2);
          expect(dropdown.iconEnabledColor, tokens.ink2);
          expect(
            _textWithColor(find.byType(CompactionSection), tokens.ink2),
            findsWidgets,
          );
          expect(
            tester.widget<Icon>(find.byIcon(Icons.cloud_outlined)).color,
            tokens.accent,
          );
          expect(
            _textWithColor(find.byType(ProviderQueueSection), tokens.ink2),
            findsWidgets,
          );
          expect(
            _textWithColor(find.byType(ProviderQueueSection), tokens.warning),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'no-service settings banner uses a Fa token surface ($label)',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: const SettingsScreen(),
            ),
          );
          await tester.pumpAndSettle();

          final bannerText = find.text('Connect a provider to start chatting.');
          final surface = tester.widget<FaSurface>(
            find.ancestor(of: bannerText, matching: find.byType(FaSurface)),
          );
          expect(surface.color, tokens.accentSoft);
          expect(surface.padding, const EdgeInsets.all(16));
          expect(surface.borderRadius, BorderRadius.circular(tokens.radiusMd));
          expect(
            tester.widget<Icon>(find.byIcon(Icons.cloud_outlined).first).color,
            tokens.accent,
          );
        },
      );
    }
  }
}
