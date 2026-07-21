import 'package:flutter_agent_harness/src/cli/agent_cli.dart';
import 'package:test/test.dart';

void main() {
  group('compactProviderError', () {
    test('unwraps OpenRouter metadata.raw upstream messages', () {
      const blob =
          '429: {"error":{"message":"Provider returned error","code":429,'
          '"metadata":{"raw":"{\\"error\\":{\\"code\\":429,\\"message\\":'
          '\\"You exceeded your current quota, please check your plan and '
          'billing details.\\",\\"status\\":\\"RESOURCE_EXHAUSTED\\"}}",'
          '"provider_name":"Google AI Studio"}}}';
      expect(
        compactProviderError(blob),
        '429: You exceeded your current quota, please check your plan and '
        'billing details. (Google AI Studio)',
      );
    });

    test('falls back to the outer error message without metadata', () {
      const blob =
          '404: {"error":{"message":"No endpoints found that support tool '
          'use.","code":404}}';
      expect(
        compactProviderError(blob),
        '404: No endpoints found that support tool use.',
      );
    });

    test('passes plain text through untouched', () {
      expect(compactProviderError('Connection refused'), 'Connection refused');
    });

    test('caps overly long messages', () {
      final long = 'x' * 400;
      expect(compactProviderError(long).length, 301); // 300 + ellipsis
    });
  });
}
