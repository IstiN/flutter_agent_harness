import 'package:flutter/material.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _tapConnect(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pump();
}

void main() {
  group('endpoint-reported model limits', () {
    Future<void> pumpWithModels(
      WidgetTester tester,
      ModelsEndpointInfo info,
      ValueSetter<AgentConfig> captured,
    ) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentSettingsForm(
                registry: ProviderRegistry.inMemory(),
                modelsFetcher: (baseUrl, {required apiKey}) async => info,
                onConnect: (config) async => captured(config),
              ),
            ),
          ),
        ),
      );
    }

    Future<void> connectWith(
      WidgetTester tester, {
      required String model,
      String key = 'sk-x',
    }) async {
      await tester.enterText(find.widgetWithText(TextField, 'API key'), key);
      await tester.enterText(find.widgetWithText(TextField, 'Model id'), model);
      await _tapConnect(tester, 'Start chat');
    }

    testWidgets('the /models limits land in the connect config', (
      tester,
    ) async {
      AgentConfig? config;
      await pumpWithModels(tester, (
        ['m-big'],
        {'m-big': 262144},
        {'m-big': 65536},
      ), (c) => config = c);
      // Let the debounced fetch land.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await connectWith(tester, model: 'm-big');

      expect(config, isNotNull);
      expect(config!.contextWindow, 262144);
      expect(config!.maxTokens, 65536);
    });

    testWidgets('unreported models fall back to the shared floor', (
      tester,
    ) async {
      AgentConfig? config;
      await pumpWithModels(tester, (
        const <String>[],
        const <String, int>{},
        const <String, int>{},
      ), (c) => config = c);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();

      await connectWith(tester, model: 'm-unknown');

      expect(config, isNotNull);
      expect(config!.contextWindow, fallbackContextWindow);
      expect(config!.maxTokens, fallbackMaxTokens);
    });
  });
}
