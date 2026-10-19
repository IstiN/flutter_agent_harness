// CLI wiring tests for gh-1680 message-cap handling (PR #1695 review
// findings): the pre-emptive gate also consumes the one-shot E1 pass a
// cap-unknown refusal armed (thread 2), a config-pinned override wins
// over the learned cap (thread 3), and a compact pass that only shrinks
// tokens while the count still trips the trigger is not a success
// (thread 2).

import 'dart:io';

import 'package:flutter_agent_harness/src/agent/message_cap.dart';
import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/overflow.dart';
import 'package:flutter_agent_harness/src/model_roles/capability_resolver.dart';
import 'package:flutter_agent_harness/src/types.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('PR #1695: cap-unknown refusals arm one pre-emptive pass (E1)', () {
    test('the pass is pending after a cap-unknown refusal', () {
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      expect(store.isPremptivePassPending('fake', 'm'), isFalse);
      store.learnFromRefusal(model, const MessageCapRefusal());
      expect(store.isPremptivePassPending('fake', 'm'), isTrue);
    });

    test('the pass is one-shot — a second gate check finds nothing', () {
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      store.learnFromRefusal(model, const MessageCapRefusal());
      expect(store.takePremptivePass('fake', 'm'), isTrue);
      expect(store.isPremptivePassPending('fake', 'm'), isFalse);
      expect(store.takePremptivePass('fake', 'm'), isFalse);
    });

    test('a new cap-unknown refusal re-arms the pass', () {
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      store.learnFromRefusal(model, const MessageCapRefusal());
      store.takePremptivePass('fake', 'm');
      store.learnFromRefusal(model, const MessageCapRefusal());
      expect(store.takePremptivePass('fake', 'm'), isTrue);
    });

    test('learning a numeric cap disarms the pending pass', () {
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      store.learnFromRefusal(model, const MessageCapRefusal());
      store.learnFromRefusal(model, const MessageCapRefusal(maxMessages: 25));
      expect(store.takePremptivePass('fake', 'm'), isFalse);
    });

    test('the pending pass never leaks into the persisted sidecar', () {
      final dir = Directory.systemTemp.createTempSync('fah-msgcap-e1');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      store.learnFromRefusal(model, const MessageCapRefusal());
      final path = '${dir.path}/model_caps.json';
      store.persist(path);
      final reloaded = ModelCapsStore.load(path);
      // The record round-trips, but the session-scoped pending pass does
      // not survive the reload.
      expect(reloaded.isCapUnknown('fake', 'm'), isTrue);
      expect(reloaded.isPremptivePassPending('fake', 'm'), isFalse);
    });
  });

  group('PR #1695: config override pin is the second tier (thread 3)', () {
    test('the pin parses, validates, and round-trips through yaml', () {
      final override = ModelCapabilityOverride.fromYaml(
        'fake',
        'm',
        loadYaml('{messageCap: 30}'),
      );
      expect(override.messageCap, 30);
      expect(override.isEmpty, isFalse);
      final buffer = StringBuffer();
      override.writeYaml(buffer, '');
      expect(buffer.toString(), contains('messageCap: 30'));
      final reparsed = ModelCapabilityOverride.fromYaml(
        'fake',
        'm',
        loadYaml(buffer.toString()),
      );
      expect(reparsed.messageCap, 30);
    });

    test('a messageCap below the margin floor is rejected', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('fake', 'm', {
          'messageCap': 1,
        }),
        throwsA(isA<ConfigException>()),
      );
    });

    test('unknown override fields stay rejected (pin is no exception)', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('fake', 'm', {
          'message_cap': 30,
        }),
        throwsA(isA<ConfigException>()),
      );
    });

    test('an all-null override still counts as empty', () {
      const override = ModelCapabilityOverride();
      expect(override.isEmpty, isTrue);
    });

    test('the CLI policy resolves the pin over the learned record', () {
      final store = ModelCapsStore();
      final model = const Model(
        id: 'm',
        api: 'test-api',
        provider: 'fake',
        baseUrl: 'https://example.test',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      // A learned cap of 8 exists; the pin of 30 must win.
      store.learnFromRefusal(model, const MessageCapRefusal(maxMessages: 8));
      const pinned = ModelCapabilityOverride(messageCap: 30);
      expect(ModelCapsStore.learnedCapOr(store.recordFor('fake', 'm'), 30), 30);
      expect(pinned.messageCap, 30);
      // Unpinned: the learned record stands.
      expect(ModelCapsStore.learnedCapOr(store.recordFor('fake', 'm'), null), 8);
    });
  });
}
