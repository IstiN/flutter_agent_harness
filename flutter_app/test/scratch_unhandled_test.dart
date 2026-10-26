import 'dart:async';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('unhandled rejection probe', () async {
    unawaited(Future<void>.error(StateError('boom'), StackTrace.current));
    await pumpEventQueue();
    expect(1, 1);
  });
}
