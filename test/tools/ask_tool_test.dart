import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

Map<String, dynamic> _singleQuestionArgs({
  bool multiSelect = false,
  Object? recommended = 0,
}) {
  return {
    'questions': [
      {
        'question': 'Which auth method?',
        'options': [
          {'label': 'JWT', 'description': 'Bearer tokens for stateless APIs.'},
          {'label': 'OAuth2'},
          {'label': 'Session cookies'},
        ],
        if (multiSelect) 'multiSelect': true,
        'recommended': ?recommended,
      },
    ],
  };
}

Map<String, dynamic> _multiQuestionArgs() {
  return {
    'questions': [
      {
        'question': 'Which storage backend?',
        'options': [
          {'label': 'SQLite'},
          {'label': 'PostgreSQL'},
        ],
      },
      {
        'question': 'Which features?',
        'options': [
          {'label': 'Alpha'},
          {'label': 'Beta'},
          {'label': 'Gamma'},
        ],
        'multiSelect': true,
      },
      {'question': 'Anything else?'},
    ],
  };
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((block) => block.text).join();

void main() {
  group('schema validation', () {
    final tool = askTool();

    Map<String, dynamic> validate(Map<String, dynamic> arguments) {
      return validateToolArguments(
        arguments: arguments,
        schema: tool.parameters,
        toolName: 'ask',
      );
    }

    test('accepts a multi-question payload with all field kinds', () {
      final validated = validate({
        'questions': [
          {
            'question': 'Which auth method?',
            'options': [
              {'label': 'JWT', 'description': 'Bearer tokens'},
              {'label': 'OAuth2'},
            ],
            'multiSelect': false,
            'recommended': 0,
          },
          {
            'question': 'Which features?',
            'options': [
              {'label': 'Alpha'},
              {'label': 'Beta'},
            ],
            'multiSelect': true,
            'recommended': 'Beta',
          },
          {'question': 'Anything else?'},
        ],
      });
      expect(validated['questions'], hasLength(3));
    });

    test('rejects a missing questions list', () {
      expect(() => validate(const {}), throwsA(isA<ToolValidationException>()));
    });

    test('rejects a question without text', () {
      expect(
        () => validate({
          'questions': [
            {
              'options': [
                {'label': 'a'},
              ],
            },
          ],
        }),
        throwsA(isA<ToolValidationException>()),
      );
    });

    test('rejects an option without a label', () {
      expect(
        () => validate({
          'questions': [
            {
              'question': 'q',
              'options': [
                {'description': 'no label'},
              ],
            },
          ],
        }),
        throwsA(isA<ToolValidationException>()),
      );
    });

    test('rejects non-object question entries', () {
      expect(
        () => validate({
          'questions': ['just a string'],
        }),
        throwsA(isA<ToolValidationException>()),
      );
    });

    test('coerces scalar fields like other tools', () {
      final validated = validate({
        'questions': [
          {'question': 'q', 'multiSelect': 'true', 'recommended': 1},
        ],
      });
      final question = (validated['questions'] as List).single;
      expect(question['multiSelect'], isTrue);
      expect(question['recommended'], 1);
    });
  });

  group('execute', () {
    test('a null callback throws (error tool result for the model)', () {
      final tool = askTool();
      expect(
        () => tool.execute(_singleQuestionArgs(), null, null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('cannot answer questions'),
          ),
        ),
      );
    });

    test('an empty questions list throws', () {
      final tool = askTool(callback: (questions) async => []);
      expect(
        () => tool.execute(const {'questions': <void>[]}, null, null),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('non-empty'),
          ),
        ),
      );
    });

    test('single-select answer maps to "User selected"', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [
            const AskAnswer.selection(['OAuth2']),
          ];
        },
      );
      final result = await tool.execute(_singleQuestionArgs(), null, null);
      expect(_text(result), 'User selected: OAuth2');
      final question = seen.single;
      expect(question.question, 'Which auth method?');
      expect(question.options.map((o) => o.label), [
        'JWT',
        'OAuth2',
        'Session cookies',
      ]);
      expect(question.options[0].description, contains('Bearer tokens'));
      expect(question.multiSelect, isFalse);
      expect(question.recommended, 0);
    });

    test('multi-select answer joins the labels', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [
            const AskAnswer.selection(['JWT', 'OAuth2']),
          ];
        },
      );
      final result = await tool.execute(
        _singleQuestionArgs(multiSelect: true),
        null,
        null,
      );
      expect(_text(result), 'User selected: JWT, OAuth2');
      expect(seen.single.multiSelect, isTrue);
    });

    test('free-text answer maps to "User provided custom input"', () async {
      final tool = askTool(
        callback: (questions) async => [const AskAnswer.text('use mTLS')],
      );
      final result = await tool.execute(_singleQuestionArgs(), null, null);
      expect(_text(result), 'User provided custom input: use mTLS');
    });

    test('multiline free text is indented like omp', () async {
      final tool = askTool(
        callback: (questions) async => [
          const AskAnswer.text('line one\nline two'),
        ],
      );
      final result = await tool.execute(_singleQuestionArgs(), null, null);
      expect(
        _text(result),
        'User provided custom input:\n  line one\n  line two',
      );
    });

    test('selection plus free text both appear', () async {
      final tool = askTool(
        callback: (questions) async => [
          const AskAnswer(selected: ['JWT'], freeText: 'with refresh rotation'),
        ],
      );
      final result = await tool.execute(_singleQuestionArgs(), null, null);
      expect(
        _text(result),
        'User selected: JWT\nUser provided custom input: with refresh rotation',
      );
    });

    test('a recommended label resolves to an index', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [
            const AskAnswer.selection(['JWT']),
          ];
        },
      );
      await tool.execute(
        _singleQuestionArgs(recommended: 'OAuth2'),
        null,
        null,
      );
      expect(seen.single.recommended, 1);
    });

    test('an out-of-range recommended index is ignored', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [
            const AskAnswer.selection(['JWT']),
          ];
        },
      );
      await tool.execute(_singleQuestionArgs(recommended: 9), null, null);
      expect(seen.single.recommended, isNull);
    });

    test('an unknown recommended label is ignored', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [
            const AskAnswer.selection(['JWT']),
          ];
        },
      );
      await tool.execute(_singleQuestionArgs(recommended: 'mTLS'), null, null);
      expect(seen.single.recommended, isNull);
    });

    test('a free-form question passes an empty option list', () async {
      final seen = <AskQuestion>[];
      final tool = askTool(
        callback: (questions) async {
          seen.addAll(questions);
          return [const AskAnswer.text('nothing more')];
        },
      );
      final result = await tool.execute(
        const {
          'questions': [
            {'question': 'Anything else?'},
          ],
        },
        null,
        null,
      );
      expect(seen.single.options, isEmpty);
      expect(_text(result), 'User provided custom input: nothing more');
    });

    test('multi-question answers use the "User answers:" format', () async {
      final tool = askTool(
        callback: (questions) async => [
          const AskAnswer.selection(['SQLite']),
          const AskAnswer.selection(['Alpha', 'Gamma']),
          const AskAnswer.text('ship it Friday'),
        ],
      );
      final result = await tool.execute(_multiQuestionArgs(), null, null);
      expect(
        _text(result),
        'User answers:\n'
        '1. Which storage backend?: SQLite\n'
        '2. Which features?: [Alpha, Gamma]\n'
        '3. Anything else?: "ship it Friday"',
      );
    });

    test('missing answers become (no answer) lines', () async {
      final tool = askTool(
        callback: (questions) async => [
          const AskAnswer.selection(['SQLite']),
        ],
      );
      final result = await tool.execute(_multiQuestionArgs(), null, null);
      expect(
        _text(result),
        'User answers:\n'
        '1. Which storage backend?: SQLite\n'
        '2. Which features?: (no answer)\n'
        '3. Anything else?: (no answer)',
      );
    });

    test('an unanswered single question reports as such', () async {
      final tool = askTool(callback: (questions) async => []);
      final result = await tool.execute(_singleQuestionArgs(), null, null);
      expect(_text(result), 'The user did not answer the question.');
    });

    test(
      'a null callback result is a cancelled result, not an error',
      () async {
        final tool = askTool(callback: (questions) async => null);
        final result = await tool.execute(_singleQuestionArgs(), null, null);
        expect(_text(result), contains('cancelled'));
      },
    );

    test('a pre-cancelled token throws before invoking the callback', () {
      var invoked = false;
      final source = CancelTokenSource()..cancel();
      final tool = askTool(
        callback: (questions) async {
          invoked = true;
          return [];
        },
      );
      expect(
        () => tool.execute(_singleQuestionArgs(), source.token, null),
        throwsA(isA<CancelledException>()),
      );
      expect(invoked, isFalse);
    });

    test('cancelling mid-wait unwinds with CancelledException', () async {
      final source = CancelTokenSource();
      final tool = askTool(
        callback: (questions) {
          source.cancel();
          // The host never answers (its UI is being torn down).
          return Completer<List<AskAnswer>?>().future;
        },
      );
      await expectLater(
        tool.execute(_singleQuestionArgs(), source.token, null),
        throwsA(isA<CancelledException>()),
      );
    });

    test('runs its tool batch sequentially (omp exclusive)', () {
      final tool = askTool();
      expect(tool.executionMode, ToolExecutionMode.sequential);
      expect(tool.tier, ApprovalTier.read);
    });
  });
}
