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
      expect(question.type, 'bool');
      expect(
        question.toJson(),
        {
          'type': 'bool',
          'instructions': 'Is this a defect?',
          'criteria': {
            'true': 'visibly broken',
            'false': 'works as designed',
          },
        },
      );
    });

    test('choice and score questions carry their criteria', () {
      const choice = DecisionChoiceQuestion(
        instructions: 'Pick the severity',
        criteria: {'low': 'cosmetic', 'high': 'blocking'},
      );
      expect(choice.type, 'choice');
      expect(
        choice.toJson()['criteria'],
        {'low': 'cosmetic', 'high': 'blocking'},
      );
      const score = DecisionScoreQuestion(
        instructions: 'Rate the fix',
        criteria: ['poor', 'good'],
      );
      expect(score.type, 'score');
      expect(score.toJson()['criteria'], ['poor', 'good']);
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
          seenRequest = request as http.Request;
          seenBody = request.body;
          return http.Response(
            jsonEncode({
              'id': 'gen-1',
              'model': model,
              'provider': 'openrouter',
              'answers': {
                'isDefect': {'type': 'bool', 'bool': 0.9},
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
              'usage': {
                'input_tokens': 10,
                'output_tokens': 5,
                'cost': 0.0001,
              },
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
      final wireQuestions =
          (body['questions'] as Map<String, dynamic>).keys.toSet();
      expect(wireQuestions, {'isDefect', 'severity', 'quality'});
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
                'isDefect': {'type': 'bool', 'bool': 0.75},
              },
              'usage': {'input_tokens': 3},
            }),
            200,
          ),
        ),
      );

      final result = await tool.execute({
        'model': 'inception/mercury-decide:free',
        'state': 'the widget is broken',
        'questions': questionsArg,
      }, null, null);

      final payload =
          jsonDecode((result.content.first as TextContent).text!) as Map<String, dynamic>;
      expect(payload['error'], isNull);
      final answers = (payload['answers'] as Map).cast<String, dynamic>();
      expect(answers['isDefect'], {'type': 'bool', 'bool': 0.75});
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

      final result = await tool.execute({
        'model': 'inception/mercury-decide:free',
        'state': 'x',
        'questions': questionsArg,
      }, null, null);

      final payload =
          jsonDecode((result.content.first as TextContent).text!) as Map<String, dynamic>;
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

      final result = await tool.execute({
        'model': 'inception/mercury-decide:free',
        'state': 'x',
        'questions': {
          'bad': {'type': 'boolean', 'instructions': 'huh?'},
        },
      }, null, null);

      final payload =
          jsonDecode((result.content.first as TextContent).text!) as Map<String, dynamic>;
      final error = (payload['error'] as Map).cast<String, dynamic>();
      expect(error['validation'], isTrue);
      expect(error['message'].toString(), contains('"bad"'));
    });
  });
}
