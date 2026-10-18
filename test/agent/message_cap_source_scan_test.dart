// gh-1680 UT-3 / AC5 / REG-1 — the no-hardcode source scan: no provider
// or model identity appears anywhere in the repair path (the only
// built-in knowledge is the error-text classifier), and no incident cap
// value is compiled into the store/coalesce module.

import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('gh-1680 no-hardcode source scan (AC5)', () {
    // The repair path: the learned-cap store + coalesce (new module), the
    // loop's heal, and the compactor's trigger. overflow.dart (the
    // classifier) is deliberately EXCLUDED — its documented provider
    // example list is the pre-existing pi port, and the classifier is the
    // one allowed built-in.
    const repairPathFiles = [
      'lib/src/agent/message_cap.dart',
      'lib/src/agent/agent_loop.dart',
      'lib/src/agent/auto_compactor.dart',
    ];

    // Provider/model identities from the incident and the wider fleet.
    // None of these may appear in the repair path (any case, any
    // substring).
    const bannedIdentities = [
      'joingonka',
      'glm',
      'z.ai',
      'zai-org',
      '01a14b3a',
      'dmtools-factory',
      'openai',
      'anthropic',
      'gemini',
      'claude',
      'gpt-',
      'llama',
      'mistral',
      'qwen',
      'deepseek',
      'groq',
      'bedrock',
    ];

    // The incident-specific identities must appear NOWHERE in the repair
    // path — these are the names a hardcoded table would use.
    const bannedIncidentIdentities = [
      'joingonka',
      'glm',
      'z.ai',
      'zai-org',
      '01a14b3a',
      'dmtools-factory',
    ];

    test('no incident provider/model identity in the repair path', () {
      for (final path in repairPathFiles) {
        final text = File(path).readAsStringSync().toLowerCase();
        for (final identity in bannedIncidentIdentities) {
          expect(
            text.contains(identity),
            isFalse,
            reason:
                '$path must not hardcode "$identity" — the cap is '
                'learned from the error text, never tabulated (AC5)',
          );
        }
      }
    });

    test('the new store/coalesce module carries no provider identity at '
        'all', () {
      final text = File(
        'lib/src/agent/message_cap.dart',
      ).readAsStringSync().toLowerCase();
      for (final identity in bannedIdentities) {
        expect(
          text.contains(identity),
          isFalse,
          reason: 'message_cap.dart must not mention "$identity"',
        );
      }
    });

    test('no incident cap value is compiled into the store/coalesce '
        'module', () {
      // The store must start empty; a literal incident value (or any
      // plausible 4-digit cap) compiled in would be a hidden table.
      final text = File('lib/src/agent/message_cap.dart').readAsStringSync();
      expect(text.contains('2048'), isFalse);
      expect(text.contains('2049'), isFalse);
      expect(
        RegExp(r'\b[2-9]\d{3,}\b').hasMatch(text),
        isFalse,
        reason: 'no cap-sized constant may live in the store module',
      );
    });

    test('the classifier regex is the only built-in: overflow.dart parses '
        'the cap from the error, never from a table', () {
      final text = File('lib/src/overflow.dart').readAsStringSync();
      // The classifier must reference the shape, not a provider.
      expect(text.contains('array length'), isTrue);
      expect(text.toLowerCase().contains('joingonka'), isFalse);
      expect(text.toLowerCase().contains('glm'), isFalse);
    });
  });
}
