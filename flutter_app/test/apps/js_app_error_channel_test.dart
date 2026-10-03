// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1164 AC4 + cross-surface dedup at the channel gate: the
/// [JsAppErrorChannel] folds raw engine events into AT MOST ONE delivered
/// report per (app, error fingerprint) until the source revision changes,
/// with the per-app circuit breaker and the demo-reset re-arm.
library;

import 'dart:async';

import 'package:fa/apps/js_app_error_channel.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late JsAppErrorChannel channel;
  late List<JsAppErrorReport> delivered;
  late StreamSubscription<JsAppErrorReport> sub;

  setUp(() {
    channel = JsAppErrorChannel();
    delivered = [];
    sub = channel.stream.listen(delivered.add);
  });

  tearDown(() => unawaited(sub.cancel()));

  /// Broadcast-stream events deliver asynchronously — drain the loop.
  Future<void> flush() => Future<void>.delayed(Duration.zero);

  void report(
    String message, {
    String appId = 'calc',
    String surface = 'app',
    String kind = 'callback',
    String revision = 'rev-1',
  }) {
    channel.reportAppError(
      JsAppErrorEvent(kind: kind, message: message, stack: 'at f (w.js:1)'),
      appId: appId,
      surface: surface,
      sourceRevision: revision,
    );
  }

  group('AC4 — anti-spam by construction', () {
    test('100 identical per-frame errors deliver exactly ONE report', () async {
      for (var i = 0; i < 100; i++) {
        report('tick boom', revision: 'rev-1');
      }
      await flush();
      expect(delivered, hasLength(1));
      expect(delivered.single.appId, 'calc');
      expect(delivered.single.message, 'tick boom');
      expect(delivered.single.sourceRevision, 'rev-1');
    });

    test('an edit (new revision) reports the same error again', () async {
      report('tick boom', revision: 'rev-1');
      report('tick boom', revision: 'rev-1');
      await flush();
      expect(delivered, hasLength(1));
      report('tick boom', revision: 'rev-2');
      await flush();
      expect(delivered, hasLength(2));
      expect(delivered.last.sourceRevision, 'rev-2');
    });

    test('a tile + the fullscreen app reporting together deliver once', () async {
      report('tick boom', surface: 'tile', revision: 'rev-1');
      report('tick boom', surface: 'app', revision: 'rev-1');
      await flush();
      expect(delivered, hasLength(1));
    });

    test('different apps do not suppress each other', () async {
      report('tick boom', appId: 'calc', revision: 'rev-1');
      report('tick boom', appId: 'notes', revision: 'rev-1');
      await flush();
      expect(delivered, hasLength(2));
    });
  });

  group('per-app circuit breaker', () {
    test('stops the loop after N unacted identical reports', () async {
      for (var revision = 1; revision <= 5; revision++) {
        report('same bug', revision: 'rev-$revision');
      }
      await flush();
      // maxUnactedRevisions = 3 (the gate default): three reports, then
      // silence — the agent saw "the fix did not take" three times.
      expect(delivered, hasLength(3));
    });

    test('progress on a different error re-arms the breaker', () async {
      for (var revision = 1; revision <= 4; revision++) {
        report('same bug', revision: 'rev-$revision');
      }
      report('a different bug', revision: 'rev-5');
      report('same bug', revision: 'rev-6');
      await flush();
      expect(delivered, hasLength(5), reason: '3 breaker-limited + 1 new + '
          '1 re-armed');
    });

    test('resetApp (demo restore) drops the gate history', () async {
      report('same bug', revision: 'rev-1');
      await flush();
      expect(delivered, hasLength(1));
      channel.resetApp('calc');
      report('same bug', revision: 'rev-1');
      await flush();
      expect(delivered, hasLength(2), reason: 'the app source was restored; '
          'fresh errors must report against the fresh baseline');
    });
  });
}
