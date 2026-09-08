import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

void main() {
  group('MockLlmScript.parse (YAML)', () {
    test('parses scenarios, fallback queue and all response kinds', () {
      final script = MockLlmScript.parse('''
model: mock-model
responses:
  - text: fallback hello
scenarios:
  - match: "list the files"
    responses:
      - toolCall:
          name: bash
          arguments: '{"command": "ls"}'
      - toolResultEcho: true
      - text: listed
      - error:
          status: 503
          message: mock outage
  - match: structured args
    responses:
      - toolCall:
          name: write
          arguments:
            path: /tmp/x.txt
            content: hi
''');
      expect(script.model, 'mock-model');
      expect(script.responses, hasLength(1));
      expect(script.responses.single, isA<MockText>());

      expect(script.scenarios, hasLength(2));
      final first = script.scenarios[0];
      expect(first.match, 'list the files');
      expect(first.responses, hasLength(4));
      final toolCall = first.responses[0] as MockToolCall;
      expect(toolCall.name, 'bash');
      expect(toolCall.argumentsJson, '{"command": "ls"}');
      expect(first.responses[1], isA<MockToolResultEcho>());
      expect((first.responses[2] as MockText).text, 'listed');
      final error = first.responses[3] as MockError;
      expect(error.status, 503);
      expect(error.message, 'mock outage');

      // Non-string toolCall arguments are JSON-encoded.
      final structured = script.scenarios[1].responses.single as MockToolCall;
      expect(structured.name, 'write');
      expect(structured.argumentsJson, '{"path":"/tmp/x.txt","content":"hi"}');
    });

    test('parses a JSON document through the same path', () {
      final script = MockLlmScript.parse('''
{
  "model": "json-model",
  "responses": [{"text": "fallback"}],
  "scenarios": [
    {"match": "run it", "responses": [{"toolCall": {"name": "bash", "arguments": "{\\"command\\": \\"echo hi\\"}"}}]}
  ]
}
''');
      expect(script.model, 'json-model');
      expect(script.scenarios.single.match, 'run it');
      final call = script.scenarios.single.responses.single as MockToolCall;
      expect(call.name, 'bash');
      expect(call.argumentsJson, '{"command": "echo hi"}');
    });

    test('defaults: empty document', () {
      final script = MockLlmScript.parse('{}');
      expect(script.model, 'mock-model');
      expect(script.scenarios, isEmpty);
      expect(script.responses, isEmpty);
    });
  });

  group('MockLlmScript.parse validation', () {
    void expectConfigError(String source, String fragment) {
      expect(
        () => MockLlmScript.parse(source),
        throwsA(
          isA<MockLlmConfigException>().having(
            (e) => e.message,
            'message',
            contains(fragment),
          ),
        ),
      );
    }

    test('unknown top-level key', () {
      expectConfigError('respnses:\n  - text: hi', 'unknown key');
    });

    test('unknown scenario key', () {
      expectConfigError(
        'scenarios:\n  - match: x\n    responces:\n      - text: hi',
        'unknown key',
      );
    });

    test('response with two keys', () {
      expectConfigError(
        'responses:\n  - text: hi\n    toolResultEcho: true',
        'exactly one of',
      );
    });

    test('unknown response kind', () {
      expectConfigError('responses:\n  - tooI: oops', 'unknown response kind');
    });

    test('non-string text', () {
      expectConfigError('responses:\n  - text: 42', 'must be a string');
    });

    test('scenario without match', () {
      expectConfigError(
        'scenarios:\n  - responses:\n      - text: hi',
        'match',
      );
    });

    test('toolCall without name', () {
      expectConfigError(
        'responses:\n  - toolCall:\n      arguments: "{}"',
        'name',
      );
    });

    test('toolResultEcho must be boolean', () {
      expectConfigError(
        'responses:\n  - toolResultEcho: yes please',
        'must be a boolean',
      );
    });

    test('error with unknown key', () {
      expectConfigError(
        'responses:\n  - error:\n      status: 503\n      msg: oops',
        'unknown key',
      );
    });

    test('invalid YAML syntax', () {
      expect(
        () => MockLlmScript.parse('a: [unclosed'),
        throwsA(isA<MockLlmConfigException>()),
      );
    });

    test('non-mapping root', () {
      expectConfigError('- just\n- a list', 'document root');
    });
  });
}
