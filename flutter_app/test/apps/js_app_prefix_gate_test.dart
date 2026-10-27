// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridge-free coverage for the engine's pure-Dart permission gate and the
/// preflight first-render await (gh-1848 tier 2).
///
/// The main engine suite skips on hosts without the native JS bridge
/// (`quickJsBridgeAvailable` guard, issue #184) — which on bare ubuntu CI
/// means the whole file contributes no coverage and native-independent
/// members measure 0%. The members covered here never boot a JS runtime:
/// constructing [JsAppEngine] is plain field init, and the prefix gate /
/// first-render await are pure Dart. They must keep running everywhere.
library;

import 'dart:async';

import 'package:fa/apps/app_preflight.dart';
import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/js_app_engine.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

JsAppInfo app() => JsAppInfo.fromManifest(
  const {'id': 'demo', 'name': 'Demo'},
  bundled: false,
  fallbackId: 'demo',
);

JsAppEngine engine(AppPermissions permissions) => JsAppEngine(
  app: app(),
  env: MemoryExecutionEnv(),
  permissions: permissions,
);

void main() {
  group('platform-bridge prefix gate (seam, gh-1848)', () {
    test('denies every declared prefix without permissions', () {
      final e = engine(const AppPermissions());
      expect(e.faPrefixGrantedForTest('homekit'), isFalse);
      expect(e.faPrefixGrantedForTest('health'), isFalse);
      expect(e.faPrefixGrantedForTest('contacts'), isFalse);
      // Prefixes with no permission at all stay denied even when every
      // declared permission is granted (the default-deny arm).
      expect(e.faPrefixGrantedForTest('sensors.read'), isFalse);
    });

    test('grants each declared prefix from its own permission', () {
      final e = engine(
        const AppPermissions(homekit: true, health: true, contacts: true),
      );
      expect(e.faPrefixGrantedForTest('homekit'), isTrue);
      expect(e.faPrefixGrantedForTest('health'), isTrue);
      expect(e.faPrefixGrantedForTest('contacts'), isTrue);
      expect(e.faPrefixGrantedForTest('sensors.read'), isFalse);
    });
  });

  group('first-render await (seam, gh-1848)', () {
    test('returns true immediately for an already-rendered tree', () async {
      final e = engine(const AppPermissions());
      e.tree.value = const {'type': 'text'};
      expect(
        await awaitFirstRenderForTest(e, const Duration(seconds: 5)),
        isTrue,
      );
    });

    test('completes true when the tree lands mid-wait', () async {
      final e = engine(const AppPermissions());
      final future = awaitFirstRenderForTest(e, const Duration(seconds: 5));
      e.tree.value = const {'type': 'text'};
      expect(await future, isTrue);
    });

    test('times out false when nothing renders within the budget', () async {
      final e = engine(const AppPermissions());
      expect(
        await awaitFirstRenderForTest(e, const Duration(milliseconds: 20)),
        isFalse,
      );
    });
  });
}
