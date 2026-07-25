// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/asr_service.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:fa/services/contact_service.dart';
import 'package:fa/services/health_service.dart';
import 'package:fa/services/home_service.dart';
import 'package:fa/services/notify_service.dart';
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

/// Fake [ContactApi] for the `fa.contacts` bridge tests — the host-side
/// tests never touch the real method channel.
final class _FakeContactApi implements ContactApi {
  final created = <({String name, List<String>? phones})>[];
  final deletedIds = <String>[];
  final openedUrls = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<List<Contact>> searchContacts({required String query}) async => [
    (
      id: 'c-anna',
      name: 'Anna Ivanova',
      phones: const ['+1 555 0100'],
      emails: const ['anna@example.com'],
    ),
  ];

  @override
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    created.add((name: name, phones: phones));
    return 'fake-id-${created.length}';
  }

  @override
  Future<void> updateContact({
    required String id,
    String? name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {}

  @override
  Future<void> deleteContact({required String id}) async {
    deletedIds.add(id);
  }

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}

/// Fake [HealthApi] for the `fa.health.summary` bridge tests — the host-side
/// tests never touch the real method channel.
final class _FakeHealthApi implements HealthApi {
  int? lastDays;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<HealthSummary> summary({required int days}) async {
    lastDays = days;
    return (
      steps: const [(date: '2026-07-25', value: 12345.0)],
      restingHeartRate: const [(date: '2026-07-25', value: 58.0)],
      sleepHours: const [(date: '2026-07-25', value: 7.5)],
    );
  }
}

/// Fake [HomeApi] for the `fa.home` bridge tests — the host-side tests
/// never touch the real method channel.
final class _FakeHomeApi implements HomeApi {
  final powerCalls = <({String id, bool on})>[];
  final brightnessCalls = <({String id, int value})>[];
  final temperatureCalls = <({String id, double celsius})>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<List<HomeAccessory>> listAccessories() async => const [
    (
      id: 'a-light',
      name: 'Ceiling Light',
      room: 'Living Room',
      homeName: 'My Home',
      category: 'lightbulb',
      reachable: true,
      isOn: true,
      brightness: 80,
      targetTemperature: null,
    ),
    (
      id: 'a-thermo',
      name: 'Thermostat',
      room: 'Hallway',
      homeName: 'My Home',
      category: 'thermostat',
      reachable: true,
      isOn: null,
      brightness: null,
      targetTemperature: 21.5,
    ),
  ];

  @override
  Future<void> setPower({required String id, required bool on}) async {
    powerCalls.add((id: id, on: on));
  }

  @override
  Future<void> setBrightness({required String id, required int value}) async {
    brightnessCalls.add((id: id, value: value));
  }

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
  }) async {
    temperatureCalls.add((id: id, celsius: celsius));
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

  /// Waits until the app exported state (the bridge calls cross real
  /// platform channels, so a single fixed settle can race under load).
  Future<void> waitForState(JsAppEngine engine) async {
    for (var i = 0; i < 40 && engine.exportedState == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  }

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

  testWidgets('fa.health.summary is gated by the health permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.health.summary({days: 14}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error.
      final deniedHealth = _FakeHealthApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        health: deniedHealth,
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
          contains('health permission'),
        );
        expect(deniedHealth.lastDays, isNull);
      } finally {
        await denied.dispose();
      }

      // With it, the summary comes from the HealthApi.
      final grantedHealth = _FakeHealthApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(health: true),
        health: grantedHealth,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(grantedHealth.lastDays, 14);
        final result = jsonEncode(granted.exportedState?['result']);
        expect(result, contains('2026-07-25'));
        expect(result, contains('12345'));
        expect(result, contains('restingHeartRate'));
        expect(result, contains('sleepHours'));
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.home is gated by the homekit permission', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.home.list().then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error.
      final deniedHome = _FakeHomeApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        home: deniedHome,
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
          contains('homekit permission'),
        );
        expect(deniedHome.powerCalls, isEmpty);
      } finally {
        await denied.dispose();
      }

      // With it, the accessories come from the HomeApi.
      final grantedHome = _FakeHomeApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(homekit: true),
        home: grantedHome,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        final result = jsonEncode(granted.exportedState?['result']);
        expect(result, contains('Ceiling Light'));
        expect(result, contains('Living Room'));
        expect(result, contains('"brightness":80'));
        expect(result, contains('"targetTemperature":21.5'));
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('granted fa.home writes reach the HomeApi (legacy homekit '
      'form included)', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.home.setPower({id: 'a-light', on: false}).then(function(power) {
    jsr.fa.home.setBrightness({id: 'a-light', value: 60}).then(function(bright) {
      jsr.fa.homekit('setTemperature', {id: 'a-thermo', celsius: 22.5}).then(function(temp) {
        jsr.exportState({power: power, bright: bright, temp: temp});
      });
    });
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final home = _FakeHomeApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(homekit: true),
        home: home,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(home.powerCalls, [(id: 'a-light', on: false)]);
        expect(home.brightnessCalls, [(id: 'a-light', value: 60)]);
        expect(home.temperatureCalls, [(id: 'a-thermo', celsius: 22.5)]);
        final state = granted.exportedState!;
        expect(jsonEncode(state['power']), contains('"on":false'));
        expect(jsonEncode(state['bright']), contains('"brightness":60'));
        expect(jsonEncode(state['temp']), contains('"temperature":22.5'));
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

  testWidgets('fa.notify is gated by the notifications permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.notify.schedule({title: 'Build done', body: 'ok', delaySeconds: 60}).then(function(result) {
    if (result && result.id) {
      jsr.fa.notify.cancel({id: result.id}).then(function(cancelResult) {
        jsr.exportState({result: result, cancelResult: cancelResult});
      }, function(error) {
        jsr.exportState({result: {__error: '' + error}});
      });
    } else {
      jsr.exportState({result: result});
    }
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error
      // and the backend never sees a schedule.
      final deniedNotify = _FakeNotifyApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        notify: deniedNotify,
      );
      try {
        await denied.start();
        // The bridge call crosses real platform channels — poll instead of
        // a fixed settle (races under load).
        for (
          var i = 0;
          i < 40 && denied.exportedState?['result'] == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('__error'),
        );
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('notifications permission'),
        );
        expect(deniedNotify.scheduled, isEmpty);
      } finally {
        await denied.dispose();
      }

      // With it, schedule reaches the NotifyApi and cancel removes the id.
      final grantedNotify = _FakeNotifyApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(notifications: true),
        notify: grantedNotify,
      );
      try {
        await granted.start();
        for (
          var i = 0;
          i < 40 && granted.exportedState?['cancelResult'] == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(grantedNotify.scheduled, hasLength(1));
        expect(grantedNotify.scheduled.single.title, 'Build done');
        expect(grantedNotify.scheduled.single.body, 'ok');
        expect(grantedNotify.scheduled.single.delaySeconds, 60.0);
        expect(grantedNotify.cancelledIds, ['fake-id-1']);
        expect(
          jsonEncode(granted.exportedState?['result']),
          contains('fake-id-1'),
        );
        expect(
          jsonEncode(granted.exportedState?['cancelResult']),
          contains('true'),
        );
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.notify schedule validates its arguments', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.notify.schedule({title: '', delaySeconds: -1}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final notify = _FakeNotifyApi();
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(notifications: true),
        notify: notify,
      );
      try {
        await engine.start();
        for (
          var i = 0;
          i < 40 && engine.exportedState?['result'] == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 150));
        }
        expect(
          jsonEncode(engine.exportedState?['result']),
          contains('__error'),
        );
        expect(notify.scheduled, isEmpty);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('fa.contacts is gated by the contacts permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.contacts.search({query: 'anna'}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final contacts = _FakeContactApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        contacts: contacts,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('contacts permission'),
        );

        final granted = JsAppEngine(
          app: app(),
          env: env,
          permissions: const AppPermissions(contacts: true),
          contacts: contacts,
        );
        try {
          await granted.start();
          await Future<void>.delayed(settle);
          final result = jsonEncode(granted.exportedState?['result']);
          expect(result, contains('Anna Ivanova'));
          expect(result, contains('+1 555 0100'));
        } finally {
          await granted.dispose();
        }
      } finally {
        await denied.dispose();
      }
    });
  });

  testWidgets('fa.contacts write/call/sms are gated by the permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.contacts.create({name: 'Bob', phones: ['+7 900 0000']}).then(function(result) {
    jsr.exportState({created: result});
  }, function(error) {
    jsr.exportState({created: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final deniedContacts = _FakeContactApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        contacts: deniedContacts,
      );
      try {
        await denied.start();
        await Future<void>.delayed(settle);
        expect(
          jsonEncode(denied.exportedState?['created']),
          contains('contacts permission'),
        );
        expect(deniedContacts.created, isEmpty);
        expect(deniedContacts.deletedIds, isEmpty);
        expect(deniedContacts.openedUrls, isEmpty);
      } finally {
        await denied.dispose();
      }
    });
  });

  testWidgets('granted fa.contacts create/call/sms reach the ContactApi', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.contacts.create({name: 'Bob', phones: ['+7 900 0000']}).then(function(result) {
    jsr.fa.contacts.call({id: 'c-anna'}).then(function(callResult) {
      jsr.fa.contacts.sms({phone: '+1 555 0100', text: 'hi there'}).then(function(smsResult) {
        jsr.exportState({created: result, called: callResult, texted: smsResult});
      });
    });
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final contacts = _FakeContactApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(contacts: true),
        contacts: contacts,
      );
      try {
        await granted.start();
        await Future<void>.delayed(settle);
        expect(contacts.created, hasLength(1));
        expect(contacts.created.single.name, 'Bob');
        expect(contacts.created.single.phones, ['+7 900 0000']);
        // {id} resolved via the search results to the first phone number.
        expect(contacts.openedUrls, [
          'tel:+1 555 0100',
          'sms:+1 555 0100?&body=hi%20there',
        ]);
        final state = granted.exportedState!;
        expect(jsonEncode(state['created']), contains('fake-id-1'));
        expect(jsonEncode(state['called']), contains('+1 555 0100'));
        expect(jsonEncode(state['texted']), contains('+1 555 0100'));
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.asr.record is gated by the microphone permission', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.asr.record({seconds: 1}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error.
      final deniedAsr = _FakeAsrApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        asr: deniedAsr,
      );
      try {
        await denied.start();
        await waitForState(denied);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('__error'),
        );
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('microphone permission'),
        );
        expect(deniedAsr.startCalls, 0);
      } finally {
        await denied.dispose();
      }

      // With it, the recording comes from the AsrApi (the engine waits the
      // requested wall-clock second).
      final grantedAsr = _FakeAsrApi();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(microphone: true),
        asr: grantedAsr,
      );
      try {
        await granted.start();
        await waitForState(granted);
        expect(grantedAsr.startCalls, 1);
        expect(grantedAsr.stopCalls, 1);
        final result = jsonEncode(granted.exportedState?['result']);
        expect(result, contains('/tmp/fah-mic-test.m4a'));
        expect(result, contains('"durationMs":5000'));
        expect(result, contains('"sampleRate":44100'));
      } finally {
        await granted.dispose();
      }
    });
  });

  testWidgets('fa.asr.record answers with the denial guidance when OS '
      'access is denied', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.asr.record({seconds: 1}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      final deniedOs = _FakeAsrApi()..granted = false;
      final engine = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(microphone: true),
        asr: deniedOs,
      );
      try {
        await engine.start();
        await waitForState(engine);
        expect(
          jsonEncode(engine.exportedState?['result']),
          contains('microphone access was denied'),
        );
        expect(deniedOs.startCalls, 0);
      } finally {
        await engine.dispose();
      }
    });
  });

  testWidgets('fa.asr.transcribe is gated, rides the transcriber, and '
      'guides when no endpoint is configured', (tester) async {
    await tester.runAsync(() async {
      final env = MemoryExecutionEnv();
      await env.writeFile('apps/demo/widget.js', '''
(function() {
  jsr.fa.asr.transcribe({path: '/tmp/fah-mic-test.m4a'}).then(function(result) {
    jsr.exportState({result: result});
  }, function(error) {
    jsr.exportState({result: {__error: '' + error}});
  });
  jsr.render({type: 'text', data: 'x'});
})();
''');

      // Without the permission the bridge answers with a permission error.
      final deniedAsr = _FakeAsrApi();
      final denied = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(),
        asr: deniedAsr,
        asrTranscriber: _FakeAsrTranscriber(),
      );
      try {
        await denied.start();
        await waitForState(denied);
        expect(
          jsonEncode(denied.exportedState?['result']),
          contains('microphone permission'),
        );
        expect(deniedAsr.readPaths, isEmpty);
      } finally {
        await denied.dispose();
      }

      // With the permission but no configured endpoint, the error tells
      // the user what to configure.
      final noEndpoint = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(microphone: true),
        asr: _FakeAsrApi(),
      );
      try {
        await noEndpoint.start();
        await waitForState(noEndpoint);
        expect(
          jsonEncode(noEndpoint.exportedState?['result']),
          contains('No ASR-capable endpoint'),
        );
      } finally {
        await noEndpoint.dispose();
      }

      // With both, the transcript comes from the transcriber.
      final grantedAsr = _FakeAsrApi();
      final transcriber = _FakeAsrTranscriber();
      final granted = JsAppEngine(
        app: app(),
        env: env,
        permissions: const AppPermissions(microphone: true),
        asr: grantedAsr,
        asrTranscriber: transcriber,
      );
      try {
        await granted.start();
        await waitForState(granted);
        expect(grantedAsr.readPaths, ['/tmp/fah-mic-test.m4a']);
        expect(transcriber.calls, hasLength(1));
        expect(transcriber.calls.single.filename, 'fah-mic-test.m4a');
        expect(
          jsonEncode(granted.exportedState?['result']),
          contains('fake transcript'),
        );
      } finally {
        await granted.dispose();
      }
    });
  });
}

