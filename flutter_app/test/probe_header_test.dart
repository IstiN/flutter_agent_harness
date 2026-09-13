// Throwaway probe (issue #225 debugging): pumps the sheet, opens the
// panel, prints whether the adaptive header and its ⋮ render.
import 'package:fa/apps/session_chat_sheet.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa_ui/fa_ui.dart' show FaAdaptiveHeader;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('probe: panel header contains the overflow menu', (tester) async {
    final env = MemoryExecutionEnv();
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
        streamFunction: (model, context, {cancelToken}) {
          final stream = AssistantMessageEventStream();
          stream.end();
          return stream;
        },
        toolRegistry: ToolRegistry(const []),
      ),
      watchExternalSessions: false,
      env: env,
      sessionsRoot: '/sessions',
      config: AgentConfig(
        providerKind: 'test',
        modelId: 'test-model',
        baseUrl: 'https://example.com',
        apiKey: '',
      ),
    );
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('sess', service);
    await tester.pumpWidget(MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SessionChatSheet(manager: manager),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sessionChatDrawerButton')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('sessionChatDrawerEntry:sess')));
    await tester.pumpAndSettle();
    debugPrint('panel count: '
        '${find.byKey(const ValueKey('sessionChatPanel')).evaluate().length}');
    debugPrint('header count: '
        '${find.byType(FaAdaptiveHeader).evaluate().length}');
    final headerWidget =
        tester.widget<FaAdaptiveHeader>(find.byType(FaAdaptiveHeader));
    debugPrint('menuItems len: ${headerWidget.menuItems.length}');
    debugPrint('actions len: ${headerWidget.actions.length}');
    debugPrint(
        'more_vert: ${find.byIcon(Icons.more_vert).evaluate().length}');
    debugPrint(
        'popup buttons: ${find.byType(PopupMenuButton<dynamic>).evaluate().length}');
    debugPrint('timeline icons: '
        '${find.byIcon(Icons.timeline).evaluate().length}');
    debugPrint('apps icons: ${find.byIcon(Icons.apps).evaluate().length}');
  });
}
