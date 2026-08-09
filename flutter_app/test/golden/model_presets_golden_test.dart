/// Golden (screenshot) tests for `lib/ui/screens/model_presets.dart` — the
/// settings "Model presets" wizard: swipeable preset cards with the combo
/// summary, dot indicators, and the Apply action. Fakes mirror
/// `test/golden/settings_golden_test.dart` (in-memory stores, a scripted
/// `AgentService`; no network/file/JS backends are touched).
library;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// A minimal [AgentService] for the section (never connected) — the pattern
/// of `test/golden/settings_golden_test.dart`.
AgentService _fakeService() {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'openai/gpt-4o-mini',
        api: 'test-api',
        provider: 'openai-completions',
        baseUrl: 'https://openrouter.ai/api/v1',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream()..end(),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

/// Pumps the section in the same frame `SettingsScreen` uses (app bar +
/// padded scroll view), centered in a readable max-width column, with a
/// saved OpenRouter key so Apply is enabled (no missing-key warning).
Future<void> _pumpPresetsFrame(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
}) {
  return pumpGolden(
    tester,
    SessionKeysScope(
      store: SessionKeysStore.inMemory({'OPENROUTER_API_KEY': 'sk-or-saved'}),
      child: ModelPresetsSection(
        service: _fakeService(),
        store: MediaModelsStore.inMemory(),
      ),
    ),
    size: goldenSizeDesktop,
    locale: locale,
    wrap: (child) => Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            filledButtonTheme: FilledButtonThemeData(
              style: theme.filledButtonTheme.style?.copyWith(
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          child: Scaffold(
            appBar: AppBar(title: Text(context.l10n.settingsTitle)),
            body: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  group('model presets goldens', () {
    testWidgets('budget preset card', (tester) async {
      await _pumpPresetsFrame(tester);

      // The first card (page 1 of the wizard): name, description, the chat +
      // per-slot combo summary, the enabled Apply, and the first dot active.
      await expectGolden(tester, 'model_presets');
    });

    testWidgets('budget preset card — ru', (tester) async {
      await _pumpPresetsFrame(tester, locale: const Locale('ru'));

      await expectGolden(tester, 'model_presets_ru');
    });

    testWidgets('swiped to the quality preset', (tester) async {
      await _pumpPresetsFrame(tester);
      await tester.drag(find.byType(PageView), const Offset(-400, 0));
      await tester.pumpAndSettle();

      // The second card with the second dot active.
      await expectGolden(tester, 'model_presets_swiped');
    });
  });
}
