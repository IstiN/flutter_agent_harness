/// Golden (screenshot) tests for the modal dialog surfaces:
/// `lib/approval_ui.dart` (approval dialog + mode selector) and
/// `lib/ask_ui.dart` (ask sheet). Fakes/builders mirror
/// `test/approval_ui_test.dart` and `test/ask_ui_test.dart`; the modals
/// overlay a realistic chat frame so the shots read as product screenshots.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/widgets/approval_ui.dart';
import 'package:fa/ui/widgets/ask_ui.dart';
import 'package:fa/ui/screens/settings_key_dialogs.dart';
import 'package:fa/ui/widgets/rename_session_dialog.dart';
import 'package:fa/ui/widgets/secret_request_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Material icons (check marks, app-bar actions) come from the SDK-bundled
/// MaterialIcons font, which flutter_test does not load on its own — without
/// this they render as hollow boxes.
Future<void> _ensureIconFont() async {
  final loader = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await loader.load();
}

/// The real app theme with one test-only patch: the theme's
/// FilledButton/ElevatedButton `styleFrom(textStyle:)` carries a
/// family-less `TextStyle(fontWeight: w600)`, and Material applies it
/// terminally (no merge with the ambient default), so in flutter_test the
/// button labels would fall back to the placeholder boxes. Pinning the
/// family to Inter keeps the labels legible; the weight/shape/colors are
/// untouched.
ThemeData _goldenTheme() {
  const interW600 = TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600);
  ButtonStyle withInterLabels(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: const WidgetStatePropertyAll(interW600),
      );
  final base = buildFahTheme();
  return base.copyWith(
    filledButtonTheme: FilledButtonThemeData(
      style: withInterLabels(base.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: withInterLabels(base.elevatedButtonTheme.style),
    ),
  );
}

