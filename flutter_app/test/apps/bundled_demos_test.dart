// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';
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

/// Fake [CalendarApi] so the calendar demo's bridge call resolves without
/// touching the real platform channel.
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
      start: DateTime(start.year, start.month, start.day, 10),
      end: DateTime(start.year, start.month, start.day, 11),
      allDay: false,
      calendar: 'Work',
      location: 'Room 3',
      notes: null,
      url: null,
      alarms: null,
      recurrence: null,
    ),
    (
      id: 'ev-lunch',
      title: 'Lunch with Alex',
      start: DateTime(start.year, start.month, start.day, 13),
      end: DateTime(start.year, start.month, start.day, 14),
      allDay: false,
      calendar: 'Personal',
      location: null,
      notes: null,
      url: null,
      alarms: null,
      recurrence: null,
    ),
  ];

  @override
  Future<List<CalendarInfo>> calendars() async => const [];

  @override
  Future<String> createEvent({
    required String title,
    required DateTime start,
    required DateTime end,
    bool allDay = false,
    String? calendar,
    String? location,
    String? notes,
    String? url,
    List<int>? alarms,
    CalendarRecurrence? recurrence,
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
    String? url,
    List<int>? alarms,
    CalendarRecurrence? recurrence,
    bool removeRecurrence = false,
    CalendarSpan span = CalendarSpan.thisEvent,
  }) async {}

  @override
  Future<void> deleteEvent({
    required String id,
    CalendarSpan span = CalendarSpan.thisEvent,
  }) async {
    deletedIds.add(id);
  }
}

