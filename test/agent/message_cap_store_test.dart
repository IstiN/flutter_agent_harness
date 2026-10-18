// gh-1680 UT-2 / AC2 — the learned per-model message-cap store:
// parse → record → persist → boot-load round trip, (provider, modelId)
// keying that never collides across providers (E5), cap-unknown flags
// (E1), re-learning a changed cap (E4), never unlearning from a
// differently-shaped retry, and the second-tier config pin.

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'some-model',
  api: 'test-api',
  provider: 'some-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

void main() {
  group('ModelCapsStore (UT-2)', () {
    test('learn → record → toJson → fromJson round trip (AC2)', () {
      final store = ModelCapsStore();
      expect(store.learnedCapFor(_model), isNull);
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      expect(store.learnedCapFor(_model), 2048);

      final revived = ModelCapsStore.fromJson(store.toJson());
      expect(revived.learnedCapFor(_model), 2048);
      expect(revived.recordFor('some-provider', 'some-model')!.maxMessages,
          2048);
    });

    test('persist → load across restarts via the disk file', () {
      final dir = Directory.systemTemp.createTempSync('fa-caps-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/model_caps.json';

      final first = ModelCapsStore();
      first.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      first.persist(path);

      // The SECOND process boots with the learned cap (boot-load).
      final second = ModelCapsStore.load(path);
      expect(second.learnedCapFor(_model), 2048);
    });

    test('a corrupt or missing file boots empty, never crashes', () {
      final dir = Directory.systemTemp.createTempSync('fa-caps-test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/model_caps.json';
      expect(ModelCapsStore.load(path).records, isEmpty);
      File(path).writeAsStringSync('not json {{{');
      expect(ModelCapsStore.load(path).records, isEmpty);
      File(path).writeAsStringSync('["unexpected"]');
      expect(ModelCapsStore.load(path).records, isEmpty);
    });

    test('the key is (provider, modelId) — same model id never collides '
        'across providers (E5)', () {
      final store = ModelCapsStore();
      final other = Model(
        id: _model.id,
        api: _model.api,
        provider: 'another-provider',
        baseUrl: 'https://other.example',
        contextWindow: 100000,
        maxTokens: 4096,
      );
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      store.learnFromRefusal(other, const MessageCapRefusal(maxMessages: 512));
      expect(store.learnedCapFor(_model), 2048);
      expect(store.learnedCapFor(other), 512);
    });

    test('a cap-unknown refusal flags the model but never unlearns a '
        'numeric cap (E1 + differently-shaped retry)', () {
      final store = ModelCapsStore();
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      // A retry phrased without numbers must NOT erase the learned cap.
      store.learnFromRefusal(_model, const MessageCapRefusal());
      expect(store.learnedCapFor(_model), 2048);

      final fresh = ModelCapsStore();
      fresh.learnFromRefusal(_model, const MessageCapRefusal());
      expect(fresh.learnedCapFor(_model), isNull);
      expect(fresh.isCapUnknown(_model.provider, _model.id), isTrue);
      // The next PARSEABLE refusal upgrades the flag to a numeric cap.
      fresh.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      expect(fresh.learnedCapFor(_model), 2048);
      expect(fresh.isCapUnknown(_model.provider, _model.id), isFalse);
    });

    test('re-learning refreshes a stale cap (E4)', () {
      final store = ModelCapsStore();
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 1024),
      );
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 4096),
      );
      expect(store.learnedCapFor(_model), 4096);
    });

    test('second-tier pin overrides the learned value', () {
      final store = ModelCapsStore();
      store.learnFromRefusal(
        _model,
        const MessageCapRefusal(maxMessages: 2048),
      );
      store.pin(_model.provider, _model.id, 3000);
      expect(store.capFor(_model.provider, _model.id), 3000);
      store.remove(_model.provider, _model.id);
      expect(store.learnedCapFor(_model), isNull);
    });

    test('an empty store serializes to an empty map — nothing hardcoded '
        '(AC5)', () {
      expect(ModelCapsStore().toJson(), isEmpty);
    });
  });

  group('messageCapTriggerReached (AC4 gate)', () {
    test('fires at cap − margin, not before', () {
      expect(messageCapTriggerReached(2031, 2048), isFalse);
      expect(messageCapTriggerReached(2032, 2048), isTrue, reason: '2048-16');
      expect(messageCapTriggerReached(2048, 2048), isTrue);
    });

    test('a null cap never triggers (AC8)', () {
      expect(messageCapTriggerReached(100000, null), isFalse);
    });

    test('a custom margin is honored', () {
      expect(messageCapTriggerReached(2039, 2048, margin: 8), isFalse);
      expect(messageCapTriggerReached(2040, 2048, margin: 8), isTrue);
      expect(messageCapTriggerReached(2040, 2048, margin: 16), isTrue);
    });
  });
}
