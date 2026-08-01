// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/live_activity.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Live Activity service is iOS-only; on the test host (macOS) every
/// call must complete as a quiet no-op and NEVER touch the method channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start/update/end complete without touching the channel', () async {
    var channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('fah/live_activity'), (
          call,
        ) async {
          channelCalls++;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('fah/live_activity'),
            null,
          ),
    );

    await LiveActivity.start(sessionTitle: 't', statusText: 'working…');
    await LiveActivity.update(statusText: '[bash] ✓');
    await LiveActivity.update(statusText: 'done', isDone: true);
    await LiveActivity.end();

    expect(channelCalls, 0);
  });
}