/// Fake [ContactApi] so the contacts demo's bridge calls resolve without
/// touching the real platform channel.
final class _FakeContactApi implements ContactApi {
  final created =
      <({String name, List<String>? phones, List<String>? emails})>[];
  final openedUrls = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<List<Contact>> searchContacts({
    required String query,
    int limit = 200,
    int offset = 0,
  }) async {
    const all = [
      (
        id: 'c-anna',
        name: 'Anna Ivanova',
        phones: ['+1 555 0100'],
        emails: ['anna@example.com'],
      ),
      (
        id: 'c-bob',
        name: 'Bob Petrov',
        phones: ['+1 555 0200'],
        emails: <String>[],
      ),
    ];
    if (query.isEmpty) return all;
    final needle = query.toLowerCase();
    return all
        .where((contact) => contact.name.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Future<String> createContact({
    required String name,
    List<String>? phones,
    List<String>? emails,
    String? note,
  }) async {
    created.add((name: name, phones: phones, emails: emails));
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
  Future<void> deleteContact({required String id}) async {}

  @override
  Future<bool> openUrl(String url) async {
    openedUrls.add(url);
    return true;
  }
}

/// Fake [HealthApi] so the health demo's bridge call resolves with real
/// data without touching the real platform channel.
final class _FakeHealthApi implements HealthApi {
  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<HealthSummary> summary({required int days}) async => (
    steps: const [
      (date: '2026-07-24', value: 10234.0),
      (date: '2026-07-25', value: 12345.0),
    ],
    restingHeartRate: const [
      (date: '2026-07-24', value: 61.0),
      (date: '2026-07-25', value: 58.0),
    ],
    sleepHours: const [
      (date: '2026-07-24', value: 6.8),
      (date: '2026-07-25', value: 7.5),
    ],
  );
}

/// Fake [AsrApi] so the voice-notes demo's bridge calls resolve without
/// touching the real platform channel.
final class _FakeAsrApi implements AsrApi {
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<void> startRecording() async {
    startCalls++;
  }

  @override
  Future<AsrRecording> stopRecording() async {
    stopCalls++;
    return (path: '/tmp/fah-mic-test.m4a', durationMs: 1000, sampleRate: 44100);
  }

  @override
  Future<Uint8List> readRecording(String path) async =>
      Uint8List.fromList(const [1, 2, 3]);
}

/// Fake [AsrTranscriber] returning a fixed transcript.
final class _FakeAsrTranscriber implements AsrTranscriber {
  @override
  Future<String> transcribe({
    required Uint8List bytes,
    required String filename,
    String? language,
  }) async => 'fake transcript';
}

/// Fake [NotifyApi] so the reminders demo's bridge calls resolve without
/// touching the real platform channel.
final class _FakeNotifyApi implements NotifyApi {
  final scheduled = <({String title, String? body, double? delaySeconds})>[];
  final cancelledIds = <String>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

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

/// Fake [HomeApi] so the home demo's bridge calls resolve with real
/// accessories without touching the real platform channel.
final class _FakeHomeApi implements HomeApi {
  final powerCalls = <({String id, bool on, String? name, String? room})>[];
  final brightnessCalls =
      <({String id, int value, String? name, String? room})>[];
  final temperatureCalls =
      <({String id, double celsius, String? name, String? room})>[];

  @override
  Future<bool> get isAvailable async => true;

  @override
  Future<bool> requestAccess() async => true;

  @override
  Future<List<HomeInfo>> listHomes() async => const [
    (
      id: 'h-1',
      name: 'My Home',
      primary: true,
      roomCount: 2,
      accessoryCount: 2,
    ),
  ];

  @override
  Future<List<HomeRoom>> listRooms({String? homeId}) async => const [];

  @override
  Future<List<HomeAccessory>> listAccessories({
    String? homeId,
    String? roomId,
  }) async => const [
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
      services: [],
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
      services: [],
    ),
  ];

  @override
  Future<HomeAccessory> readAccessory({required String id}) async =>
      (await listAccessories()).firstWhere((accessory) => accessory.id == id);

  @override
  Future<void> writeCharacteristic({
    required String id,
    required String type,
    required Object value,
    String? name,
    String? room,
  }) async {}

  @override
  Future<List<HomeScene>> listScenes({String? homeId}) async => const [];

  @override
  Future<void> executeScene({required String id}) async {}

  @override
  Future<void> setPower({
    required String id,
    required bool on,
    String? name,
    String? room,
  }) async {
    powerCalls.add((id: id, on: on, name: name, room: room));
  }

  @override
  Future<void> setBrightness({
    required String id,
    required int value,
    String? name,
    String? room,
  }) async {
    brightnessCalls.add((id: id, value: value, name: name, room: room));
  }

  @override
  Future<void> setTargetTemperature({
    required String id,
    required double celsius,
    String? name,
    String? room,
  }) async {
    temperatureCalls.add((id: id, celsius: celsius, name: name, room: room));
  }
}

/// Smoke tests for the bundled demo apps under `assets/apps/`:
/// manifest discovery/parse/permission flags for every seeded id, plus a
/// real-engine boot of the bridge demos (calendar, map, health, homekit) —
/// booting through the JavaScriptCore backend also proves each `widget.js`
/// parses and renders an initial tree.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const settle = Duration(milliseconds: 300);

  group('bundled demo manifests', () {
    test('every seeded id has a parseable manifest and a widget.js', () {
      for (final id in AppsStore.demoAppIds) {
        final manifestFile = File('assets/apps/$id/manifest.json');
        final widgetFile = File('assets/apps/$id/widget.js');
        expect(manifestFile.existsSync(), isTrue, reason: id);
        expect(widgetFile.existsSync(), isTrue, reason: id);
        final decoded = jsonDecode(manifestFile.readAsStringSync());
        final app = JsAppInfo.fromManifest(
          (decoded as Map).cast<String, Object?>(),
          bundled: true,
          fallbackId: id,
        );
        expect(app.id, id, reason: 'manifest id matches the folder');
        expect(app.name, isNotEmpty, reason: id);
        expect(app.description, isNotEmpty, reason: id);
        expect(app.icon, isNotEmpty, reason: id);
      }
    });

    test('the bridge demos declare their permission flags', () {
      Map<String, Object?> manifest(String id) =>
          (jsonDecode(File('assets/apps/$id/manifest.json').readAsStringSync())
                  as Map)
              .cast<String, Object?>();

      final calendar = AppPermissions.fromJson(manifest('calendar'));
      expect(calendar.calendar, isTrue);
      expect(calendar.network, isFalse);

      final contacts = AppPermissions.fromJson(manifest('contacts'));
      expect(contacts.contacts, isTrue);
      expect(contacts.network, isFalse);

      final map = AppPermissions.fromJson(manifest('map'));
      expect(map.network, isTrue); // OSM tiles

      final health = AppPermissions.fromJson(manifest('health'));
      expect(health.health, isTrue);

      final homekit = AppPermissions.fromJson(manifest('homekit'));
      expect(homekit.homekit, isTrue);

      final voiceNotes = AppPermissions.fromJson(manifest('voice-notes'));
      expect(voiceNotes.microphone, isTrue);
      expect(voiceNotes.network, isFalse);

      final reminders = AppPermissions.fromJson(manifest('reminders'));
      expect(reminders.notifications, isTrue);
      expect(reminders.network, isFalse);
    });
  });

  group('bridge demo apps boot in the real engine', () {
    Future<MemoryExecutionEnv> envWithApp(String id) async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        'apps/$id/widget.js',
        await File('assets/apps/$id/widget.js').readAsString(),
      );
      return env;
    }

    JsAppInfo app(String id, Map<String, Object?> manifest) =>
        JsAppInfo.fromManifest(manifest, bundled: true, fallbackId: id);

    testWidgets('calendar renders events from the fa.calendar bridge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('calendar');
        final engine = JsAppEngine(
          app: app('calendar', const {'id': 'calendar', 'name': 'Calendar'}),
          env: env,
          permissions: const AppPermissions(calendar: true),
          calendar: _FakeCalendarApi(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.tree.value, isNotNull);
          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['error'], isNull);
          expect(engine.exportedState?['eventCount'], 2);
          expect(
            jsonEncode(engine.exportedState?['events']),
            contains('Standup'),
          );

          // Day navigation re-queries the bridge.
          await engine.callEvent('next_day');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['eventCount'], 2);
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('calendar add form creates an event through the bridge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final calendar = _FakeCalendarApi();
        final env = await envWithApp('calendar');
        final engine = JsAppEngine(
          app: app('calendar', const {'id': 'calendar', 'name': 'Calendar'}),
          env: env,
          permissions: const AppPermissions(calendar: true),
          calendar: calendar,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          // Open the add form, fill it, save.
          await engine.callEvent('add_open');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['form'], 'add');
          await engine.callEvent('form_title', {'value': 'Dentist'});
          await engine.callEvent('form_start', {'value': '16'});
          await engine.callEvent('form_end', {'value': '17'});
          await engine.callEvent('form_save');
          await Future<void>.delayed(settle);

          expect(calendar.created, hasLength(1));
          expect(calendar.created.single.title, 'Dentist');
          expect(calendar.created.single.start.hour, 16);
          expect(calendar.created.single.end.hour, 17);
          // The form closed and the day reloaded.
          expect(engine.exportedState?['form'], isNull);
          expect(engine.exportedState?['notice'], 'Event added.');
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('calendar event tap opens edit, delete removes the event', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final calendar = _FakeCalendarApi();
        final env = await envWithApp('calendar');
        final engine = JsAppEngine(
          app: app('calendar', const {'id': 'calendar', 'name': 'Calendar'}),
          env: env,
          permissions: const AppPermissions(calendar: true),
          calendar: calendar,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          // Tapping the first event row opens the edit form for it.
          await engine.callEvent('event_0');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['form'], 'edit');
          expect(jsonEncode(engine.tree.value), contains('Edit event'));

          // The delete action goes through the bridge with the event id.
          await engine.callEvent('form_delete');
          await Future<void>.delayed(settle);
          expect(calendar.deletedIds, ['ev-standup']);
          expect(engine.exportedState?['form'], isNull);
          expect(engine.exportedState?['notice'], 'Event deleted.');
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('calendar without the permission shows the grant card', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('calendar');
        final engine = JsAppEngine(
          app: app('calendar', const {'id': 'calendar', 'name': 'Calendar'}),
          env: env,
          permissions: const AppPermissions(),
          calendar: _FakeCalendarApi(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(
            engine.exportedState?['error'],
            contains('calendar permission'),
          );
          expect(
            jsonEncode(engine.tree.value),
            contains('Calendar permission needed'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('contacts renders search results from the bridge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('contacts');
        final engine = JsAppEngine(
          app: app('contacts', const {'id': 'contacts', 'name': 'Contacts'}),
          env: env,
          permissions: const AppPermissions(contacts: true),
          contacts: _FakeContactApi(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.tree.value, isNotNull);
          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['error'], isNull);
          expect(engine.exportedState?['resultCount'], 2);
          expect(
            jsonEncode(engine.exportedState?['contacts']),
            contains('Anna Ivanova'),
          );

          // The results list is a scrollable listView.
          expect(jsonEncode(engine.tree.value), contains('"listView"'));

          // Tapping a result opens the detail card with call/SMS buttons.
          await engine.callEvent('contact_0');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['selected'], 'Anna Ivanova');
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('Call'));
          expect(tree, contains('SMS'));

          // A name query re-searches live on change (no submit needed).
          await engine.callEvent('back_list');
          await engine.callEvent('search_change', {'value': 'bob'});
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['resultCount'], 1);
          expect(
            jsonEncode(engine.exportedState?['contacts']),
            contains('Bob Petrov'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('contacts add form creates a contact through the bridge', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final contacts = _FakeContactApi();
        final env = await envWithApp('contacts');
        final engine = JsAppEngine(
          app: app('contacts', const {'id': 'contacts', 'name': 'Contacts'}),
          env: env,
          permissions: const AppPermissions(contacts: true),
          contacts: contacts,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          // Open the add form, fill it, save.
          await engine.callEvent('add_open');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['form'], 'add');
          await engine.callEvent('form_name', {'value': 'Carol Sidorova'});
          await engine.callEvent('form_phone', {'value': '+1 555 0300'});
          await engine.callEvent('form_save');
          await Future<void>.delayed(settle);

          expect(contacts.created, hasLength(1));
          expect(contacts.created.single.name, 'Carol Sidorova');
          expect(contacts.created.single.phones, ['+1 555 0300']);
          // The form closed and the list reloaded.
          expect(engine.exportedState?['form'], isNull);
          expect(engine.exportedState?['notice'], 'Contact added.');
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('contacts without the permission shows the grant card', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('contacts');
        final engine = JsAppEngine(
          app: app('contacts', const {'id': 'contacts', 'name': 'Contacts'}),
          env: env,
          permissions: const AppPermissions(),
          contacts: _FakeContactApi(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(
            engine.exportedState?['error'],
            contains('contacts permission'),
          );
          expect(
            jsonEncode(engine.tree.value),
            contains('Contacts permission needed'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('map renders the map node and handles taps', (tester) async {
      await tester.runAsync(() async {
        final env = await envWithApp('map');
        final engine = JsAppEngine(
          app: app('map', const {'id': 'map', 'name': 'Map'}),
          env: env,
          permissions: const AppPermissions(network: true),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('"map"'));
          expect(tree, contains('old-castle'));
          expect(engine.exportedState?['markerCount'], 4);

          // Tapping the map drops a pin.
          await engine.callEvent('map_tap', {'lat': 53.68, 'lng': 23.84});
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['markerCount'], 5);
          expect(engine.exportedState?['userPins'], 1);

          // Zoom stays within bounds.
          await engine.callEvent('zoom_in');
          await engine.callEvent('zoom_in');
          await Future<void>.delayed(settle);
          expect(engine.exportedState?['zoom'], 16);
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('health shows the honest bridge stub state', (tester) async {
      await tester.runAsync(() async {
        final env = await envWithApp('health');
        final engine = JsAppEngine(
          app: app('health', const {'id': 'health', 'name': 'Health'}),
          env: env,
          permissions: const AppPermissions(health: true),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.exportedState?['bridgeAvailable'], isFalse);
          final error = engine.exportedState?['bridgeError'] as String?;
          expect(error, isNotNull);
          // On iOS/macOS the real channel answers "denied" when Health
          // access is not granted; on other platforms the bridge reports
          // "not available". Either way the demo falls back to demo data.
          expect(error, anyOf(contains('not available'), contains('denied')));
          expect(engine.exportedState?['demoData'], isTrue);
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('DEMO DATA'));
          expect(tree, contains('8,432')); // sample steps card
          // Chart nodes carry their series (renderer turns these into
          // sparklines/bars via the documented `data` prop — 0.4.7).
          expect(tree, contains('"chart"'));
          expect(tree, contains('"data":[3.2,5.1,4,6.8,5.5,7.9,8.4]'));
          expect(tree, contains('"chartType":"bar"')); // water card
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('health renders real data when the bridge provides it', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('health');
        final engine = JsAppEngine(
          app: app('health', const {'id': 'health', 'name': 'Health'}),
          env: env,
          permissions: const AppPermissions(health: true),
          health: _FakeHealthApi(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['bridgeAvailable'], isTrue);
          expect(engine.exportedState?['bridgeError'], isNull);
          expect(engine.exportedState?['demoData'], isFalse);
          expect(
            jsonEncode(engine.exportedState?['latest']),
            contains('"steps":12345'),
          );
          final tree = jsonEncode(engine.tree.value);
          // Real dashboard — no demo banner, no sample numbers.
          expect(tree, isNot(contains('DEMO DATA')));
          expect(tree, isNot(contains('8,432')));
          expect(tree, contains('LIVE'));
          expect(tree, contains('12,345')); // real steps card
          expect(tree, contains('7.5 h')); // real sleep card
          expect(tree, contains('"chart"'));
          expect(tree, contains('"data":[10234,12345]'));
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('homekit demo toggles persist locally', (tester) async {
      await tester.runAsync(() async {
        final env = await envWithApp('homekit');
        final engine = JsAppEngine(
          app: app('homekit', const {'id': 'homekit', 'name': 'Home'}),
          env: env,
          permissions: const AppPermissions(homekit: true),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.exportedState?['bridgeAvailable'], isFalse);
          expect(
            engine.exportedState?['bridgeError'],
            contains('not available'),
          );
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('Ceiling Light'));
          expect(tree, contains('Thermostat'));

          // Toggle the living-room light off — persisted via jsr.storage.
          await engine.callEvent('toggle_living-light');
          await Future<void>.delayed(settle);
          expect(
            jsonEncode(engine.exportedState?['devices']),
            contains('"id":"living-light","type":"light","status":"Off"'),
          );
          await Future<void>.delayed(settle);
          final storage = await env.readTextFile('apps/homekit/storage.json');
          expect(storage.valueOrNull, contains('"on":false'));

          // Thermostat bump.
          await engine.callEvent('temp_up');
          await Future<void>.delayed(settle);
          expect(
            jsonEncode(engine.exportedState?['devices']),
            contains('22.0°C'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('homekit renders real accessories and controls call the '
        'bridge', (tester) async {
      await tester.runAsync(() async {
        final home = _FakeHomeApi();
        final env = await envWithApp('homekit');
        final engine = JsAppEngine(
          app: app('homekit', const {'id': 'homekit', 'name': 'Home'}),
          env: env,
          permissions: const AppPermissions(homekit: true),
          home: home,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['bridgeAvailable'], isTrue);
          expect(engine.exportedState?['bridgeError'], isNull);
          expect(engine.exportedState?['demoData'], isFalse);
          expect(engine.exportedState?['accessoryCount'], 2);
          final tree = jsonEncode(engine.tree.value);
          // Real rooms/accessories — no demo banner, no demo devices.
          expect(tree, contains('LIVE'));
          expect(tree, contains('Living Room'));
          expect(tree, contains('Ceiling Light'));
          expect(tree, contains('Hallway'));
          expect(tree, contains('Thermostat'));
          expect(tree, isNot(contains('DEMO — LOCAL STATE ONLY')));
          expect(tree, isNot(contains('Front Door')));

          // Toggling the light calls setPower on the HomeApi.
          await engine.callEvent('power_a-light');
          await Future<void>.delayed(settle);
          expect(home.powerCalls, [
            (
              id: 'a-light',
              on: false,
              name: 'Ceiling Light',
              room: 'Living Room',
            ),
          ]);
          expect(
            jsonEncode(engine.exportedState?['accessories']),
            contains('"status":"Off · 80%"'),
          );

          // Brightness and thermostat steppers call their writes.
          await engine.callEvent('brightdown_a-light');
          await Future<void>.delayed(settle);
          expect(home.brightnessCalls, [
            (
              id: 'a-light',
              value: 70,
              name: 'Ceiling Light',
              room: 'Living Room',
            ),
          ]);
          await engine.callEvent('tempup_a-thermo');
          await Future<void>.delayed(settle);
          expect(home.temperatureCalls, [
            (
              id: 'a-thermo',
              celsius: 22.0,
              name: 'Thermostat',
              room: 'Hallway',
            ),
          ]);
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('voice-notes records, transcribes, and persists the note', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final asr = _FakeAsrApi();
        final env = await envWithApp('voice-notes');
        // A 1-second take keeps the test fast (the app defaults to 5 s).
        await env.writeFile(
          'apps/voice-notes/storage.json',
          '{"recordSeconds":1}',
        );
        final engine = JsAppEngine(
          app: app('voice-notes', const {
            'id': 'voice-notes',
            'name': 'Voice Notes',
          }),
          env: env,
          permissions: const AppPermissions(microphone: true),
          asr: asr,
          asrTranscriber: _FakeAsrTranscriber(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.tree.value, isNotNull);
          expect(engine.exportedState?['noteCount'], 0);
          expect(engine.exportedState?['busy'], isNull);

          // Record a take: the bridge waits the wall-clock second, then
          // the transcript is appended and persisted via jsr.storage.
          // Poll — the bridge calls cross real platform channels.
          await engine.callEvent('record_toggle');
          for (
            var i = 0;
            i < 40 && engine.exportedState?['noteCount'] != 1;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          expect(asr.startCalls, 1);
          expect(asr.stopCalls, 1);
          expect(engine.exportedState?['noteCount'], 1);
          expect(engine.exportedState?['busy'], isNull);
          expect(
            jsonEncode(engine.exportedState?['notes']),
            contains('fake transcript'),
          );
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('fake transcript'));
          final storage = await env.readTextFile(
            'apps/voice-notes/storage.json',
          );
          expect(storage.valueOrNull, contains('fake transcript'));
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('voice-notes without the permission shows the grant card', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final asr = _FakeAsrApi();
        final env = await envWithApp('voice-notes');
        await env.writeFile(
          'apps/voice-notes/storage.json',
          '{"recordSeconds":1}',
        );
        final engine = JsAppEngine(
          app: app('voice-notes', const {
            'id': 'voice-notes',
            'name': 'Voice Notes',
          }),
          env: env,
          permissions: const AppPermissions(),
          asr: asr,
          asrTranscriber: _FakeAsrTranscriber(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          await engine.callEvent('record_toggle');
          // The bridge call crosses real platform channels — poll instead
          // of a fixed settle (races under load).
          for (
            var i = 0;
            i < 40 && engine.exportedState?['error'] == null;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          expect(asr.startCalls, 0);
          expect(
            engine.exportedState?['error'],
            contains('microphone permission'),
          );
          expect(
            jsonEncode(engine.tree.value),
            contains('Microphone permission needed'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('reminders schedules and cancels through the fa.notify '
        'bridge', (tester) async {
      await tester.runAsync(() async {
        final notify = _FakeNotifyApi();
        final env = await envWithApp('reminders');
        final engine = JsAppEngine(
          app: app('reminders', const {'id': 'reminders', 'name': 'Reminders'}),
          env: env,
          permissions: const AppPermissions(notifications: true),
          notify: notify,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          expect(engine.tree.value, isNotNull);
          expect(engine.exportedState?['loading'], isFalse);
          expect(engine.exportedState?['reminderCount'], 0);

          // Fill the form and schedule: the bridge call crosses real
          // platform channels, so poll instead of a fixed settle.
          await engine.callEvent('remind_title', {'value': 'Stretch break'});
          await engine.callEvent('remind_minutes', {'value': '1'});
          await engine.callEvent('remind_add');
          for (
            var i = 0;
            i < 40 && engine.exportedState?['reminderCount'] != 1;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          expect(notify.scheduled, hasLength(1));
          expect(notify.scheduled.single.title, 'Stretch break');
          expect(notify.scheduled.single.delaySeconds, 60.0);
          expect(engine.exportedState?['reminderCount'], 1);
          expect(engine.exportedState?['notice'], 'Reminder scheduled.');
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('Stretch break'));
          // The list is persisted via jsr.storage.
          final storage = await env.readTextFile('apps/reminders/storage.json');
          expect(storage.valueOrNull, contains('Stretch break'));

          // Cancel the row: the bridge cancel reaches the NotifyApi.
          await engine.callEvent('cancel_0');
          for (
            var i = 0;
            i < 40 && engine.exportedState?['reminderCount'] != 0;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          expect(notify.cancelledIds, ['fake-id-1']);
          expect(engine.exportedState?['reminderCount'], 0);
          expect(engine.exportedState?['notice'], 'Reminder cancelled.');
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('reminders without the permission shows the grant card', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final notify = _FakeNotifyApi();
        final env = await envWithApp('reminders');
        final engine = JsAppEngine(
          app: app('reminders', const {'id': 'reminders', 'name': 'Reminders'}),
          env: env,
          permissions: const AppPermissions(),
          notify: notify,
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);

          await engine.callEvent('remind_title', {'value': 'Stretch break'});
          await engine.callEvent('remind_minutes', {'value': '1'});
          await engine.callEvent('remind_add');
          // The bridge call crosses real platform channels — poll instead
          // of a fixed settle (races under load).
          for (
            var i = 0;
            i < 40 && engine.exportedState?['error'] == null;
            i++
          ) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          expect(notify.scheduled, isEmpty);
          expect(
            engine.exportedState?['error'],
            contains('notifications permission'),
          );
          expect(
            jsonEncode(engine.tree.value),
            contains('Notifications permission needed'),
          );
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets(
      'animation-showcase staggers entrances and switches list → card',
      (tester) async {
        List<Map<String, Object?>> nodesOfType(Object? node, String type) {
          final out = <Map<String, Object?>>[];
          void walk(Object? n) {
            if (n is Map) {
              if (n['type'] == type) out.add(n.cast<String, Object?>());
              n.values.forEach(walk);
            } else if (n is List) {
              n.forEach(walk);
            }
          }

          walk(node);
          return out;
        }

        await tester.runAsync(() async {
          final env = await envWithApp('animation-showcase');
          final engine = JsAppEngine(
            app: app('animation-showcase', const {
              'id': 'animation-showcase',
              'name': 'Animation Showcase',
            }),
            env: env,
            permissions: const AppPermissions(),
          );
          try {
            await engine.start();
            await Future<void>.delayed(settle);

            // Menu boot: the new demo is listed.
            expect(jsonEncode(engine.tree.value), contains('go_listcard'));

            // Open the List → Card scene.
            await engine.callEvent('go_listcard');
            await Future<void>.delayed(settle);

            var tree = engine.tree.value;
            final entrances = nodesOfType(tree, 'entrance');
            expect(entrances, hasLength(7));
            // Staggered slideUp rows: delays strictly increase by 60ms.
            final delays = entrances
                .map((n) => (n['delay'] as num).toInt())
                .toList();
            expect(delays, [0, 60, 120, 180, 240, 300, 360]);
            expect(entrances.every((n) => n['animation'] == 'slideUp'), isTrue);

            var switchers = nodesOfType(tree, 'animatedSwitcher');
            expect(switchers, hasLength(1));
            expect(switchers.single['switchKey'], 'list');
            expect(switchers.single['animation'], 'slideLeft');

            // Tap a row → detail card, switchKey flips to card:<id>.
            await engine.callEvent('lc_open_rocket');
            await Future<void>.delayed(settle);

            tree = engine.tree.value;
            switchers = nodesOfType(tree, 'animatedSwitcher');
            expect(switchers.single['switchKey'], 'card:rocket');
            // The card itself enters with a fadeScale entrance.
            final cardEntrances = nodesOfType(tree, 'entrance');
            expect(cardEntrances, hasLength(1));
            expect(cardEntrances.single['animation'], 'fadeScale');
            expect(jsonEncode(tree), contains('Rocket'));

            // Back button returns to the staggered list.
            await engine.callEvent('lc_back');
            await Future<void>.delayed(settle);
            tree = engine.tree.value;
            expect(
              nodesOfType(tree, 'animatedSwitcher').single['switchKey'],
              'list',
            );
            expect(nodesOfType(tree, 'entrance'), hasLength(7));

            // The app registered the jsr.onBack contract at boot.
            expect(engine.backHandlerRegistered.value, isTrue);

            // Back on a card: consumed — returns to the list, no close.
            var closeRequests = 0;
            engine.onCloseRequested = () => closeRequests++;
            await engine.callEvent('lc_open_saturn');
            await Future<void>.delayed(settle);
            await engine.callEvent('back');
            await Future<void>.delayed(settle);
            expect(
              nodesOfType(
                engine.tree.value,
                'animatedSwitcher',
              ).single['switchKey'],
              'list',
            );
            expect(closeRequests, 0);

            // Back on the list: declined — the host is asked to close.
            await engine.callEvent('back');
            await Future<void>.delayed(settle);
            expect(closeRequests, 1);
          } finally {
            await engine.dispose();
          }
        });
      },
    );

    testWidgets('fitness-trainer boots and renders the workout card', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final env = await envWithApp('fitness-trainer');
        final engine = JsAppEngine(
          app: app('fitness-trainer', const {
            'id': 'fitness-trainer',
            'name': 'Fitness Trainer',
          }),
          env: env,
          permissions: const AppPermissions(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);
          expect(engine.tree.value, isNotNull);
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('Goblet Squat'));
          expect(tree, contains('SET 2 OF 4'));
        } finally {
          await engine.dispose();
        }
      });
    });

    testWidgets('english-teacher boots and flips flashcards', (tester) async {
      await tester.runAsync(() async {
        final env = await envWithApp('english-teacher');
        final engine = JsAppEngine(
          app: app('english-teacher', const {
            'id': 'english-teacher',
            'name': 'English Teacher',
          }),
          env: env,
          permissions: const AppPermissions(),
        );
        try {
          await engine.start();
          await Future<void>.delayed(settle);
          var tree = jsonEncode(engine.tree.value);
          expect(tree, contains('Daily English'));
          expect(tree, contains('apple'));

          // The flip button swaps the card to its translation.
          await engine.callEvent('flip');
          await Future<void>.delayed(settle);
          tree = jsonEncode(engine.tree.value);
          expect(tree, contains('яблоко'));
        } finally {
          await engine.dispose();
        }
      });
    });
  });
}
