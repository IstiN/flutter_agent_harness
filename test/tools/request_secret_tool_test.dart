import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _args = {'name': 'GITHUB_TOKEN', 'reason': 'to push the branch'};

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((block) => block.text).join();

void main() {
  group('schema validation', () {
    final tool = requestSecretTool();

    Map<String, dynamic> validate(Map<String, dynamic> arguments) {
      return validateToolArguments(
        arguments: arguments,
        schema: tool.parameters,
        toolName: 'request_secret',
      );
    }

    test('accepts a name + reason payload', () {
      final validated = validate(Map<String, dynamic>.of(_args));
      expect(validated['name'], 'GITHUB_TOKEN');
    });

    test('rejects a missing name or reason', () {
      expect(
        () => validate(const {'reason': 'r'}),
        throwsA(isA<ToolValidationException>()),
      );
      expect(
        () => validate(const {'name': 'N'}),
        throwsA(isA<ToolValidationException>()),
      );
    });
  });

  group('execution', () {
    test('is a read-tier, sequentially executed tool', () {
      final tool = requestSecretTool();
      expect(tool.name, 'request_secret');
      expect(tool.tier, ApprovalTier.read);
      expect(tool.executionMode, ToolExecutionMode.sequential);
    });

    test('grant resolves with the saved-and-available text', () async {
      final tool = requestSecretTool(
        callback: (name, reason) async {
          expect(name, 'GITHUB_TOKEN');
          expect(reason, 'to push the branch');
          return const RequestSecretResult(
            name: 'GITHUB_TOKEN',
            value: 'ghp_secret-value',
          );
        },
      );
      final result = await tool.execute(_args, null, null);
      expect(
        _text(result),
        'Secret GITHUB_TOKEN saved and available as \$GITHUB_TOKEN.',
      );
    });

    test(
      'grant text reflects the host-adjusted name, never the value',
      () async {
        final tool = requestSecretTool(
          callback: (name, reason) async =>
              const RequestSecretResult(name: 'GH_TOKEN', value: 'ghp_secret'),
        );
        final result = await tool.execute(_args, null, null);
        final text = _text(result);
        expect(text, contains('GH_TOKEN'));
        expect(text, isNot(contains('ghp_secret')));
      },
    );

    test('non-persisted grant says session-only', () async {
      final tool = requestSecretTool(
        callback: (name, reason) async => const RequestSecretResult(
          name: 'GITHUB_TOKEN',
          value: 'ghp_secret',
          persisted: false,
        ),
      );
      final result = await tool.execute(_args, null, null);
      expect(_text(result), contains('this session only'));
    });

    test('decline resolves with the declined text (non-error)', () async {
      final tool = requestSecretTool(callback: (name, reason) async => null);
      final result = await tool.execute(_args, null, null);
      expect(_text(result), 'The user declined to provide GITHUB_TOKEN.');
    });

    test('null callback throws (host cannot prompt)', () {
      final tool = requestSecretTool();
      expect(
        () => tool.execute(_args, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cannot request secrets'),
          ),
        ),
      );
    });

    test('rejects a non-UPPER_SNAKE name', () {
      final tool = requestSecretTool(
        callback: (name, reason) async =>
            RequestSecretResult(name: name, value: 'v'),
      );
      expect(
        () => tool.execute(const {'name': 'lower', 'reason': 'r'}, null, null),
        throwsA(isA<StateError>()),
      );
      expect(
        () => tool.execute(const {'name': '1BAD', 'reason': 'r'}, null, null),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects an empty reason', () {
      final tool = requestSecretTool(
        callback: (name, reason) async =>
            RequestSecretResult(name: name, value: 'v'),
      );
      expect(
        () => tool.execute(
          const {'name': 'GOOD_NAME', 'reason': ' '},
          null,
          null,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
