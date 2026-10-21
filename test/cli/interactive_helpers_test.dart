import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A scripted prompt callback: returns canned answers in order.
Future<TuiPromptAnswer?> Function(TuiPromptSpec) scriptedPrompt(
  List<TuiPromptAnswer> answers,
) {
  var i = 0;
  return (spec) async {
    if (i < answers.length) return answers[i++];
    return null;
  };
}

void main() {
  group('interactiveKeySet', () {
    test('saves when name and value are provided', () async {
      final store = FakeSecureKeyStore(available: true);
      final keys = SecureKeyCache(store);
      await keys.probe();
      String? storedName;
      String? storedValue;
      var savedCalled = false;

      await interactiveKeySet(
        name: null,
        keys: keys,
        onSecretStored: (n, v) {
          storedName = n;
          storedValue = v;
        },
        prompt: scriptedPrompt([
          const TextPromptAnswer('MY_KEY'),
          const TextPromptAnswer('secret123'),
        ]),
        onResult: (_) {},
        onSaved: (_, _) => savedCalled = true,
      );

      expect(keys.read('MY_KEY'), 'secret123');
      expect(storedName, 'MY_KEY');
      expect(storedValue, 'secret123');
      expect(savedCalled, isTrue);
    });

    test('uses the provided name without prompting', () async {
      final store = FakeSecureKeyStore(available: true);
      final keys = SecureKeyCache(store);
      await keys.probe();
      var promptCount = 0;

      await interactiveKeySet(
        name: 'GIVEN_NAME',
        keys: keys,
        onSecretStored: null,
        prompt: (spec) async {
          promptCount++;
          return const TextPromptAnswer('val');
        },
        onResult: (_) {},
        onSaved: (_, _) {},
      );

      expect(promptCount, 1);
      expect(keys.read('GIVEN_NAME'), 'val');
    });

    test('reports invalid key name', () async {
      final store = FakeSecureKeyStore(available: true);
      final keys = SecureKeyCache(store);
      await keys.probe();
      String? resultMessage;

      await interactiveKeySet(
        name: null,
        keys: keys,
        onSecretStored: null,
        prompt: scriptedPrompt([const TextPromptAnswer('bad name!')]),
        onResult: (m) => resultMessage = m,
        onSaved: (_, _) {},
      );

      expect(resultMessage, contains('invalid key name'));
    });

    test('reports cancelled on empty value', () async {
      final store = FakeSecureKeyStore(available: true);
      final keys = SecureKeyCache(store);
      await keys.probe();
      String? resultMessage;

      await interactiveKeySet(
        name: 'MY_KEY',
        keys: keys,
        onSecretStored: null,
        prompt: scriptedPrompt([const TextPromptAnswer('')]),
        onResult: (m) => resultMessage = m,
        onSaved: (_, _) {},
      );

      expect(resultMessage, 'cancelled');
    });

    test('reports could not save on write failure', () async {
      final store = FakeSecureKeyStore(available: true)..failWrites = true;
      final keys = SecureKeyCache(store);
      await keys.probe();
      String? resultMessage;

      await interactiveKeySet(
        name: 'MY_KEY',
        keys: keys,
        onSecretStored: null,
        prompt: scriptedPrompt([const TextPromptAnswer('val')]),
        onResult: (m) => resultMessage = m,
        onSaved: (_, _) {},
      );

      expect(resultMessage, contains('could not save'));
    });

    test('aborts silently on cancel (null result)', () async {
      final store = FakeSecureKeyStore(available: true);
      final keys = SecureKeyCache(store);
      await keys.probe();
      var resultCalled = false;

      await interactiveKeySet(
        name: null,
        keys: keys,
        onSecretStored: null,
        prompt: (spec) async => null,
        onResult: (_) => resultCalled = true,
        onSaved: (_, _) {},
      );

      expect(resultCalled, isFalse);
    });
  });
}
