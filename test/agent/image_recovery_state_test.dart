// gh-1934 UT — the session-scoped 413 recovery state: adaptive budget
// halving with the recovery floor, config-still-honored-when-lower (AC5),
// the one-shot recovery note, and the canonical notice text.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('ImagePayloadRecoveryState.effectiveByteBudget', () {
    test('no learning — the configured budget rides verbatim', () {
      final state = ImagePayloadRecoveryState();
      expect(state.effectiveByteBudget(8 * 1024 * 1024), 8 * 1024 * 1024);
      expect(state.effectiveByteBudget(0), 0, reason: '0 = budget disabled');
    });

    test('a learned budget binds only when lower than configured (AC5)', () {
      final state = ImagePayloadRecoveryState()..halveBudget(8 * 1024 * 1024);
      expect(state.learnedByteBudget, 4 * 1024 * 1024);
      expect(state.effectiveByteBudget(8 * 1024 * 1024), 4 * 1024 * 1024);
      expect(
        state.effectiveByteBudget(1 * 1024 * 1024),
        1 * 1024 * 1024,
        reason: 'config still honored when lower',
      );
      expect(state.effectiveByteBudget(0), 4 * 1024 * 1024,
          reason: 'a disabled config budget cannot raise the learned one');
    });

    test('halving compounds — each 413 halves again (AC4)', () {
      final state = ImagePayloadRecoveryState();
      state.halveBudget(8 * 1024 * 1024);
      state.halveBudget(8 * 1024 * 1024);
      expect(state.learnedByteBudget, 2 * 1024 * 1024);
    });

    test('the learned budget never sinks below the recovery floor', () {
      final state = ImagePayloadRecoveryState();
      state.halveBudget(8 * 1024 * 1024);
      for (var i = 0; i < 12; i++) {
        state.halveBudget(8 * 1024 * 1024);
      }
      expect(state.learnedByteBudget, imageRecoveryBudgetFloor);
      expect(
        state.effectiveByteBudget(8 * 1024 * 1024),
        imageRecoveryBudgetFloor,
      );
    });

    test('a disabled configured budget seeds halving from the default', () {
      final state = ImagePayloadRecoveryState()..halveBudget(0);
      expect(
        state.learnedByteBudget,
        defaultMaxImageBytesPerRequest ~/ 2,
        reason: 'the provider proved a cap — the ladder learns from the '
            'default, not from a disabled budget',
      );
    });
  });

  group('the one-shot recovery note', () {
    test('armed → consumed once with the build counts, then silence', () {
      final state = ImagePayloadRecoveryState();
      expect(state.consumeNote(), isNull, reason: 'nothing armed');

      state.armNote(pass: 1);
      state.observeBuild(dropped: 7, stripped: 0);
      final note = state.consumeNote();
      expect(note, contains('recovered from 413'));
      expect(note, contains('dropped 7'));
      expect(state.consumeNote(), isNull, reason: 'one-shot');
    });

    test('the note re-arms per pass with fresh counts', () {
      final state = ImagePayloadRecoveryState();
      state.armNote(pass: 1);
      state.observeBuild(dropped: 3, stripped: 0);
      expect(state.consumeNote(), contains('dropped 3'));

      state.armNote(pass: 2);
      state.observeBuild(dropped: 0, stripped: 5);
      final note = state.consumeNote();
      expect(note, contains('stripped 5'));
    });
  });

  test('the canonical notice text matches the ticket format', () {
    expect(
      imageRecoveryNoticeText(dropped: 7, stripped: 2),
      '[images] recovered from 413: dropped 7, stripped 2',
    );
    expect(
      imageRecoveryFailedText('413: still too large'),
      contains('switch provider or lower images.maxBytesPerRequest'),
    );
  });
}