/// pumpGolden's twin with [_goldenTheme]: the modal routes under test are
/// pushed above `home`, so a theme override must live on the MaterialApp
/// itself (pumpGolden's `wrap` cannot reach dialogs/sheets).
Future<void> _pumpDialogHost(
  WidgetTester tester,
  Widget child, {
  Locale locale = const Locale('en'),
}) async {
  tester.view.physicalSize = goldenSizeDesktop;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _goldenTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

const _request = ApprovalRequest(
  toolName: 'bash',
  tier: ApprovalTier.exec,
  arguments: {'command': 'rm -rf /'},
  reason: 'Critical pattern detected: recursive delete from a root path',
);

AgentService _service() {
  final agent = Agent(
    model: Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test',
      baseUrl: 'https://example.com',
      contextWindow: 100000,
      maxTokens: 4096,
    ),
    streamFunction: (model, context, {cancelToken}) {
      final stream = AssistantMessageEventStream();
      stream.push(
        DoneEvent(
          reason: StopReason.stop,
          message: AssistantMessage(
            content: const [],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        ),
      );
      stream.end();
      return stream;
    },
    toolRegistry: ToolRegistry(builtinTools(MemoryExecutionEnv())),
  );
  return AgentService(
    agent: agent,
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

const _singleQuestion = AskQuestion(
  question: 'Which auth method?',
  options: [
    AskOption(label: 'JWT', description: 'Bearer tokens for stateless APIs.'),
    AskOption(label: 'OAuth2'),
    AskOption(label: 'Session cookies'),
  ],
  recommended: 0,
);

const _multiQuestion = AskQuestion(
  question: 'Which features?',
  options: [
    AskOption(label: 'Alpha'),
    AskOption(label: 'Beta'),
    AskOption(label: 'Gamma'),
  ],
  multiSelect: true,
);

/// A static, deterministic chat frame the modals overlay: an app bar and a
/// short transcript whose narrative leads into the approval prompt. Nothing
/// here animates or reads the clock.
class _ChatHost extends StatefulWidget {
  const _ChatHost({required this.open});

  /// Opens the modal under test; fired once after the first frame.
  final Future<void> Function(BuildContext context) open;

  @override
  State<_ChatHost> createState() => _ChatHostState();
}

class _ChatHostState extends State<_ChatHost> {
  var _opened = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_opened || !mounted) return;
      _opened = true;
      widget.open(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('flutter_agent'),
        actions: [
          IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
          IconButton(onPressed: () {}, icon: const Icon(Icons.settings)),
        ],
      ),
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Card(
                      color: theme.colorScheme.primaryContainer,
                      child: const Padding(
                        padding: EdgeInsets.all(12),
                        child: Text(
                          'Delete the build artifacts to free some disk '
                          'space.',
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'I\u2019ll remove the build directory. This is '
                              'a destructive shell command, so I need your '
                              'approval first.',
                            ),
                            const SizedBox(height: 8),
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color:
                                    theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                r'$ rm -rf /',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontFamily: 'JetBrainsMono',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Pumps the desktop chat frame, then lets it open the modal under test and
/// settles the entry animation.
Future<void> _pumpOpened(
  WidgetTester tester,
  Future<void> Function(BuildContext context) open, {
  Locale locale = const Locale('en'),
}) async {
  await _pumpDialogHost(tester, _ChatHost(open: open), locale: locale);
  await tester.pumpAndSettle();
}

/// Opens a settings-style dialog hosting the approval mode selector.
Future<void> _openSettings(BuildContext context, AgentService service) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Settings', style: theme.textTheme.titleLarge),
                const SizedBox(height: 16),
                ApprovalModeSelector(service: service),
              ],
            ),
          ),
        ),
      );
    },
  );
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureIconFont();
  });

  group('dialogs goldens', () {
    testWidgets('approval dialog: bash tool, tier line, three buttons', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showApprovalPrompt(context, _request),
      );
      await expectGolden(tester, 'dialogs_approval');
    });

    testWidgets('approval mode selector: default write mode', (tester) async {
      final service = _service();
      addTearDown(service.dispose);
      await _pumpOpened(tester, (context) => _openSettings(context, service));
      await expectGolden(tester, 'dialogs_approval_mode');
    });

    testWidgets('ask sheet: labeled options with a recommended one', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showAskSheet(context, [_singleQuestion]),
      );
      await expectGolden(tester, 'dialogs_ask_options');
    });

    testWidgets('ask sheet: multi-select with checked options', (tester) async {
      await _pumpOpened(
        tester,
        (context) => showAskSheet(context, [_multiQuestion]),
      );
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gamma'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'dialogs_ask_multi');
    });

    testWidgets('secret request sheet: prefilled name, entered value', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showSecretRequestSheet(
          context,
          'GITHUB_TOKEN',
          'I need a GitHub token to push the branch and open the pull '
              'request. Create a fine-grained token with repo access.',
        ),
      );
      await tester.enterText(find.byType(TextField).at(1), 'ghp_golden-value');
      await tester.pumpAndSettle();
      await expectGolden(tester, 'dialogs_secret_request');
    });

    testWidgets('secret request sheet: russian locale', (tester) async {
      await _pumpOpened(
        tester,
        (context) => showSecretRequestSheet(
          context,
          'OPENAI_API_KEY',
          'Мне нужен ключ OpenAI, чтобы перегенерировать иллюстрации '
              'для отчёта.',
        ),
        locale: const Locale('ru'),
      );
      await expectGolden(tester, 'dialogs_secret_request_ru');
    });

    testWidgets('settings key editor dialog', (tester) async {
      await _pumpOpened(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (_) =>
              const KeyEditorDialog(title: 'Set OPENROUTER_API_KEY'),
        ),
      );
      await expectGolden(tester, 'dialogs_key_editor');
    });

    testWidgets('settings add key dialog', (tester) async {
      await _pumpOpened(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (_) => AddKeyDialog(isDuplicate: (_) => false),
        ),
      );
      await expectGolden(tester, 'dialogs_add_key');
    });

    testWidgets('rename session dialog: prefilled custom title', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (_) => const RenameSessionDialog(
            initialTitle: "Makar's week",
            derivedName: 'Aug 1 21:30',
          ),
        ),
      );
      await expectGolden(tester, 'dialogs_rename_session');
    });

    testWidgets('rename session dialog: russian, derived-name hint', (
      tester,
    ) async {
      await _pumpOpened(
        tester,
        (context) => showDialog<void>(
          context: context,
          builder: (_) => const RenameSessionDialog(
            initialTitle: '',
            derivedName: '1 авг. 21:30',
          ),
        ),
        locale: const Locale('ru'),
      );
      await expectGolden(tester, 'dialogs_rename_session_ru');
    });
  });
}
