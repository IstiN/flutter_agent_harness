// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/apps/app_tile_host.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake tile engine emitting a fixed tree — the [AppTileHost] tests stay
/// deterministic (no JavaScriptCore boot) via the engine-factory seam.
final class _FakeTileEngine extends JsAppEngine {
  _FakeTileEngine({
    required super.app,
    required super.env,
    required super.permissions,
    super.initialTheme,
    required this.fixedTree,
  });

  final Map<String, dynamic> fixedTree;
  final receivedEvents = <String>[];
  var startCount = 0;
  var disposeCount = 0;

  /// When set, the next [callEvent] hangs on this completer — tests drive
  /// the in-flight-refresh drain.
  Completer<void>? callEventGate;

  @override
  Future<void> start() async {
    startCount++;
    tree.value = fixedTree;
  }

  @override
  Future<void> callEvent(
    String actionId, [
    Map<String, dynamic>? payload,
  ]) async {
    receivedEvents.add(actionId);
    await callEventGate?.future;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await super.dispose();
  }

  @override
  Future<void> updateTheme(Map<String, dynamic> theme) async {}
}

const _tree = <String, dynamic>{
  'type': 'container',
  'alignment': 'center',
  'child': {
    'type': 'column',
    'mainAxisSize': 'min',
    'crossAxisAlignment': 'center',
    'children': [
      {
        'type': 'text',
        'data': '21°',
        'style': {'fontSize': 26, 'fontWeight': 'w700'},
      },
      {
        'type': 'text',
        'data': 'Minsk',
        'style': {'fontSize': 11},
      },
      {
        'type': 'inkWell',
        'onTap': 'tap',
        'child': {
          'type': 'text',
          'data': 'Open',
          'style': {'fontSize': 10},
        },
      },
    ],
  },
};

JsAppInfo _app({int? refreshSeconds}) => JsAppInfo.fromManifest(
  {
    'id': 'weather',
    'name': 'Weather',
    'widget': {'entry': 'widget_tile.js', 'refreshSeconds': ?refreshSeconds},
  },
  bundled: false,
  fallbackId: 'weather',
);

class _Harness {
  _Harness(this.env, this.engines);

  final MemoryExecutionEnv env;
  final List<_FakeTileEngine> engines;

  int opened = 0;

  TileEngineFactory get factory =>
      ({
        required JsAppInfo app,
        required ExecutionEnv env,
        required AppPermissions permissions,
        required Map<String, dynamic> initialTheme,
      }) {
        final engine = _FakeTileEngine(
          app: app,
          env: env,
          permissions: permissions,
          initialTheme: initialTheme,
          fixedTree: _tree,
        );
        engines.add(engine);
        return engine;
      };
}

Future<_Harness> _pumpHost(
  WidgetTester tester, {
  int? refreshSeconds,
  ValueNotifier<int>? fsRevision,
}) async {
  final harness = _Harness(MemoryExecutionEnv(), []);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            height: 120,
            child: AppTileHost(
              app: _app(refreshSeconds: refreshSeconds),
              env: harness.env,
              fsRevision: fsRevision,
              engineFactory: harness.factory,
              onOpen: () => harness.opened++,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  group('AppTileHost', () {
    testWidgets('renders the tree the tile engine emits', (tester) async {
      await _pumpHost(tester);
      expect(find.text('21°'), findsOneWidget);
      expect(find.text('Minsk'), findsOneWidget);
    });

    testWidgets('any UI event from the tile opens the full app', (
      tester,
    ) async {
      final harness = await _pumpHost(tester);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(harness.opened, 1);
    });

    testWidgets('refreshSeconds fires tile.refresh on the cadence', (
      tester,
    ) async {
      final harness = await _pumpHost(tester, refreshSeconds: 60);
      final engine = harness.engines.single;
      expect(engine.receivedEvents, isEmpty);
      await tester.pump(const Duration(seconds: 61));
      expect(engine.receivedEvents, ['tile.refresh']);
      // Unmount to cancel the periodic timer before the test ends.
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('unmount disposes the engine immediately', (tester) async {
      final harness = await _pumpHost(tester, refreshSeconds: 60);
      final engine = harness.engines.single;
      // An evaluation in flight (gated) must NOT delay disposal: queued
      // evaluations are guarded inside the runtime (`_isLive`), and a
      // LATE native release is what actually crashed production
      // (freed-then-reused context address).
      final gate = Completer<void>();
      engine.callEventGate = gate;
      await tester.pump(const Duration(seconds: 61));
      expect(engine.receivedEvents, ['tile.refresh']);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      expect(engine.disposeCount, 1);
      gate.complete();
    });

    testWidgets('a restart disposes the old engine and boots a fresh one', (
      tester,
    ) async {
      final fsRevision = ValueNotifier(0);
      addTearDown(fsRevision.dispose);
      final harness = await _pumpHost(tester, fsRevision: fsRevision);
      final old = harness.engines.single;

      fsRevision.value++;
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pumpAndSettle();
      expect(old.disposeCount, 1);
      expect(harness.engines, hasLength(2));
      expect(harness.engines.last.startCount, 1);
    });

    testWidgets('no refreshSeconds → no periodic timer', (tester) async {
      final harness = await _pumpHost(tester);
      await tester.pump(const Duration(minutes: 5));
      expect(harness.engines.single.receivedEvents, isEmpty);
    });

    testWidgets('an fsRevision bump restarts the engine (debounced)', (
      tester,
    ) async {
      final fsRevision = ValueNotifier(0);
      addTearDown(fsRevision.dispose);
      final harness = await _pumpHost(tester, fsRevision: fsRevision);
      expect(harness.engines, hasLength(1));

      fsRevision.value++;
      // The 600 ms debounce has not elapsed yet — still one engine.
      await tester.pump(const Duration(milliseconds: 300));
      expect(harness.engines, hasLength(1));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(harness.engines, hasLength(2));
      expect(harness.engines.last.startCount, 1);
      expect(find.text('21°'), findsOneWidget);
    });
  });
}
