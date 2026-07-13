import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('CancelToken', () {
    test('starts uncancelled', () {
      final source = CancelTokenSource();
      expect(source.token.isCancelled, isFalse);
      expect(source.token.cancelReason, isNull);
    });

    test('cancel flips isCancelled and records reason', () {
      final source = CancelTokenSource();
      source.cancel('user abort');
      expect(source.token.isCancelled, isTrue);
      expect(source.token.cancelReason, 'user abort');
    });

    test('cancel is idempotent; first reason wins', () {
      final source = CancelTokenSource();
      source.cancel('first');
      source.cancel('second');
      expect(source.token.cancelReason, 'first');
    });

    test('onCancel completes after cancel', () async {
      final source = CancelTokenSource();
      final future = source.token.onCancel;
      source.cancel();
      await expectLater(future, completes);
    });

    test('onCancel completes immediately when already cancelled', () async {
      final source = CancelTokenSource();
      source.cancel();
      await expectLater(source.token.onCancel, completes);
    });

    test('multiple listeners all complete', () async {
      final source = CancelTokenSource();
      final a = source.token.onCancel;
      final b = source.token.onCancel;
      source.cancel();
      await expectLater(Future.wait([a, b]), completes);
    });

    test('throwIfCancelled throws only after cancel', () {
      final source = CancelTokenSource();
      source.token.throwIfCancelled(); // no throw
      source.cancel('done');
      expect(
        source.token.throwIfCancelled,
        throwsA(
          isA<CancelledException>().having((e) => e.reason, 'reason', 'done'),
        ),
      );
    });

    test('CancelledException toString includes reason', () {
      expect(CancelledException('x').toString(), contains('x'));
      expect(CancelledException(null).toString(), 'CancelledException');
    });
  });
}