/// Fake [AsrApi] for the `fa.asr` bridge tests — the host-side tests never
/// touch the real method channel.
final class _FakeAsrApi implements AsrApi {
  bool granted = true;
  int startCalls = 0;
  int stopCalls = 0;
  final readPaths = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => granted;

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<AsrRecording> stopRecording() async {
    stopCalls++;
    return (path: '/tmp/fah-mic-test.m4a', durationMs: 5000, sampleRate: 44100);
  }

  @override
  Future<Uint8List> readRecording(String path) async {
    readPaths.add(path);
    return Uint8List.fromList(const [1, 2, 3]);
  }
}

/// Fake [AsrTranscriber] returning a fixed transcript.
final class _FakeAsrTranscriber implements AsrTranscriber {
  final calls = <({Uint8List bytes, String filename})>[];

  @override
  Future<String> transcribe({
    required Uint8List bytes,
    required String filename,
    String? language,
  }) async {
    calls.add((bytes: bytes, filename: filename));
    return 'fake transcript';
  }
}

/// Fake [NotifyApi] for the `fa.notify` bridge tests — the host-side tests
/// never touch the real method channel.
final class _FakeNotifyApi implements NotifyApi {
  bool granted = true;
  final scheduled = <({String title, String? body, double? delaySeconds})>[];
  final cancelledIds = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => granted;

  @override
  Future<String> schedule({
    required String title,
    String? body,
    String? id,
    double? delaySeconds,
  }) async {
    scheduled.add((title: title, body: body, delaySeconds: delaySeconds));
    return id ?? 'fake-id-${scheduled.length}';
  }

  @override
  Future<void> cancel({required String id}) async {
    cancelledIds.add(id);
  }

  @override
  Future<void> cancelAll() async {}
}
