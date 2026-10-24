// Copyright (c) 2026, the Flutter Agent Harness authors.
// gh-1844: the `decide` tool's Decisions API client — request building,
// response parsing, local validation, and the OpenRouter-only gate.

import 'dart:convert';

import 'package:flutter_agent_harness/src/decisions/decisions.dart';
import 'package:flutter_agent_harness/src/types.dart' show TextContent;
import 'package:flutter_agent_harness/src/tools/decide_tool.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('question wire shapes', () {
    test('bool question serializes type/criteria branches', () {
      const question = DecisionBoolQuestion(
        instructions: 'Is this a defect?',
        criteriaTrue: 'visibly broken',
        criteriaFalse: 'works as designed',
      );
      expect(question.type, 'noul');
      expect(question.toJson(), {
        'type': 'noul',
        'instructions': 'Is this a defect?',
        'criteria': {'true': 'visibly broken', 'false': 'works as designed'},
      });
    });

    test('choice and score questions carry their criteria', () {
      const choice = DecisionChoiceQuestion(
        instructions: 'Pick the severity',
        criteria: {'low': 'cosmetic', 'high': 'blocking'},
      );
      expect(choice.type, 'choice');
      expect(choice.toJson()['criteria'], {
        'low': 'cosmetic',
        'high': 'blocking',
      });
      const score = DecisionScoreQuestion(
        instructions: 'Rate the fix',
        criteria: ['poor', 'good'],
      );
      expect(score.type, 'score');
      expect(score.toJson()['criteria'], ['poor', 'good']);
    });
  });

  group('validateDecisionRequest (gh-1844 CRAP coverage)', () {
    const validQuestions = {
      'isDefect': DecisionBoolQuestion(instructions: 'Is this a defect?'),
      'severity': DecisionChoiceQuestion(
        instructions: 'Severity?',
        criteria: {'low': 'cosmetic'},
      ),
      'quality': DecisionScoreQuestion(
        instructions: 'Quality?',
        criteria: ['poor', 'good'],
      ),
    };

    test('a blank model is a validation failure', () {
      final failure = validateDecisionRequest(
        model: '   ',
        state: 'x',
        questions: validQuestions,
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('model is required'));
      expect(failure.validation, isTrue);
    });

    test('a missing state is a validation failure', () {
      final failure = validateDecisionRequest(
        model: 'm',
        state: null,
        questions: validQuestions,
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('state is required'));
    });

    test('an empty question set is a validation failure', () {
      final failure = validateDecisionRequest(
        model: 'm',
        state: 'x',
        questions: const {},
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('at least one question'));
    });

    test('a blank question name is a validation failure', () {
      final failure = validateDecisionRequest(
        model: 'm',
        state: 'x',
        questions: const {' ': DecisionBoolQuestion(instructions: 'q?')},
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('question names must be non-empty'));
    });

    test('a choice question with empty criteria is a validation failure', () {
      final failure = validateDecisionRequest(
        model: 'm',
        state: 'x',
        questions: const {
          'severity': DecisionChoiceQuestion(
            instructions: 'Severity?',
            criteria: {},
          ),
        },
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('choice question "severity"'));
    });

    test('a score question with empty criteria is a validation failure', () {
      final failure = validateDecisionRequest(
        model: 'm',
        state: 'x',
        questions: const {
          'quality': DecisionScoreQuestion(
            instructions: 'Quality?',
            criteria: [],
          ),
        },
      );
      expect(failure, isNotNull);
      expect(failure!.message, contains('score question "quality"'));
    });

    test('a valid multi-question set passes (null failure)', () {
      expect(
        validateDecisionRequest(
          model: 'inception/mercury-decide:free',
          state: const {'log': 'ok'},
          questions: validQuestions,
        ),
        isNull,
      );
    });
  });

  group('DecisionsAdapter.decide', () {
    const model = 'inception/mercury-decide:free';
    const questions = {
      'isDefect': DecisionBoolQuestion(instructions: 'Is this a defect?'),
      'severity': DecisionChoiceQuestion(
        instructions: 'Severity?',
        criteria: {'low': 'cosmetic', 'high': 'blocking'},
      ),
      'quality': DecisionScoreQuestion(
        instructions: 'Quality?',
        criteria: ['poor', 'good'],
      ),
    };

    test('posts state + questions to {base}/systemone', () async {
      http.Request? seenRequest;
      String? seenBody;
      final adapter = DecisionsAdapter(
        httpClient: MockClient((request) async {
          seenRequest = request;
          seenBody = request.body;
          return http.Response(
            jsonEncode({
              'id': 'gen-1',
              'model': model,
              'provider': 'openrouter',
              'answers': {
                // gh-1844 review: the Decisions API discriminates yes/no
                // questions on `noul` (per the official OpenAPI spec), not
                // `bool`.
                'isDefect': {'type': 'noul', 'noul': 0.9},
                'severity': {
                  'type': 'choice',
                  'choice': 'high',
                  'confidence': 0.8,
                  'probabilities': {'low': 0.1, 'high': 0.9},
                },
                'quality': {
                  'type': 'score',
                  'score': 0.7,
                  'probabilities': {'poor': 0.2, 'good': 0.8},
                },
              },
              'usage': {'input_tokens': 10, 'output_tokens': 5, 'cost': 0.0001},
            }),
            200,
          );
        }),
      );

      final result = await adapter.decide(
        model: model,
        state: {'log': 'boom'},
        questions: questions,
        apiKey: 'or-key',
      );

      expect(result.isSuccess, isTrue);
      final success = result as DecisionSuccess;
      expect(success.id, 'gen-1');
      expect(success.answers['isDefect'], isA<DecisionBoolAnswer>());
      expect(
        (success.answers['isDefect']! as DecisionBoolAnswer).probability,
        0.9,
      );
      final severity = success.answers['severity']! as DecisionChoiceAnswer;
      expect(severity.choice, 'high');
      expect(severity.probabilities['high'], 0.9);
      final quality = success.answers['quality']! as DecisionScoreAnswer;
      expect(quality.score, 0.7);
      expect(success.usage.inputTokens, 10);
      expect(success.usage.cost, 0.0001);

      expect(seenRequest!.method, 'POST');
      expect(
        seenRequest!.url.toString(),
        'https://openrouter.ai/api/v1/systemone',
      );
      expect(seenRequest!.headers['authorization'], 'Bearer or-key');
      final body = jsonDecode(seenBody!) as Map<String, dynamic>;
      expect(body['model'], model);
      expect(body['state'], {'log': 'boom'});
      final wireQuestions = (body['questions'] as Map<String, dynamic>).keys
          .toSet();
      expect(wireQuestions, {'isDefect', 'severity', 'quality'});
    });

    test('a legacy bool-discriminated answer still parses (alias)', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'answers': {
                // Tolerance for pre-noul payloads: the answer key is
                // accepted under the legacy `bool` discriminator too.
                'isDefect': {'type': 'bool', 'bool': 0.6},
              },
            }),
            200,
          ),
        ),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: '[REDACTED:Sensitive Value]',
      );
      final success = result as DecisionSuccess;
      expect(
        (success.answers['isDefect']! as DecisionBoolAnswer).probability,
        0.6,
      );
    });

    test('local validation fails before any network call', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response('unexpected call', 500),
        ),
      );
      final result = await adapter.decide(
        model: ' ',
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: 'k',
      );
      expect(result.isSuccess, isFalse);
      final failure = result as DecisionFailure;
      expect(failure.validation, isTrue);
    });

    test('provider error shape parses into a failure', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'error': {'code': 429, 'message': 'rate limited'},
            }),
            429,
          ),
        ),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: 'k',
      );
      final failure = result as DecisionFailure;
      expect(failure.validation, isFalse);
      expect(failure.statusCode, 429);
      expect(failure.code, 429);
      expect(failure.message, 'rate limited');
    });

    // gh-1844 CRAP gate: the remaining parseDecisionResponse arms — a
    // non-JSON body, a non-object 2xx body, a missing answers object,
    // and a malformed answer entry.
    test('a non-JSON error body degrades to the HTTP status failure', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response('gateway timeout', 504),
        ),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: '[REDACTED:Sensitive Value]',
      );
      final failure = result as DecisionFailure;
      expect(failure.statusCode, 504);
      expect(failure.code, 504);
      expect(failure.message, 'HTTP 504');
    });

    test('a non-object 2xx body is a failure, not a crash', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient((request) async => http.Response('[1, 2]', 200)),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: '[REDACTED:Sensitive Value]',
      );
      final failure = result as DecisionFailure;
      expect(failure.statusCode, 200);
      expect(failure.message, 'decisions response was not a JSON object');
    });

    test('a 2xx body without an answers object is a failure', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response('{"id": "gen-9"}', 200),
        ),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: '[REDACTED:Sensitive Value]',
      );
      final failure = result as DecisionFailure;
      expect(failure.statusCode, 200);
      expect(failure.message, 'decisions response carried no answers object');
    });

    test('a malformed answer entry is a failure naming the question', () async {
      final adapter = DecisionsAdapter(
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'answers': {
                'q': {'type': 'unknown'},
              },
            }),
            200,
          ),
        ),
      );
      final result = await adapter.decide(
        model: model,
        state: 'x',
        questions: const {'q': DecisionBoolQuestion(instructions: 'q?')},
        apiKey: '[REDACTED:Sensitive Value]',
      );
      final failure = result as DecisionFailure;
      expect(failure.statusCode, 200);
      expect(failure.message, contains('decisions answer "q"'));
    });
  });

  group('decideTool', () {
    final questionsArg = {
      'isDefect': {
        'type': 'bool',
        'instructions': 'Is this a defect?',
        'criteria': {'true': 'broken', 'false': 'fine'},
      },
    };

    test('returns the structured success payload', () async {
      final tool = decideTool(
        mainBaseUrl: () => 'https://openrouter.ai/api/v1',
        mainProviderKind: () => 'openrouter',
        mainApiKey: () => 'or-key',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'answers': {
                'isDefect': {'type': 'noul', 'noul': 0.75},
              },
              'usage': {'input_tokens': 3},
            }),
            200,
          ),
        ),
      );

      final result = await tool.execute(
        {
          'model': 'inception/mercury-decide:free',
          'state': 'the widget is broken',
          'questions': questionsArg,
        },
        null,
        null,
      );

      final payload =
          jsonDecode((result.content.first as TextContent).text)
              as Map<String, dynamic>;
      expect(payload['error'], isNull);
      final answers = (payload['answers'] as Map).cast<String, dynamic>();
      expect(answers['isDefect'], {'type': 'noul', 'noul': 0.75});
    });

    test('a non-OpenRouter main connection fails before any call', () async {
      final tool = decideTool(
        mainBaseUrl: () => 'https://api.anthropic.com/v1',
        mainProviderKind: () => 'anthropic',
        mainApiKey: () => 'k',
        httpClient: MockClient(
          (request) async => http.Response('unexpected call', 500),
        ),
      );

      final result = await tool.execute(
        {
          'model': 'inception/mercury-decide:free',
          'state': 'x',
          'questions': questionsArg,
        },
        null,
        null,
      );

      final payload =
          jsonDecode((result.content.first as TextContent).text)
              as Map<String, dynamic>;
      final error = (payload['error'] as Map).cast<String, dynamic>();
      expect(error['validation'], isTrue);
      expect(
        error['message'].toString(),
        contains('main connection provider is "anthropic"'),
      );
    });

    test('a malformed question entry returns a validation failure', () async {
      final tool = decideTool(
        mainBaseUrl: () => 'https://openrouter.ai/api/v1',
        mainProviderKind: () => 'openrouter',
        mainApiKey: () => 'or-key',
      );

      final result = await tool.execute(
        {
          'model': 'inception/mercury-decide:free',
          'state': 'x',
          'questions': {
            'bad': {'type': 'boolean', 'instructions': 'huh?'},
          },
        },
        null,
        null,
      );

      final payload =
          jsonDecode((result.content.first as TextContent).text)
              as Map<String, dynamic>;
      final error = (payload['error'] as Map).cast<String, dynamic>();
      expect(error['validation'], isTrue);
      expect(error['message'].toString(), contains('"bad"'));
    });
    // gh-1844 CRAP gate: _parseQuestion's choice/score arms — the valid
    // shapes and the non-Map / non-List criteria rejections.
    test('parses choice and score question args end to end', () async {
      final tool = decideTool(
        mainBaseUrl: () => 'https://openrouter.ai/api/v1',
        mainProviderKind: () => 'openrouter',
        mainApiKey: () => 'or-key',
        httpClient: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'answers': {
                'team': {
                  'type': 'choice',
                  'choice': 'payments',
                  'probabilities': {'frontend': 0.2, 'payments': 0.8},
                },
                'confidence': {
                  'type': 'score',
                  'score': 0.6,
                  'probabilities': {'low': 0.3, 'high': 0.7},
                },
              },
            }),
            200,
          ),
        ),
      );

      final result = await tool.execute(
        {
          'model': 'inception/mercury-decide:free',
          'state': 'pick a team',
          'questions': {
            'team': {
              'type': 'choice',
              'instructions': 'Which team?',
              'criteria': {'frontend': 'ui', 'payments': 'billing'},
            },
            'confidence': {
              'type': 'score',
              'instructions': 'How confident?',
              'criteria': ['low', 'high'],
            },
          },
        },
        null,
        null,
      );

      final payload =
          jsonDecode((result.content.first as TextContent).text)
              as Map<String, dynamic>;
      expect(payload['error'], isNull);
      final answers = (payload['answers'] as Map).cast<String, dynamic>();
      expect(answers['team'], containsPair('choice', 'payments'));
      expect(answers['confidence'], containsPair('score', 0.6));
    });

    test(
      'a choice question with non-map criteria is a validation failure',
      () async {
        final tool = decideTool(
          mainBaseUrl: () => 'https://openrouter.ai/api/v1',
          mainProviderKind: () => 'openrouter',
          mainApiKey: () => 'or-key',
        );

        final result = await tool.execute(
          {
            'model': 'inception/mercury-decide:free',
            'state': 'x',
            'questions': {
              'team': {
                'type': 'choice',
                'instructions': 'Which team?',
                'criteria': ['frontend', 'payments'],
              },
            },
          },
          null,
          null,
        );

        final payload =
            jsonDecode((result.content.first as TextContent).text)
                as Map<String, dynamic>;
        final error = (payload['error'] as Map).cast<String, dynamic>();
        expect(error['validation'], isTrue);
        expect(error['message'].toString(), contains('"team"'));
      },
    );

    test(
      'a score question with non-list criteria is a validation failure',
      () async {
        final tool = decideTool(
          mainBaseUrl: () => 'https://openrouter.ai/api/v1',
          mainProviderKind: () => 'openrouter',
          mainApiKey: () => 'or-key',
        );

        final result = await tool.execute(
          {
            'model': 'inception/mercury-decide:free',
            'state': 'x',
            'questions': {
              'confidence': {
                'type': 'score',
                'instructions': 'How confident?',
                'criteria': {'low': 'a', 'high': 'b'},
              },
            },
          },
          null,
          null,
        );

        final payload =
            jsonDecode((result.content.first as TextContent).text)
                as Map<String, dynamic>;
        final error = (payload['error'] as Map).cast<String, dynamic>();
        expect(error['validation'], isTrue);
        expect(error['message'].toString(), contains('"confidence"'));
      },
    );
  });
}
