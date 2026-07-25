// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [CalendarApi] for the `fa.calendar` bridge tests — the host-side
/// tests never touch the real method channel.
final class _FakeCalendarApi implements CalendarApi {
  final created = <({String title, DateTime start, DateTime end})>[];
  final deletedIds = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<List<CalendarEvent>> events({
    required DateTime start,
    required DateTime end,
  }) async => [
    (
      id: 'ev-standup',
      title: 'Standup',
      start: DateTime(2026, 7, 25, 10),
      end: DateTime(2026, 7, 25, 11),
      allDay: false,
      calendar: 'Work',
      location: null,
      notes: null,
    ),
  ];

  @override
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
  }) async {
    created.add((title: title, start: start, end: end));
    return 'fake-id-${created.length}';
  }

  @override
  Future<void> updateEvent({
    required String id,
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? calendar,
    String? location,
    String? notes,
  }) async {}

  @override
  Future<void> deleteEvent({required String id}) async {
    deletedIds.add(id);
  }
}

/// Smoke test for the real JS backend (flutter_js / JavaScriptCore on the
/// macOS test host): boots the engine, expects a render tree, and checks the
/// fa-bridge permission gates.
///
/// Everything runs inside `tester.runAsync` with small real delays: the
/// JS→Dart bridge messages are processed on the real event loop, and the
/// fake-time `pump()` would both starve them and trip the pending-timer
/// invariant.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 300);

  const widgetJs = '''
(function() {
  jsr.onEvent(function(actionId, payload) {
    if (actionId === 'tap') {
      jsr.render({type: 'text', data: 'tapped'});
      jsr.exportState({tapped: true});
    }
  });
  jsr.render({type: 'text', data: 'hello'});
  jsr.exportState({ready: true});
})();
''';

  JsAppInfo app() => JsAppInfo.fromManifest(
    const {'id': 'demo', 'name': 'Demo'},
    bundled: false,
    fallbackId: 'demo',
  );

  testWidgets('engine renders the initial tree and exports state', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', widgetJs);
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        await engine.start();
        await Future<void>.delayed(settle);

        expect(engine.tree.value, isNotNull);
        expect(jsonEncode(engine.tree.value), contains('hello'));
        expect(engine.exportedState, isNotNull);
        expect(engine.exportedState!['ready'], isTrue);

        await engine.callEvent('tap');
        await Future<void>.delayed(settle);
        expect(jsonEncode(engine.tree.value), contains('tapped'));
        expect(engine.exportedState!['tapped'], isTrue);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('back bridge: registration push, consume, and close', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  var backs = 0;
  jsr.onEvent(function(actionId, payload) {
    // 'back' is reserved: it must NOT reach the app handler.
    if (actionId === 'back') jsr.exportState({leaked: true});
  });
  jsr.onBack = function() {
    backs++;
    jsr.exportState({backs: backs});
    return backs < 2; // consume the first back, decline the second
  };
  jsr.render({type: 'text', data: 'x'});
})();
''');
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        var closeRequests = 0;
        engine.onCloseRequested = () => closeRequests++;
        await engine.start();

        // The bootstrap pushes the jsr.onBack registration to the host.
        for (var i = 0; i < 20 && !engine.backHandlerRegistered.value; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(engine.backHandlerRegistered.value, isTrue);

        // First back: the app consumes it — no close request.
        await engine.callEvent('back');
        await Future<void>.delayed(settle);
        expect(engine.exportedState?['backs'], 1);
        expect(engine.exportedState?['leaked'], isNull);
        expect(closeRequests, 0);

        // Second back: the app declines — the host is asked to close.
        await engine.callEvent('back');
        await Future<void>.delayed(settle);
        expect(engine.exportedState?['backs'], 2);
        expect(closeRequests, 1);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('back without a jsr.onBack handler asks the host to close', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.onEvent(function(actionId, payload) {});
  jsr.render({type: 'text', data: 'x'});
})();
''');
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
      );
      try {
        var closeRequests = 0;
        engine.onCloseRequested = () => closeRequests++;
        await engine.start();
        await Future<void>.delayed(settle);
        expect(engine.backHandlerRegistered.value, isFalse);

        await engine.callEvent('back');
        await Future<void>.delayed(settle);
        expect(closeRequests, 1);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('fa.llm is gated by the llm permission', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.llm('ping').then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      Future<Object?> fakeLlm(
        List<FaLlmMessage> messages, {
        void Function(String delta)? onDelta,
      }) async => 'pong:${messages.single.content}';

      // Without the permission the bridge answers with a permission error.
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        llmHandler: fakeLlm,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('__error'),
        );
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('llm permission'),
        );
      } finally {
        await denied.dispose();
      }

      // With it, the handler runs.
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(llm: true),
        llmHandler: fakeLlm,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(granted.exportedState?['result'], 'pong:ping');
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.llm.chat is gated and passes multi-turn messages in order', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.llm.chat([
    {role: 'system', content: 'be terse'},
    {role: 'user', content: 'hi'},
    {role: 'assistant', content: 'hello'},
    {role: 'user', content: 'how are you?'}
  ]).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final received = <FaLlmMessage>[];
      Future<Object?> fakeLlm(
        List<FaLlmMessage> messages, {
        void Function(String delta)? onDelta,
      }) async {
        received.addAll(messages);
        return 'fine';
      }

      // Without the permission the bridge answers with a permission error.
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        llmHandler: fakeLlm,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('llm permission'),
        );
        expect(received, isEmpty);
      } finally {
        await denied.dispose();
      }

      // With it, the full conversation reaches the handler in order.
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(llm: true),
        llmHandler: fakeLlm,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(granted.exportedState?['result'], 'fine');
        expect(received.map((m) => m.role), [
          'system',
          'user',
          'assistant',
          'user',
        ]);
        expect(received.map((m) => m.content), [
          'be terse',
          'hi',
          'hello',
          'how are you?',
        ]);
      } finally {
        await granted.dispose();
      }

      // Permission granted but no model connected: actionable error.
      final noModel = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(llm: true),
      );
      try {
        await noModel.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(noModel.exportedState?['result']),
          contains('connect a model'),
        );
      } finally {
        await noModel.dispose();
      }
    });
  });

  testWidgets('fa.llm.stream delivers ordered deltas and resolves full text', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      // Note: no jsr.onEvent registration — the bootstrap's fallback handler
      // must still deliver llm.delta events.
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  var partials = [];
  jsr.fa.llm.stream([{role: 'user', content: 'count'}], function(partial) {
    partials.push(partial);
  }).then(function(text) {
    jsr.exportState({partials: partials, done: text});
  }, function(error) {
    jsr.exportState({done: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final received = <FaLlmMessage>[];
      Future<Object?> fakeLlm(
        List<FaLlmMessage> messages, {
        void Function(String delta)? onDelta,
      }) async {
        received.addAll(messages);
        onDelta?.call('one ');
        onDelta?.call('two');
        return 'one two';
      }

      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(llm: true),
        llmHandler: fakeLlm,
      );
      try {
        await engine.start();
        for (var i = 0; i < 30 && engine.exportedState?['done'] == null; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        // onDelta receives the ACCUMULATED partial text, in order.
        expect(engine.exportedState?['partials'], ['one ', 'one two']);
        expect(engine.exportedState?['done'], 'one two');
        expect(received.single.role, 'user');
        expect(received.single.content, 'count');
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('fa.calendar is gated by the calendar permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.calendar({date: '2026-07-25'}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error.
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        calendar: _FakeCalendarApi(),
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('__error'),
        );
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('calendar permission'),
        );
      } finally {
        await denied.dispose();
      }

      // With it, the events come from the CalendarApi.
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(calendar: true),
        calendar: _FakeCalendarApi(),
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        final result = jsonEncode(granted.exportedState?['result']);
        expect(result, contains('Standup'));
        expect(result, contains('Work'));
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.calendar write methods are gated by the permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.calendar.create({title: 'Dentist', date: '2026-07-25', startHour: 14, endHour: 15}).then(function(result) {
    jsr.exportState({created: result});
  }, function(error) {
    jsr.exportState({created: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the write calls answer with an error.
      final deniedCalendar = _FakeCalendarApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        calendar: deniedCalendar,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['created']),
          contains('calendar permission'),
        );
        expect(deniedCalendar.created, isEmpty);
        expect(deniedCalendar.deletedIds, isEmpty);
      } finally {
        await denied.dispose();
      }
    });
  });

  testWidgets('granted fa.calendar create/delete reach the CalendarApi', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.calendar.create({title: 'Dentist', date: '2026-07-25', startHour: 14, endHour: 15}).then(function(result) {
    jsr.exportState({created: result});
    jsr.fa.calendar.delete({id: 'ev-standup'}).then(function(deleteResult) {
      jsr.exportState({created: result, deleted: deleteResult});
    });
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final calendar = _FakeCalendarApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(calendar: true),
        calendar: calendar,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(calendar.created, hasLength(1));
        expect(calendar.created.single.title, 'Dentist');
        expect(calendar.created.single.start, DateTime(2026, 7, 25, 14));
        expect(calendar.created.single.end, DateTime(2026, 7, 25, 15));
        expect(calendar.deletedIds, ['ev-standup']);
        final created = jsonEncode(granted.exportedState?['created']);
        expect(created, contains('fake-id-1'));
        expect(jsonEncode(granted.exportedState?['deleted']), contains('true'));
      } finally {
        await granted.dispose();
      }
    });
  });
}
