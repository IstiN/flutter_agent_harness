// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/notify_service.dart';
import 'package:fa/services/notify_tool.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Configurable fake [NotifyApi] — the host-side tests never touch the
/// real method channel.
final class FakeNotifyApi implements NotifyApi {
  FakeNotifyApi({this.available = true, this.granted = true});

  bool available;
  bool granted;
  int requestAccessCalls = 0;
  int cancelAllCalls = 0;
  int nextId = 0;
  final scheduled = <({String title, String? body, double? delaySeconds})>[];
  final cancelledIds = <String>[];

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> requestAccess() async {
    requestAccessCalls++;
    return granted;
  }

  @override
  Future<String> schedule({
    required String title,
    String? body,
    String? id,
    double? delaySeconds,
  }) async {
    scheduled.add((title: title, body: body, delaySeconds: delaySeconds));
    return id ?? 'fake-id-${nextId++}';
  }

  @override
  Future<void> cancel({required String id}) async {
    cancelledIds.add(id);
  }

  @override
  Future<void> cancelAll() async {
    cancelAllCalls++;
  }
}

String _textOf(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join();

void main() {
  group('notifyTool', () {
    test('schedules immediately and renders the id', () async {
      final notify = FakeNotifyApi();
      final tool = notifyTool(notify);
      expect(tool.tier, ApprovalTier.write);

      final result = await tool.execute(
        const {'title': 'Build finished', 'body': 'macOS build succeeded'},
        null,
        null,
      );

      expect(notify.scheduled, hasLength(1));
      expect(notify.scheduled.single.title, 'Build finished');
      expect(notify.scheduled.single.body, 'macOS build succeeded');
      expect(notify.scheduled.single.delaySeconds, 0.0);
      final text = _textOf(result);
      expect(text, contains('Scheduled notification "Build finished"'));
      expect(text, contains('immediately'));
      expect(text, contains('id: fake-id-0'));
    });

    test('delaySeconds schedules a delayed notification', () async {
      final notify = FakeNotifyApi();
      final tool = notifyTool(notify);

      final result = await tool.execute(
        const {'title': 'Standup', 'delaySeconds': 300},
        null,
        null,
      );

      expect(notify.scheduled.single.delaySeconds, 300.0);
      expect(_textOf(result), contains('in 5m'));
    });

    test(
      'negative delay and missing title answer with an error text',
      () async {
        final notify = FakeNotifyApi();
        final tool = notifyTool(notify);

        final negative = await tool.execute(
          const {'title': 'X', 'delaySeconds': -5},
          null,
          null,
        );
        expect(_textOf(negative), contains('delaySeconds must be >= 0'));

        final noTitle = await tool.execute(const {}, null, null);
        expect(_textOf(noTitle), contains('title is required'));

        expect(notify.scheduled, isEmpty);
      },
    );

    test('denied access requests once, then reports guidance', () async {
      final notify = FakeNotifyApi(granted: false);
      final tool = notifyTool(notify);

      final result = await tool.execute(const {'title': 'X'}, null, null);

      expect(notify.requestAccessCalls, 1);
      final text = _textOf(result);
      expect(text, contains('denied'));
      expect(text, contains('Notifications'));
      expect(notify.scheduled, isEmpty);
    });

    test('unsupported platform answers with a clean note', () async {
      final notify = FakeNotifyApi(available: false);
      final tool = notifyTool(notify);

      final result = await tool.execute(const {'title': 'X'}, null, null);

      expect(_textOf(result), contains('not supported on this platform'));
      expect(notify.requestAccessCalls, 0);
    });

    test('cancel and cancelAll reach the api', () async {
      final notify = FakeNotifyApi();

      await notify.cancel(id: 'fake-id-0');
      await notify.cancelAll();

      expect(notify.cancelledIds, ['fake-id-0']);
      expect(notify.cancelAllCalls, 1);
    });
  });
}
