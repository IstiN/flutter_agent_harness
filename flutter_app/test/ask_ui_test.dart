import 'package:flutter/material.dart';
import 'package:fa/agent_service.dart';
import 'package:fa/ask_ui.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Pumps a button that opens the ask sheet and completes [result].
Future<void> _pumpOpener(
  WidgetTester tester, {
  required List<AskQuestion> questions,
  required void Function(List<AskAnswer>?) onResult,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              onResult(await showAskSheet(context, questions));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

FilledButton _answerButton(WidgetTester tester, [String label = 'Answer']) {
  return tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));
}

void main() {
  group('AskSheet', () {
    testWidgets('renders the question, options, and recommended badge', (
      tester,
    ) async {
      await _pumpOpener(tester, questions: [_singleQuestion], onResult: (_) {});
      await _openSheet(tester);

      expect(find.text('Which auth method?'), findsOneWidget);
      expect(find.text('JWT'), findsOneWidget);
      expect(find.text('Bearer tokens for stateless APIs.'), findsOneWidget);
      expect(find.text('OAuth2'), findsOneWidget);
      expect(find.text('Recommended'), findsOneWidget);
      expect(find.text('Other (type your own)'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      // Nothing selected yet: the Answer button is disabled.
      expect(_answerButton(tester).onPressed, isNull);
    });

    testWidgets('single select resolves the picked label', (tester) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [_singleQuestion],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      await tester.tap(find.text('OAuth2'));
      await tester.pumpAndSettle();
      expect(_answerButton(tester).onPressed, isNotNull);
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result, isNotNull);
      expect(result!.single.selected, ['OAuth2']);
      expect(result!.single.freeText, isNull);
    });

    testWidgets('multi select resolves every checked label', (tester) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [_multiQuestion],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Gamma'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result!.single.selected, ['Alpha', 'Gamma']);
      expect(result!.single.freeText, isNull);
    });

    testWidgets('multi select keeps an Other note next to the picks', (
      tester,
    ) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [_multiQuestion],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      await tester.tap(find.text('Beta'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'plus webhooks');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result!.single.selected, ['Beta']);
      expect(result!.single.freeText, 'plus webhooks');
    });

    testWidgets('Other resolves the typed free text (single select)', (
      tester,
    ) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [_singleQuestion],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      await tester.tap(find.text('Other (type your own)'));
      await tester.pumpAndSettle();
      // Still disabled while the Other field is empty.
      expect(_answerButton(tester).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'use mTLS');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result!.single.selected, isEmpty);
      expect(result!.single.freeText, 'use mTLS');
    });

    testWidgets('a free-form question (no options) takes typed text', (
      tester,
    ) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [const AskQuestion(question: 'Anything else?')],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      expect(find.byType(RadioListTile<int>), findsNothing);
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(_answerButton(tester).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'ship on Friday');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result!.single.freeText, 'ship on Friday');
    });

    testWidgets('Cancel resolves null (ask cancelled by user)', (tester) async {
      var called = false;
      List<AskAnswer>? result = [];
      await _pumpOpener(
        tester,
        questions: [_singleQuestion],
        onResult: (r) {
          called = true;
          result = r;
        },
      );
      await _openSheet(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(called, isTrue);
      expect(result, isNull);
    });

    testWidgets('dismissing the sheet resolves null (safe default)', (
      tester,
    ) async {
      List<AskAnswer>? result = [];
      await _pumpOpener(
        tester,
        questions: [_singleQuestion],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      // Tap the barrier above the sheet.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(result, isNull);
    });

    testWidgets('multiple questions page with Back and collect in order', (
      tester,
    ) async {
      List<AskAnswer>? result;
      await _pumpOpener(
        tester,
        questions: [
          const AskQuestion(
            question: 'Which storage?',
            options: [
              AskOption(label: 'SQLite'),
              AskOption(label: 'PostgreSQL'),
            ],
          ),
          const AskQuestion(
            question: 'Which cache?',
            options: [
              AskOption(label: 'memory'),
              AskOption(label: 'redis'),
            ],
          ),
        ],
        onResult: (r) => result = r,
      );
      await _openSheet(tester);
      expect(find.text('Question 1 of 2'), findsOneWidget);
      await tester.tap(find.text('PostgreSQL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.text('Question 2 of 2'), findsOneWidget);
      // Back preserves the first answer's draft.
      await tester.tap(find.text('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Question 1 of 2'), findsOneWidget);
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('memory'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Answer'));
      await tester.pumpAndSettle();
      expect(result, hasLength(2));
      expect(result![0].selected, ['PostgreSQL']);
      expect(result![1].selected, ['memory']);
    });
  });

  group('AgentService ask wiring', () {
    test('registers the ask tool and delegates to askHandler', () async {
      final service = await AgentService.create(
        config: AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'test-model',
          baseUrl: 'https://example.test',
          apiKey: 'test-key',
        ),
        env: MemoryExecutionEnv(),
      );
      addTearDown(service.dispose);
      final ask = service.toolsForTest.whereType<AgentTool>().singleWhere(
        (tool) => tool.name == 'ask',
      );
      const args = {
        'questions': [
          {
            'question': 'proceed?',
            'options': [
              {'label': 'yes'},
              {'label': 'no'},
            ],
          },
        ],
      };
      String textOf(ToolExecutionResult result) => result.content
          .whereType<TextContent>()
          .map((block) => block.text)
          .join();

      // No handler installed: the call resolves as cancelled (safe default).
      final cancelled = await ask.execute(args, null, null);
      expect(textOf(cancelled), contains('cancelled'));

      // An installed handler receives the parsed questions.
      service.askHandler = (questions) async {
        expect(questions.single.question, 'proceed?');
        return [
          const AskAnswer.selection(['yes']),
        ];
      };
      final answered = await ask.execute(args, null, null);
      expect(textOf(answered), 'User selected: yes');
    });
  });
}
