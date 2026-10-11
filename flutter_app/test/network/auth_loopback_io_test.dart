// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/network/auth_loopback_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoopbackOAuthReceiver', () {
    test('close cancels the timeout timer (no late unhandled error)', () async {
      final receiver = await LoopbackOAuthReceiver.bind(
        timeout: const Duration(milliseconds: 50),
      );
      receiver.close();

      // If close() left the timer running, it fires about now and calls
      // completeError on a future nobody listens to — an unhandled async
      // error that fails the test zone.
      await Future<void>.delayed(const Duration(milliseconds: 120));
    });
  });
}
