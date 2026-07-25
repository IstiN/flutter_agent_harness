// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:io';

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/services/calendar_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [CalendarApi] so the calendar demo's bridge call resolves without
/// touching the real platform channel.
final class _FakeCalendarApi implements CalendarApi {
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
      title: 'Standup',
      start: DateTime(start.year, start.month, start.day, 10),
      end: DateTime(start.year, start.month, start.day, 11),
      allDay: false,
      calendar: 'Work',
      location: 'Room 3',
      notes: null,
    ),
    (
      title: 'Lunch with Alex',
      start: DateTime(start.year, start.month, start.day, 13),
      end: DateTime(start.year, start.month, start.day, 14),
      allDay: false,
      calendar: 'Personal',
      location: null,
      notes: null,
    ),
  ];
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

      final map = AppPermissions.fromJson(manifest('map'));
      expect(map.network, isTrue); // OSM tiles

      final health = AppPermissions.fromJson(manifest('health'));
      expect(health.health, isTrue);

      final homekit = AppPermissions.fromJson(manifest('homekit'));
      expect(homekit.homekit, isTrue);
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
          expect(
            engine.exportedState?['bridgeError'],
            contains('not available'),
          );
          expect(engine.exportedState?['demoData'], isTrue);
          final tree = jsonEncode(engine.tree.value);
          expect(tree, contains('DEMO DATA'));
          expect(tree, contains('8,432')); // sample steps card
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
  });
}
